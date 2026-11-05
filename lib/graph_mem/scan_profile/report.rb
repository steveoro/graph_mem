# frozen_string_literal: true

require "fileutils"
require "json"

module GraphMem
  module ScanProfile
    # The report of one `graph_mem:scan_profile` run (F-3b): `report.json` and `report.md` in
    # `<report_dir>/<UTC timestamp>/` (tmp/scan_profile/ by default, git-ignored, never committed).
    # Repo keys and relative paths only: no file contents and no absolute paths (#scrub). The JSON's
    # shape is versioned by SCHEMA_VERSION: per run the repo key, pinned commit, profile, settings,
    # caps, scan counters and timing, and the resulting graph (entities with type, observations and
    # relations), so a later tool can compare it with another graph.
    #
    #   report = Report.new(started_at: Time.now.utc, options: options, backend: backend, runs: runs, errors: []).write("tmp/scan_profile")
    #   report.dir # => "tmp/scan_profile/20261105T101500Z"
    class Report
      SCHEMA_VERSION = 1
      # The scan columns of the Markdown table, in order.
      SCAN_COLUMNS = {
        "entities c/u" => %w[entities_created entities_updated], "observations c/o" => %w[observations_created observations_obsoleted],
        "relations c/d" => %w[relations_created relations_deleted], "parts t/f/s" => %w[parts_total parts_failed parts_split],
        "too large/over budget" => %w[files_too_large files_over_budget]
      }.freeze
      # The noise columns of the Markdown table (Metrics keys), in order.
      NOISE_COLUMNS = {
        "entities" => "entities", "no obs." => "entities_without_observations", "short obs." => "short_observations",
        "dup. obs." => "duplicate_observations", "generic" => "generic_names", "file name" => "filename_names",
        "root only" => "root_only_entities", "isolated" => "isolated_entities",
        "rescan churn" => "rescan_churn"
      }.freeze

      # @return [String, nil] the directory written (after #write)
      attr_reader :dir

      # Replaces absolute paths (the given roots, the temp dir, the app root and the home folder) so
      # nothing machine-specific reaches the report.
      #
      # @param text [String]
      # @param roots [Array<String>] extra folders to hide (a checkout's root)
      # @return [String]
      def self.scrub(text, *roots)
        hidden = (roots + [ Dir.tmpdir, Rails.root.to_s, Dir.home ]).compact.map(&:to_s).reject(&:empty?).uniq.sort_by { |root| -root.length }
        hidden.reduce(text.to_s) { |scrubbed, root| scrubbed.gsub(root, "<path>") }
      end

      # @param started_at [Time]
      # @param options [Options]
      # @param backend [Hash] the Runner's backend summary
      # @param runs [Array<Hash>] the Runner's profiled runs
      # @param errors [Array<Hash>] repos that were skipped
      # @param extra [Hash{String => Object}] more top-level JSON keys (a sweep comparison)
      # @param sections [Array<String>] more Markdown lines at the end (the metrics, a sweep table)
      def initialize(started_at:, options:, backend:, runs:, errors:, extra: {}, sections: [])
        @started_at = started_at
        @options = options
        @backend = backend || {}
        @runs = runs
        @errors = errors
        @extra = extra
        @sections = sections
      end

      # @param report_dir [String]
      # @return [Report] self
      def write(report_dir)
        @dir = File.join(report_dir, @started_at.strftime("%Y%m%dT%H%M%SZ"))
        FileUtils.mkdir_p(@dir)
        File.write(File.join(@dir, "report.json"), "#{JSON.pretty_generate(data)}\n")
        File.write(File.join(@dir, "report.md"), markdown)
        self
      end

      # @return [Hash] the JSON document
      def data
        {
          "schema_version" => SCHEMA_VERSION, "graph_mem_version" => GraphMem::VERSION, "started_at" => @started_at.iso8601,
          "options" => { "repos" => @options.repos, "profiles" => @options.profiles, "rescan" => @options.rescan,
                         "full" => @options.full, "settings" => @options.settings.keys },
          "backend" => @backend, "errors" => @errors, "runs" => @runs
        }.merge(@extra)
      end

      # @return [String] the Markdown summary (no graph contents)
      def markdown
        lines = [ "# Scan profile #{@started_at.strftime('%Y-%m-%d %H:%M UTC')} (graph_mem #{GraphMem::VERSION})", "" ]
        lines.concat(backend_lines)
        lines.concat([ "", "## Scans", "", scan_header, scan_separator ])
        @runs.each { |run| run["scans"].each { |phase, stats| lines << scan_row(run, phase, stats) } }
        lines.concat(noise_lines)
        lines.concat([ "", "## Skipped repos", "" ] + @errors.map { |error| "- `#{error['repo']}`: #{error['error']}" }) if @errors.any?
        lines.concat(@sections)
        "#{lines.join("\n")}\n"
      end

      private

      def backend_lines
        cloud = @backend["left_machine"] ? "**yes**" : "no"
        [ "- Backend: chain `#{@backend['chain']}`, model `#{@backend['model']}`, num_ctx #{@backend['num_ctx']}; " \
          "cloud chain: #{@backend['cloud_chain'] ? 'yes (refused by the gate)' : 'no'}; anything left the machine: #{cloud}",
          "- Throwaway database `#{@backend['database']}`#{@backend['database_kept'] ? ' (kept: KEEP_DB=1)' : ' (dropped)'}; " \
          "jobs enqueued, none run: #{format_counts(@backend['enqueued_jobs'])}",
          "- Repos: #{@options.repos.join(', ')}; profiles: #{@options.profiles.join(', ')}; " \
          "#{@options.full ? 'FULL=1' : 'first-run caps'}; rescan: #{@options.rescan ? 'yes' : 'no'}" ]
      end

      # The noise metrics of each run's first scan (Metrics), with recall / precision for synth.
      def noise_lines
        header = "| repo | profile | settings | #{NOISE_COLUMNS.keys.join(' | ')} | recall e/r | precision e/r | types |"
        rows = @runs.filter_map do |run|
          metrics = run["metrics"] or next
          cells = NOISE_COLUMNS.values.map { |key| metrics[key].nil? ? "-" : metrics[key] }
          accuracy = %w[recall precision].map { |kind| metrics[kind] ? metrics[kind].values.map { |value| value || "-" }.join("/") : "-" }
          types = metrics["types"].to_h.first(4).map { |type, count| "#{type} #{count}" }.join(", ")
          "| #{run['repo']} | #{run['profile']} | #{run['settings'].values.join(' / ')} | #{cells.join(' | ')} | #{accuracy.join(' | ')} | #{types} |"
        end
        return [] if rows.empty?

        [ "", "## Noise (first scan)", "", header, "|#{'---|' * (NOISE_COLUMNS.size + 6)}" ] + rows
      end

      def format_counts(counts)
        counts.blank? ? "none" : counts.map { |name, count| "#{name} #{count}" }.join(", ")
      end

      def scan_header
        "| repo | profile | settings | caps | phase | #{SCAN_COLUMNS.keys.join(' | ')} | partial | fallback | wall s | part p50/p95 s | noise dropped |"
      end

      def scan_separator
        "|#{'---|' * (SCAN_COLUMNS.size + 10)}"
      end

      def scan_row(run, phase, stats)
        settings = run["settings"].values.join(" / ")
        caps = "#{run['caps']['max_total_input_bytes'] / 1024} KB / #{run['caps']['max_files']}"
        cells = SCAN_COLUMNS.values.map { |keys| keys.map { |key| stats[key].to_i }.join("/") }
        noise = stats["noise_dropped"].to_h.select { |_rule, count| count.to_i.positive? }
        "| #{run['repo']} | #{run['profile']} | #{settings} | #{caps} | #{phase} | #{cells.join(' | ')} | " \
          "#{stats['partial'] ? 'yes' : 'no'} | #{stats['fallback'] ? "yes (#{stats['fallback_reason']})" : 'no'} | " \
          "#{stats['wall_s']} | #{stats['part_p50_s'] || '-'}/#{stats['part_p95_s'] || '-'} | #{format_counts(noise)} |"
      end
    end
  end
end
