# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScanProjectStatusTool, type: :model do
  let(:tool) { described_class.new }

  describe "class methods" do
    describe ".tool_name" do
      it "returns the correct tool name" do
        expect(described_class.tool_name).to eq("scan_project_status")
      end
    end

    describe ".description" do
      it "returns a non-empty description" do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe "#call" do
    it "raises ResourceNotFound when the scan does not exist" do
      expect {
        tool.call(scan_id: "missing-scan-id")
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /not found/) do |error|
        expect(error).not_to be_a(McpGraphMemErrors::InternalServerError)
        expect(error.next_move).to include("scan_project")
        expect(error.next_move).to include("scan_project_status")
      end
    end

    it "returns a status and progress hash for an existing scan" do
      operation = OperationProgress.start!(
        operation_type: "project_scan",
        operation_id: "existing-scan-id",
        total_count: 10,
        message: "Scanning"
      )
      operation.update_progress!(current: 4, total: 10, message: "Walking files")

      result = tool.call(scan_id: operation.operation_id)

      expect(result).to include(
        scan_id: operation.operation_id,
        status: "running",
        message: "Walking files"
      )
      expect(result[:progress]).to include(current: 4, total: 10)
      expect(result[:status]).not_to eq("not_found")
    end

    it "raises a generic InternalServerError on unexpected failures" do
      allow(OperationProgress).to receive(:find_by).and_raise(StandardError.new("secret db failure"))

      expect {
        tool.call(scan_id: "any-scan")
      }.to raise_error(McpGraphMemErrors::InternalServerError, /unexpected error/) do |error|
        expect(error.message).not_to include("secret db failure")
      end
    end
  end
end
