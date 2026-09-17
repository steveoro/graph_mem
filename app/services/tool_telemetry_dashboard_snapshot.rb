# frozen_string_literal: true

# Builds bounded aggregate data for the operator telemetry dashboard.
class ToolTelemetryDashboardSnapshot
  BREAKDOWN_LIMIT = 10
  PERCENTILE_SAMPLE_LIMIT = ToolUsageReport::PERCENTILE_SAMPLE_LIMIT

  # Builds the dashboard snapshot for normalized ToolInvocation filters.
  #
  # @param filters [Hash, ActionController::Parameters]
  # @return [Hash] summary, series, breakdowns, and retention status
  def self.call(filters: {})
    new(filters: filters).call
  end

  # @param filters [Hash, ActionController::Parameters]
  def initialize(filters:)
    @filters = ToolInvocation.normalize_filter_params(filters)
    @relation = ToolInvocation.filter(@filters).reorder(nil)
  end

  # Executes bounded dashboard aggregate queries.
  #
  # @return [Hash]
  def call
    report = ToolUsageReport.call(
      since: nil,
      tool_names: observed_tool_names,
      relation: @relation
    )
    {
      filters: @filters,
      summary: summary,
      series: time_series,
      tools: report[:tools].select { |row| row[:call_count].positive? },
      duration_sample_limited: report[:duration_sample_limited],
      clients: client_breakdown,
      errors: error_breakdown,
      argument_signatures: argument_signature_breakdown,
      retention: retention
    }
  end

  private

  def summary
    total_calls = @relation.count
    error_count = @relation.errors.count
    durations = @relation.reorder(created_at: :desc)
                         .limit(PERCENTILE_SAMPLE_LIMIT)
                         .pluck(:duration_ms)
                         .sort
    {
      total_calls: total_calls,
      error_count: error_count,
      error_rate_percent: percentage(error_count, total_calls),
      active_clients: @relation.distinct.count(:client_id),
      average_ms: @relation.average(:duration_ms)&.round(1),
      p95_ms: percentile(durations, 0.95),
      average_result_size: @relation.where.not(result_size: nil).average(:result_size)&.round(1)
    }
  end

  def time_series
    hourly = @filters[:since_days] == "1"
    expression = hourly ?
      "DATE_FORMAT(created_at, '%Y-%m-%d %H:00:00')" :
      "DATE(created_at)"
    calls = bucket_counts(@relation, expression)
    errors = bucket_counts(@relation.errors, expression)

    time_series_points(hourly).map do |time|
      key = hourly ? time.strftime("%Y-%m-%d %H:00:00") : time.to_date.to_s
      {
        key: key,
        label: hourly ? time.strftime("%H:00") : time.strftime("%b %-d"),
        calls: calls.fetch(key, 0),
        errors: errors.fetch(key, 0)
      }
    end
  end

  def bucket_counts(relation, expression)
    relation.group(Arel.sql(expression)).count.transform_keys(&:to_s)
  end

  def time_series_points(hourly)
    now = Time.current
    if hourly
      24.downto(0).map { |offset| (now - offset.hours).beginning_of_hour }
    else
      days = @filters[:since_days].to_i
      days.downto(0).map { |offset| (now - offset.days).beginning_of_day }
    end
  end

  def observed_tool_names
    @relation.distinct.order(nil).pluck(:tool_name)
  end

  def client_breakdown
    counts = @relation.group(:client_id).count
    errors = @relation.errors.group(:client_id).count
    averages = @relation.group(:client_id).average(:duration_ms)
    last_seen = @relation.group(:client_id).maximum(:created_at)

    top_rows(counts).map do |client_id, call_count|
      {
        client_id: client_id,
        call_count: call_count,
        error_count: errors.fetch(client_id, 0),
        error_rate_percent: percentage(errors.fetch(client_id, 0), call_count),
        average_ms: averages[client_id]&.round(1),
        last_seen_at: last_seen[client_id]
      }
    end
  end

  def error_breakdown
    counts = @relation.errors.group(:error_category, :error_class).count
    top_rows(counts).map do |(category, error_class), count|
      {
        category: category.presence || "uncategorized",
        error_class: error_class.presence || "Unknown",
        count: count
      }
    end
  end

  def argument_signature_breakdown
    counts = @relation.group(:argument_keys).count
    top_rows(counts).map do |keys, count|
      { argument_keys: normalized_argument_keys(keys), count: count }
    end
  end

  def normalized_argument_keys(value)
    return value if value.is_a?(Array)

    JSON.parse(value.to_s)
  rescue JSON::ParserError
    []
  end

  def retention
    {
      days: AppSettings.tool_invocation_retention_days.to_i,
      expired_count: ToolInvocation.expired.count,
      oldest_at: ToolInvocation.minimum(:created_at)
    }
  end

  def top_rows(counts)
    counts.sort_by { |_key, count| -count }.first(BREAKDOWN_LIMIT)
  end

  def percentage(numerator, denominator)
    return 0.0 if denominator.zero?

    ((numerator.to_f / denominator) * 100).round(2)
  end

  def percentile(values, fraction)
    return if values.empty?

    values.fetch((fraction * values.length).ceil - 1)
  end
end
