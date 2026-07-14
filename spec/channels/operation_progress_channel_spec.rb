# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationProgressChannel, type: :channel do
  it "subscribes to a persisted operation stream" do
    operation = OperationProgress.start!(operation_type: "import", total_count: 1)

    subscribe(operation_id: operation.operation_id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(OperationProgressBroadcaster.stream_name(operation.operation_id))
  end

  it "rejects an unknown operation" do
    subscribe(operation_id: "missing-operation")

    expect(subscription).to be_rejected
  end
end
