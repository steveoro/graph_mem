# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationProgress, type: :model do
  describe ".start!" do
    it "captures a fixed baseline and creates a unique operation ID" do
      operation = described_class.start!(operation_type: "import", total_count: 3)

      expect(operation.operation_id).to be_present
      expect(operation.status).to eq("running")
      expect(operation.current_count).to eq(0)
      expect(operation.total_count).to eq(3)
    end
  end

  describe "#update_progress!" do
    it "does not allow current progress or total to regress" do
      operation = described_class.start!(operation_type: "export", total_count: 10)
      operation.update_progress!(current: 5, total: 10)
      operation.update_progress!(current: 2, total: 4)

      expect(operation.reload.current_count).to eq(5)
      expect(operation.total_count).to eq(10)
      expect(operation.percentage).to eq(50.0)
    end
  end

  it "completes at one hundred percent" do
    operation = described_class.start!(operation_type: "garbage_collection", total_count: 2)
    operation.complete!(current: 2)

    expect(operation.reload.status).to eq("completed")
    expect(operation.percentage).to eq(100.0)
  end
end
