# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplyMaintenanceReviewTool, type: :model do
  let(:tool) { described_class.new }
  let!(:source) { MemoryEntity.create!(name: "ApplySource", entity_type: "Task") }
  let!(:target) { MemoryEntity.create!(name: "ApplyTarget", entity_type: "Task") }
  let!(:report) { MaintenanceReport.create!(report_type: "compaction_review", data: { "source" => "test" }) }
  let!(:merge_row) do
    payload = {
      "entity_a" => { "entity_id" => source.id, "name" => source.name, "entity_type" => source.entity_type },
      "entity_b" => { "entity_id" => target.id, "name" => target.name, "entity_type" => target.entity_type }
    }
    MaintenanceReportRow.create!(
      maintenance_report: report,
      report_type: "compaction_review",
      row_uuid: "apply-merge-1",
      kind: "entity_merge",
      status: "active",
      signature: CompactionReviewService.signature_for("entity_merge", payload),
      payload: payload
    )
  end

  describe "class methods" do
    it ".tool_name returns apply_maintenance_review" do
      expect(described_class.tool_name).to eq("apply_maintenance_review")
    end

    it ".description returns a non-empty description" do
      expect(tool.description).to be_a(String)
      expect(tool.description).not_to be_empty
    end
  end

  describe "#call" do
    it "applies a queued merge" do
      result = tool.call(item_id: merge_row.row_uuid, action_params: { "source_id" => source.id, "target_id" => target.id })

      expect(result[:success]).to be true
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
      expect(merge_row.reload.status).to eq("approved")
    end

    it "returns a dry-run preview without applying" do
      result = tool.call(item_id: merge_row.row_uuid, dry_run: true)

      expect(result[:dry_run]).to be true
      expect(result[:item_id]).to eq(merge_row.row_uuid)
      expect(MemoryEntity.find_by(id: source.id)).to be_present
      expect(merge_row.reload.status).to eq("active")
    end

    it "raises ResourceNotFound for a missing suggestion" do
      expect {
        tool.call(item_id: "missing-item")
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /Suggestion not found/) do |error|
        expect(error.next_move).to include("`list_maintenance_review`")
        expect(error.next_move).to include("`apply_maintenance_review`")
      end
    end

    it "raises InvalidArgumentsError when the review cannot be applied as given" do
      expect {
        tool.call(item_id: merge_row.row_uuid, action_params: { "source_id" => source.id, "target_id" => source.id })
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /into itself/) do |error|
        expect(error.message).to include("`apply_maintenance_review`")
        expect(error.message).to include("`dismiss_maintenance_review`")
      end
    end

    it "raises a generic OperationFailed for unexpected apply failures" do
      allow(CompactionReviewService).to receive(:apply).and_return(
        { success: false, error: "Failed to create relation: secret boom" }
      )

      expect {
        tool.call(item_id: merge_row.row_uuid)
      }.to raise_error(McpGraphMemErrors::OperationFailed, "The maintenance review could not be applied.") do |error|
        expect(error.message).not_to include("secret boom")
        expect(error.next_move).to include("`list_maintenance_review`")
      end
    end

    it "raises InternalServerError on unexpected errors without leaking the original message" do
      allow(CompactionReviewService).to receive(:find_item).and_raise(StandardError.new("secret boom"))

      expect {
        tool.call(item_id: merge_row.row_uuid)
      }.to raise_error(McpGraphMemErrors::InternalServerError, "An unexpected error occurred.") do |error|
        expect(error.message).not_to include("secret boom")
      end
    end

    it "re-raises Timeout::Error so the envelope can map category timeout" do
      allow(CompactionReviewService).to receive(:find_item).and_raise(Timeout::Error.new("execution expired"))

      expect {
        tool.call(item_id: merge_row.row_uuid)
      }.to raise_error(Timeout::Error, "execution expired")
    end
  end
end
