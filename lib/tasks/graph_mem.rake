# frozen_string_literal: true

namespace :graph_mem do
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
end
