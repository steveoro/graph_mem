# frozen_string_literal: true

class ToolUsageReport
  DEFAULT_WINDOW_DAYS = 30
  PERCENTILE_SAMPLE_LIMIT = 100_000
  PERCENTILES = {
    p50_ms: 0.50,
    p95_ms: 0.95
  }.freeze

  # Builds per-tool count, error-rate, and latency metrics.
  #
  # @param since [Time, nil] optional lower time boundary
  # @param tool_names [Array<String>, nil] names to include even with zero calls
  # @param relation [ActiveRecord::Relation<ToolInvocation>, nil] pre-filtered scope
  # @return [Hash] aggregate report and percentile sampling metadata
  def self.call(since: DEFAULT_WINDOW_DAYS.days.ago, tool_names: nil, relation: nil)
    new(since: since, tool_names: tool_names, relation: relation).call
  end

  # @param since [Time, nil]
  # @param tool_names [Array<String>, nil]
  # @param relation [ActiveRecord::Relation<ToolInvocation>, nil]
  def initialize(since:, tool_names:, relation: nil)
    @since = since
    @tool_names = tool_names
    @relation = relation
  end

  # Executes SQL-backed counts and bounded percentile sampling.
  #
  # @return [Hash]
  def call
    relation = @relation || ToolInvocation.all
    relation = relation.since(@since) if @since
    counts = relation.group(:tool_name).count
    error_counts = relation.errors.group(:tool_name, :error_category).count
    duration_rows = relation.reorder(created_at: :desc)
                            .limit(PERCENTILE_SAMPLE_LIMIT)
                            .pluck(:tool_name, :duration_ms)
    durations = duration_rows.group_by(&:first)
    total_calls = counts.values.sum

    {
      generated_at: Time.current,
      since: @since,
      total_calls: total_calls,
      duration_sample_size: duration_rows.size,
      duration_sample_limited: total_calls > duration_rows.size,
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

    values.sort.fetch((fraction * values.length).ceil - 1)
  end
end
