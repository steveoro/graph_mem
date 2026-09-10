# frozen_string_literal: true

require "rails_helper"

RSpec.describe ListMaintenanceReviewTool, type: :model do
  let(:tool) { described_class.new }
  let!(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" }) }
  let!(:row) do
    payload = { "entity_a" => { "entity_id" => 11 }, "entity_b" => { "entity_id" => 22 } }
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "list-merge-1",
      kind: "entity_merge",
      status: "active",
      signature: CompactionReviewService.signature_for("entity_merge", payload),
      payload: payload
    )
  end

  describe "class methods" do
    it ".tool_name returns list_maintenance_review" do
      expect(described_class.tool_name).to eq("list_maintenance_review")
    end

    it ".description returns a non-empty description" do
      expect(tool.description).to be_a(String)
      expect(tool.description).not_to be_empty
    end
  end

  describe "#call" do
    it "returns paginated review rows including item_id" do
      result = tool.call

      expect(result[:report_type]).to eq("compaction_review")
      expect(result[:status]).to eq("active")
      expect(result[:page]).to eq(1)
      expect(result[:per_page]).to eq(ListMaintenanceReviewTool::PER_PAGE)
      expect(result[:total_count]).to be >= 1
      expect(result[:items].map { |item| item[:item_id] }).to include(row.row_uuid)
    end

    it "filters by kind" do
      result = tool.call(kind: "entity_merge")

      expect(result[:kind]).to eq("entity_merge")
      expect(result[:items]).not_to be_empty
      expect(result[:items].map { |item| item[:kind] }.uniq).to eq([ "entity_merge" ])
    end

    it "returns an empty item list when no rows match" do
      result = tool.call(report_type: "orphans")

      expect(result[:items]).to eq([])
      expect(result[:total_count]).to eq(0)
    end
  end
end
