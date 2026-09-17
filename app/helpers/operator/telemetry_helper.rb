# frozen_string_literal: true

module Operator
  # Formatting and accessible SVG geometry for telemetry analytics.
  module TelemetryHelper
    # Returns the shared vertical chart scale for calls and errors.
    #
    # @param series [Array<Hash>]
    # @return [Integer]
    def telemetry_chart_max(series)
      [ series.flat_map { |point| [ point[:calls], point[:errors] ] }.max.to_i, 1 ].max
    end

    # Converts a series metric to SVG polyline coordinates.
    #
    # @param series [Array<Hash>]
    # @param metric [Symbol] :calls or :errors
    # @param max_value [Numeric] shared chart maximum
    # @param width [Integer]
    # @param height [Integer]
    # @return [String]
    def telemetry_svg_points(series, metric, max_value:, width: 720, height: 180)
      denominator = [ series.length - 1, 1 ].max
      series.map.with_index do |point, index|
        x = (index.to_f / denominator * width).round(2)
        y = (height - (point.fetch(metric).to_f / max_value * height)).round(2)
        "#{x},#{y}"
      end.join(" ")
    end

    # Formats a millisecond duration for compact tables and stat chips.
    #
    # @param value [Numeric, nil]
    # @return [String]
    def telemetry_duration(value)
      value.nil? ? "—" : "#{number_with_delimiter(value)} ms"
    end

    # Formats a percentage consistently.
    #
    # @param value [Numeric, nil]
    # @return [String]
    def telemetry_percentage(value)
      number_to_percentage(value.to_f, precision: 2, strip_insignificant_zeros: true)
    end

    # Formats the privacy-safe argument-key signature.
    #
    # @param keys [Array<String>]
    # @return [String]
    def telemetry_argument_signature(keys)
      keys.present? ? keys.join(", ") : t("operator.telemetry.argument_signatures.none")
    end

    # Renders a localized outcome badge.
    #
    # @param outcome [String]
    # @return [ActiveSupport::SafeBuffer]
    def telemetry_outcome_badge(outcome)
      css = outcome == "ok" ? "dashboard-badge--completed" : "dashboard-badge--failed"
      content_tag(
        :span,
        t("operator.telemetry.outcomes.#{outcome}"),
        class: "dashboard-badge #{css}"
      )
    end
  end
end
