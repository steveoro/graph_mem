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

  desc "Canonicalize stored relation types (R1a; DRY_RUN=1 counts without writing; VERBOSE=1 also lists the changes)"
  task canonicalize_relations: :environment do
    dry_run = ENV["DRY_RUN"].to_s.match?(/\A(1|true|yes)\z/i)
    summary = RelationTypeSweep.call(dry_run: dry_run, actor: "rake:canonicalize_relations", source: "rake")
    counts = summary[:counts]

    puts "Relation types#{' (dry run: nothing written)' if dry_run}: " +
         counts.map { |outcome, count| "#{outcome} #{count}" }.join(", ")
    puts "Report: maintenance report ##{summary[:report_id]}" if summary[:report_id]
    if ENV["VERBOSE"].present?
      summary[:changes].each do |change|
        puts "  ##{change['relation_id']} #{change['action']}: #{change['old_type']} -> #{change['new_type']}" \
             "#{" (into ##{change['merged_into_id']})" if change['merged_into_id']}" \
             "#{" (review row #{change['review_row_id']})" if change['review_row_id']}#{" (#{change['error']})" if change['error']}"
      end
      puts "  … #{summary[:changes_omitted]} more not listed" if summary[:changes_omitted].to_i.positive?
    end
  end

  desc "Export projects (or global roots) by name as a graph_mem-sql script " \
       "(graph_mem:export_sql[SynthPrj,...]; OUT=path, default tmp/exports/<first name>.sql; NESTED=0 leaves nested Projects out)"
  task :export_sql, [ :name ] => :environment do |_t, args|
    names = [ args[:name], *args.extras ].compact_blank
    abort "usage: bin/rails graph_mem:export_sql[<project>,...] [OUT=path] [NESTED=0]" if names.empty?

    roots = names.map do |name|
      MemoryEntity.find_by(name: name, project_id: nil) or abort "no Project root or global entity named '#{name}'"
    end
    out = ENV["OUT"].presence || ExportJob::TEMP_DIR.join("#{names.first.parameterize(separator: '_').presence || 'export'}.sql").to_s
    FileUtils.mkdir_p(File.dirname(out))
    counts = SqlExport::Writer.new(roots.map(&:id), include_nested: ENV["NESTED"] != "0").write_file(out)
    puts "Wrote #{out}: #{counts.map { |key, count| "#{key}=#{count}" }.join(' ')}"
  rescue ArgumentError => e
    abort "export refused: #{e.message}"
  end

  desc "Import a graph_mem-sql script (FILE=path; DRY_RUN=1 runs it and rolls it back). Always validated first; " \
       "prints the counts and the affected rows"
  task import_sql: :environment do
    path = ENV["FILE"].presence or abort "usage: bin/rails graph_mem:import_sql FILE=path [DRY_RUN=1]"
    dry_run = ENV["DRY_RUN"].to_s.match?(/\A(1|true|yes)\z/i)
    result = SqlImport::Executor.call(SqlImport::Validator.validate_file(path), dry_run: dry_run)

    puts dry_run ? "Dry run: nothing was written." : "Imported: operation #{result.operation_id}"
    [ result.summary, result.affected ].each do |rows|
      next puts("(no affected rows)") if rows.empty?

      columns = rows.first.keys
      cells = ([ columns.to_h { |column| [ column, column ] } ] + rows).map do |row|
        columns.map { |column| (row[column].is_a?(Hash) ? row[column].to_json : row[column].to_s).truncate(60) }
      end
      widths = cells.transpose.map { |column| column.map(&:length).max }
      cells.each { |row| puts row.zip(widths).map { |cell, width| cell.ljust(width) }.join("  ").rstrip }
    end
    puts "Embeddings, keywords and trust scores of the new and changed rows are filled by the background jobs." unless dry_run
  rescue SqlImport::Validator::Invalid, SqlImport::Executor::Refused, ProjectMembership::LockTimeout, Errno::ENOENT => e
    abort "import refused, nothing was written: #{e.message}"
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
