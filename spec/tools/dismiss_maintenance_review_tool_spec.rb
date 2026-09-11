# frozen_string_literal: true

require "rails_helper"

RSpec.describe DismissMaintenanceReviewTool, type: :model do
  let(:tool) { described_class.new }
  let!(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" }) }
  let!(:row) do
    payload = { "entity_a" => { "entity_id" => 1 }, "entity_b" => { "entity_id" => 2 } }
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "dismiss-1",
      kind: "entity_merge",
      status: "active",
      signature: CompactionReviewService.signature_for("entity_merge", payload),
      payload: payload
    )
  end

  describe "class methods" do
    it ".tool_name returns dismiss_maintenance_review" do
      expect(described_class.tool_name).to eq("dismiss_maintenance_review")
    end

    it ".description returns a non-empty description" do
      expect(tool.description).to be_a(String)
      expect(tool.description).not_to be_empty
    end
  end

  describe "#call" do
    it "dismisses a queued suggestion" do
      result = tool.call(item_id: row.row_uuid, action: "dismiss", reason: "not a duplicate")

      expect(result[:success]).to be true
      expect(row.reload.status).to eq("dismissed")
    end

    it "ignores a queued suggestion" do
      result = tool.call(item_id: row.row_uuid, action: "ignore")

      expect(result[:success]).to be true
      expect(row.reload.status).to eq("ignored")
    end

    it "restores a dismissed suggestion" do
      tool.call(item_id: row.row_uuid, action: "dismiss")
      result = tool.call(item_id: row.row_uuid, action: "restore")

      expect(result[:success]).to be true
      expect(row.reload.status).to eq("active")
    end

    it "raises InvalidArgumentsError for an unknown action" do
      expect {
        tool.call(item_id: row.row_uuid, action: "delete")
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Invalid action/) do |error|
        expect(error.message).to include("dismiss")
        expect(error.message).to include("ignore")
        expect(error.message).to include("restore")
      end
    end

    it "raises ResourceNotFound for a missing suggestion" do
      expect {
        tool.call(item_id: "missing-item", action: "dismiss")
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /Suggestion not found/) do |error|
        expect(error.next_move).to include("`list_maintenance_review`")
        expect(error.next_move).to include("`dismiss_maintenance_review`")
      end
    end

    it "raises a generic OperationFailed for unexpected service failures" do
      allow(CompactionReviewService).to receive(:dismiss).and_return(
        { success: false, error: "secret boom" }
      )

      expect {
        tool.call(item_id: row.row_uuid, action: "dismiss")
      }.to raise_error(McpGraphMemErrors::OperationFailed, "The maintenance review could not be updated.") do |error|
        expect(error.message).not_to include("secret boom")
        expect(error.next_move).to include("`list_maintenance_review`")
      end
    end

    it "raises InternalServerError on unexpected errors without leaking the original message" do
      allow(CompactionReviewService).to receive(:dismiss).and_raise(StandardError.new("secret boom"))

      expect {
        tool.call(item_id: row.row_uuid, action: "dismiss")
      }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
        expect(error.message).not_to include("secret boom")
      end
    end

    it "re-raises Timeout::Error so the envelope can map category timeout" do
      allow(CompactionReviewService).to receive(:dismiss).and_raise(Timeout::Error.new("execution expired"))

      expect {
        tool.call(item_id: row.row_uuid, action: "dismiss")
      }.to raise_error(Timeout::Error, "execution expired")
    end
  end
end
