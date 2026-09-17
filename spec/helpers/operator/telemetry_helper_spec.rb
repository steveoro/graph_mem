# frozen_string_literal: true

require "rails_helper"

RSpec.describe Operator::TelemetryHelper, type: :helper do
  describe "#telemetry_svg_points" do
    it "maps the series into bounded SVG coordinates" do
      series = [
        { calls: 0, errors: 0 },
        { calls: 10, errors: 2 }
      ]

      expect(
        helper.telemetry_svg_points(series, :calls, max_value: 10, width: 100, height: 50)
      ).to eq("0.0,50.0 100.0,0.0")
    end
  end

  describe "#telemetry_argument_signature" do
    it "renders keys without values" do
      expect(helper.telemetry_argument_signature(%w[limit query])).to eq("limit, query")
    end
  end
end
