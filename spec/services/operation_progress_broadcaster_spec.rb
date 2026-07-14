# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationProgressBroadcaster do
  it "broadcasts the persisted snapshot on the operation stream" do
    operation = OperationProgress.start!(operation_type: "import", total_count: 1)

    expect(ActionCable.server).to receive(:broadcast).with(
      described_class.stream_name(operation.operation_id),
      hash_including(operation_id: operation.operation_id, current: 0, total: 1)
    )

    described_class.call(operation)
  end
end
