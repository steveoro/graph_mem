# frozen_string_literal: true

require "rails_helper"

RSpec.describe GetMaintenanceReportsTool, type: :model do
  let(:tool) { described_class.new }

  before { MaintenanceReport.delete_all }
  after { MaintenanceReport.delete_all }

  describe "class methods" do
    it "has the correct tool name" do
      expect(described_class.tool_name).to eq("get_maintenance_reports")
    end

    it "exposes an enum of valid report types in its schema" do
      schema = described_class.input_schema_to_json
      expect(schema[:properties][:report_type][:enum]).to include("compaction_review")
    end
  end

  describe "#call" do
    context "with no reports" do
      it "returns an empty list" do
        result = tool.call
        expect(result[:reports]).to eq([])
        expect(result[:total]).to eq(0)
      end
    end

    context "with reports of multiple types" do
      before do
        MaintenanceReport.create!(report_type: "orphans", data: { count: 2 })
        MaintenanceReport.create!(report_type: "compaction_review", data: { count: 1, items: [ { kind: "entity_merge" } ] })
      end

      it "returns the latest report of each type when no filter is given" do
        result = tool.call

        types = result[:reports].map { |r| r[:report_type] }
        expect(types).to include("orphans", "compaction_review")
      end

      it "filters by report_type" do
        result = tool.call(report_type: "compaction_review")

        expect(result[:total]).to eq(1)
        expect(result[:reports].first[:report_type]).to eq("compaction_review")
        expect(result[:reports].first[:data]["items"]).to be_present
      end

      it "raises on an unknown report_type" do
        expect {
          tool.call(report_type: "bogus")
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Unknown report_type/) do |error|
          expect(error.message).to include("Valid types:")
          MaintenanceReport::REPORT_TYPES.each { |type| expect(error.message).to include(type) }
          expect(error.message).to include("`get_maintenance_reports`")
          expect(error.message).to include("`list_maintenance_review`")
        end
      end
    end

    context "limit handling" do
      before do
        3.times { |i| MaintenanceReport.create!(report_type: "orphans", data: { count: i }) }
      end

      it "caps the number of returned reports" do
        result = tool.call(report_type: "orphans", limit: 2)
        expect(result[:total]).to eq(2)
      end

      it "orders reports most-recent first" do
        result = tool.call(report_type: "orphans", limit: 3)
        created_ats = result[:reports].map { |r| r[:created_at] }
        expect(created_ats).to eq(created_ats.sort.reverse)
      end
    end

    context "error handling" do
      it "raises InternalServerError on unexpected errors without leaking the original message" do
        allow(MaintenanceReport).to receive(:by_type).and_raise(StandardError.new("secret boom"))

        expect {
          tool.call(report_type: "orphans")
        }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
          expect(error.message).not_to include("secret boom")
        end
      end

      it "re-raises Timeout::Error so the envelope can map category timeout" do
        allow(MaintenanceReport).to receive(:by_type).and_raise(Timeout::Error.new("execution expired"))

        expect {
          tool.call(report_type: "orphans")
        }.to raise_error(Timeout::Error, "execution expired")
      end
    end
  end
end
