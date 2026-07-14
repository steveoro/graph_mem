# frozen_string_literal: true

class OperationProgressTracker
  attr_reader :operation_progress

  def initialize(operation_progress:, total:, phase: nil, message: nil, counters: {})
    @operation_progress = operation_progress
    @total = [ total.to_i, 0 ].max
    @current = 0
    @phase = phase
    @counters = counters
    @operation_progress.update_progress!(current: 0, total: @total, phase: @phase, message: message, counters: @counters)
    OperationProgressBroadcaster.call(@operation_progress)
  end

  def set_total!(total)
    @total = [ total.to_i, 0 ].max
    @operation_progress.update_progress!(current: @current, total: @total, phase: @phase, counters: @counters)
    OperationProgressBroadcaster.call(@operation_progress)
  end

  def increment!(by: 1, phase: @phase, message: nil, counters: @counters)
    @current += by.to_i
    @phase = phase
    @counters = counters
    @operation_progress.update_progress!(
      current: @current,
      total: @total,
      phase: @phase,
      message: message,
      counters: @counters
    )
    OperationProgressBroadcaster.call(@operation_progress)
  end

  def complete!(message: nil, counters: @counters)
    @current = @total
    @operation_progress.complete!(current: @current, message: message, counters: counters)
    OperationProgressBroadcaster.call(@operation_progress)
  end

  def fail!(error)
    @operation_progress.fail!(error)
    OperationProgressBroadcaster.call(@operation_progress)
  end
end
