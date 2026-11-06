# frozen_string_literal: true

module GraphMem
  module ScanProfile
    # Runs `graph_mem:scan_profile` (F-3b, step P): inside a Sandbox and a Workspace, for each
    # selected repo × profile × settings combination, an empty graph, the Project root, a
    # `mode: "initial"` ProjectScanner run on the checkout and, unless RESCAN=0, a `mode: "rescan"`
    # run of the same code. ProjectScanner is called directly on the profiler's own temp dir, so
    # ScanRootPolicy is neither used nor widened. A repo that can't be checked out (a moved pin, no
    # network) is reported and skipped; a Sandbox::Refused stops the run.
    #
    #   report = Runner.new(options: options, manifest: manifest, fetcher: ScanProfileGitFetch).call
    #   report.dir # => "tmp/scan_profile/20261105T101500Z"
    class Runner
      # The scan result's counters a run reports (ProjectScanner::Result#to_h keys).
      COUNTERS = %i[entities_created entities_updated observations_created observations_obsoleted observations_moved
                    relations_created relations_deleted parts_total parts_failed files_too_large files_over_budget
                    partial fallback fallback_reason].freeze

      # @param options [Options]
      # @param manifest [Manifest]
      # @param fetcher [#call, nil] the clone step (Workspace); nil when only synth is selected
      # @param out [IO] progress lines
      def initialize(options:, manifest:, fetcher: nil, out: $stdout)
        @options = options
        @manifest = manifest
        @fetcher = fetcher
        @out = out
        @runs = []
        @errors = []
      end

      # @return [Report] written to options.report_dir
      # @raise [Sandbox::Refused] when the run may not start or a write would leave the throwaway database
      def call
        started_at = Time.now.utc
        backend = nil
        Sandbox.new(target: @options.db, keep_db: @options.keep_db).run do |sandbox|
          @sandbox = sandbox
          sandbox.configure!(chain: @options.chain, settings: @options.settings)
          say "throwaway database #{sandbox.target}; scan chain #{@options.chain}"
          Workspace.open(fetcher: @fetcher) { |workspace| @options.repos.each { |key| profile_repo(workspace, @manifest.fetch(key)) } }
          backend = backend_summary
        end
        Report.new(started_at: started_at, options: @options, backend: backend, runs: @runs, errors: @errors).write(@options.report_dir)
      end

      private

      def say(line)
        @out&.puts("[scan_profile] #{line}")
      end

      def profile_repo(workspace, repo)
        checkout = workspace.checkout(repo)
        @options.profiles.each do |profile|
          @options.setting_sets.each { |settings| @runs << profile_unit(checkout, profile, settings) }
        end
      rescue Sandbox::Refused
        raise
      rescue StandardError => e
        @errors << { "repo" => repo.key, "error" => Report.scrub(e.message) }
        say "#{repo.key}: skipped (#{Report.scrub(e.message)})"
      ensure
        workspace.remove(checkout) if checkout
      end

      def profile_unit(checkout, profile, settings)
        repo = checkout.repo
        @sandbox.reset_graph!
        applied = apply_settings(settings)
        project = @sandbox.project!(name: repo.project_name)
        globs = repo.globs(profile)
        caps = @manifest.caps(repo, full: @options.full)
        files = checkout.files(globs)
        scans = { "initial" => scan(checkout, globs, caps, "initial") }
        # The graph of a first scan: what the metrics and the snapshot describe.
        graph = GraphSnapshot.call(project.reload)
        metrics = Metrics.call(project, expected: Manifest.synthetic(repo.key)&.expected(profile))
        scans["rescan"] = scan(checkout, globs, caps, "rescan") if @options.rescan
        say "#{repo.key} #{profile} #{applied.values.join('/')}: #{scan_line(scans['initial'])}"
        { "repo" => repo.key, "commit" => checkout.commit, "profile" => profile, "settings" => applied,
          "caps" => effective_caps(caps), "files" => file_stats(checkout, files), "scans" => scans,
          "metrics" => metrics.merge("rescan_churn" => Metrics.churn(scans["rescan"])), "graph" => graph }
      end

      # @return [Hash{String => Numeric}] the scan settings in force for the run
      def apply_settings(settings)
        settings.each { |key, value| AppSettings.public_send(:"project_scan_#{key}=", value) }
        { "bytes_per_token" => AppSettings.project_scan_bytes_per_token.to_f,
          "chunk_output_tokens" => AppSettings.project_scan_chunk_output_tokens.to_i,
          "max_chunks" => AppSettings.project_scan_max_chunks.to_i }
      end

      def scan(checkout, globs, caps, mode)
        @sandbox.assert_target!
        parts = []
        started = monotonic
        result = ProjectScanner.new(project_root: checkout.root, project_name: checkout.repo.project_name, mode: mode,
                                    file_globs: globs, **caps, on_part_done: ->(done) { parts << done }).call
        scan_stats(result.to_h, parts, monotonic - started, checkout)
      end

      def scan_stats(result, parts, seconds, checkout)
        times = parts.map(&:seconds).sort
        stats = COUNTERS.to_h { |key| [ key.to_s, result[key] ] }
        stats.merge("status" => result[:status], "wall_s" => seconds.round(3), "noise_dropped" => result[:noise_dropped] || {},
                    "code_map" => result[:code_map] || {},
                    "requests" => parts.size, "parts_split" => parts.count(&:split),
                    "part_p50_s" => percentile(times, 0.5), "part_p95_s" => percentile(times, 0.95),
                    "errors" => Array(result[:errors]).first(3).map { |error| Report.scrub(error.to_s, checkout.root) })
      end

      def percentile(sorted, fraction)
        return nil if sorted.empty?

        sorted[((sorted.size - 1) * fraction).round].round(3)
      end

      def effective_caps(caps)
        { "max_total_input_bytes" => caps[:max_total_input_bytes] || ProjectScanner::MAX_TOTAL_INPUT_BYTES,
          "max_files" => caps[:max_files] || ProjectScanner::MAX_FILES }
      end

      def file_stats(checkout, files)
        { "resolved" => files.size, "bytes" => files.sum { |rel| File.size(File.join(checkout.root, rel)) } }
      end

      def scan_line(stats)
        "#{stats['entities_created']} entities, #{stats['observations_created']} observations, " \
          "#{stats['parts_total']} parts (#{stats['parts_failed']} failed, #{stats['parts_split']} split), #{stats['wall_s']} s" \
          "#{' partial' if stats['partial']}#{' fallback' if stats['fallback']}"
      end

      def backend_summary
        config = SummarizationConfig.resolved_config
        usage = @sandbox.llm_usage
        cloud_calls = usage.sum { |_task, providers| providers.except(Llm::OllamaProvider::NAME).sum { |_name, counts| counts[:calls] } }
        { "chain" => @options.chain, "cloud_chain" => Llm::Router.cloud_chain?(:scan),
          "left_machine" => cloud_calls.positive?, "model" => config[:model], "num_ctx" => config[:num_ctx],
          "llm_usage" => usage, "enqueued_jobs" => @sandbox.enqueued, "database" => @sandbox.target,
          "database_kept" => @sandbox.keep_db? }
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
