# frozen_string_literal: true

namespace :graph_mem do
  desc "Backfill memory_entities.project_id from the part_of tree " \
       "(arg 'dry_run' reports without writing; re-runs are no-ops)"
  task :backfill_project_ids, [ :mode ] => :environment do |_t, args|
    dry_run = args[:mode].to_s == "dry_run"
    abort "usage: bin/rails graph_mem:backfill_project_ids[dry_run]" unless args[:mode].blank? || dry_run

    begin
      ProjectIdBackfill.new.run(dry_run: dry_run)
    rescue ActiveRecord::RecordNotUnique => e
      # Stamped-but-unrooted row colliding with a global same-name row:
      # the transactional apply already rolled back — tell the operator
      # how to unblock instead of surfacing the raw DB error.
      abort "backfill aborted and rolled back: #{ProjectIdBackfill.conflict_hint(e)}\n" \
            "  raw error: #{e.cause&.message || e.message}"
    end
  end

  desc "Report MCP tool usage (DAYS=30 by default; DAYS=all for all history)"
  task tool_usage: :environment do
    days = ENV.fetch("DAYS", ToolUsageReport::DEFAULT_WINDOW_DAYS.to_s)
    since =
      if days.casecmp?("all")
        nil
      elsif days.match?(/\A[1-9]\d*\z/)
        days.to_i.days.ago
      else
        abort "DAYS must be a positive integer or 'all'"
      end

    report = ToolUsageReport.call(since: since)
    window = since ? "since #{since.iso8601}" : "for all recorded history"

    puts "GraphMem MCP tool usage #{window}"
    puts "Total calls: #{report[:total_calls]}"
    puts format(
      "%-32s %8s %8s %8s %8s %8s  %s",
      "Tool", "Calls", "Share", "Errors", "p50", "p95", "Error categories"
    )

    report[:tools].each do |row|
      categories = row[:errors_by_category].map { |category, count| "#{category}=#{count}" }.join(",")
      categories = "-" if categories.empty?

      puts format(
        "%-32s %8d %7.2f%% %7.2f%% %7s %7s  %s",
        row[:tool_name],
        row[:call_count],
        row[:share_percent],
        row[:error_rate_percent],
        row[:p50_ms] || "-",
        row[:p95_ms] || "-",
        categories
      )
    end

    never_called = report[:tools].select { |row| row[:call_count].zero? }.map { |row| row[:tool_name] }
    puts "Never called: #{never_called.any? ? never_called.join(', ') : 'none'}"
  end

  desc "Set metadata.graph-mem-version in skills/graph-mem-mcp-toolset/SKILL.md and the README's version badge " \
       "to GraphMem::VERSION (run after bumping lib/graph_mem/version.rb; SKILL_PATH and README_PATH override the files)"
  task :sync_skill_version do
    require Rails.root.join("lib/graph_mem/version").to_s

    path = ENV.fetch("SKILL_PATH", Rails.root.join("skills/graph-mem-mcp-toolset/SKILL.md").to_s)
    text = File.read(path)
    pattern = /^(  graph-mem-version: )"[^"]*"$/
    abort "#{path}: no 'graph-mem-version:' line under metadata" unless text.match?(pattern)

    File.write(path, text.sub(pattern, %(\\1"#{GraphMem::VERSION}")))
    puts "#{path}: graph-mem-version = #{GraphMem::VERSION}"

    # 1.81.0: the README's shields.io version badge, which used to fall behind.
    readme = ENV.fetch("README_PATH", Rails.root.join("README.md").to_s)
    badge = %r{(img\.shields\.io/badge/version-)[0-9][0-9.]*(-blue)}
    readme_text = File.read(readme)
    abort "#{readme}: no version badge (img.shields.io/badge/version-X.Y.Z-blue)" unless readme_text.match?(badge)

    File.write(readme, readme_text.sub(badge, "\\1#{GraphMem::VERSION}\\2"))
    puts "#{readme}: version badge = #{GraphMem::VERSION}"
  end
end
