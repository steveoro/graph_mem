# frozen_string_literal: true

class OperationProgressBroadcaster
  STREAM_PREFIX = "operation_progress"

  def self.call(operation_progress)
    new(operation_progress).call
  end

  def initialize(operation_progress)
    @operation_progress = operation_progress
  end

  def call
    ActionCable.server.broadcast(stream_name, @operation_progress.snapshot)
    @operation_progress.snapshot
  end

  def self.stream_name(operation_id)
    "#{STREAM_PREFIX}_#{operation_id}"
  end

  private

  def stream_name
    self.class.stream_name(@operation_progress.operation_id)
  end
end
