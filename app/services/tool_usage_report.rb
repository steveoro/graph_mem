# frozen_string_literal: true

class ToolUsageReport
  DEFAULT_WINDOW_DAYS = 30
  PERCENTILES = {
    p50_ms: 0.50,
    p95_ms: 0.95
  }.freeze

  def self.call(since: DEFAULT_WINDOW_DAYS.days.ago, tool_names: nil)
    new(since: since, tool_names: tool_names).call
  end

  def initialize(since:, tool_names:)
    @since = since
    @tool_names = tool_names
  end

  def call
    relation = @since ? ToolInvocation.since(@since) : ToolInvocation.all
    counts = relation.group(:tool_name).count
    error_counts = relation.errors.group(:tool_name, :error_category).count
    durations = relation.order(:tool_name, :duration_ms).pluck(:tool_name, :duration_ms).group_by(&:first)
    total_calls = counts.values.sum

    {
      generated_at: Time.current,
      since: @since,
      total_calls: total_calls,
      tools: all_tool_names(counts).map do |tool_name|
        tool_row(
          tool_name,
          count: counts.fetch(tool_name, 0),
          total_calls: total_calls,
          error_counts: error_counts,
          durations: durations.fetch(tool_name, []).map(&:second)
        )
      end
    }
  end

  private

  def all_tool_names(counts)
    ((@tool_names || registered_tool_names) + counts.keys).uniq.sort
  end

  def registered_tool_names
    GraphMem::McpToolRegistry.load_all!
    GraphMem::McpToolRegistry.tool_classes.map(&:tool_name)
  end

  def tool_row(tool_name, count:, total_calls:, error_counts:, durations:)
    errors_by_category = error_counts.each_with_object({}) do |((name, category), category_count), result|
      next unless name == tool_name

      result[category.presence || "uncategorized"] = category_count
    end
    error_count = errors_by_category.values.sum

    {
      tool_name: tool_name,
      call_count: count,
      share_percent: percentage(count, total_calls),
      error_count: error_count,
      error_rate_percent: percentage(error_count, count),
      errors_by_category: errors_by_category.sort.to_h,
      p50_ms: percentile(durations, PERCENTILES[:p50_ms]),
      p95_ms: percentile(durations, PERCENTILES[:p95_ms])
    }
  end

  def percentage(numerator, denominator)
    return 0.0 if denominator.zero?

    ((numerator.to_f / denominator) * 100).round(2)
  end

  def percentile(values, fraction)
    return nil if values.empty?

    values.fetch((fraction * values.length).ceil - 1)
  end
end
