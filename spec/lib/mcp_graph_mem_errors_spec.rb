# frozen_string_literal: true

require "rails_helper"

RSpec.describe McpGraphMemErrors do
  describe McpGraphMemErrors::ResourceNotFound do
    it "defaults to not_found and is not retriable" do
      error = described_class.new("Entity with ID=1 not found.")

      expect(error.message).to eq("Entity with ID=1 not found.")
      expect(error.category).to eq("not_found")
      expect(error.retriable).to be(false)
      expect(error.next_move).to include("`search_entities`")
      expect(error.next_move).to include("`list_entities`")
    end

    it "accepts next_move overrides" do
      error = described_class.new(
        "Scan not found.",
        next_move: "Call scan_project to start a scan, then retry with that scan_id."
      )

      expect(error.next_move).to include("scan_project")
    end
  end

  describe McpGraphMemErrors::InternalServerError do
    it "defaults to system_error and is not retriable" do
      error = described_class.new("boom")

      expect(error.category).to eq("system_error")
      expect(error.retriable).to be(false)
      expect(error.next_move).to match(/do not retry blindly/i)
    end
  end

  describe McpGraphMemErrors::OperationFailed do
    it "defaults to system_error" do
      error = described_class.new("Failed to delete")

      expect(error.category).to eq("system_error")
      expect(error.retriable).to be(false)
    end
  end
end
