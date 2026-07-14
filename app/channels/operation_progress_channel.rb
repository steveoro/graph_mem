# frozen_string_literal: true

class OperationProgressChannel < ApplicationCable::Channel
  def subscribed
    operation_id = params[:operation_id].to_s
    operation = OperationProgress.find_by(operation_id: operation_id)
    return reject unless operation

    stream_from OperationProgressBroadcaster.stream_name(operation.operation_id)
    transmit operation.snapshot
  end
end
