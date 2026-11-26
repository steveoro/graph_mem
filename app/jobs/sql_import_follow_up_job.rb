# frozen_string_literal: true

# Runs SqlImport::FollowUp for an SQL import, after it committed and released the membership lock:
# queued by the import page and by graph_mem:import_sql once the executor returned. While the
# embeddings lock is busy (another backfill), it runs again after LOCK_RETRY_WAIT, up to
# MAX_ATTEMPTS times; the last attempt goes on without the backfill and the report says so.
class SqlImportFollowUpJob < ApplicationJob
  queue_as :default

  LOCK_RETRY_WAIT = 1.minute
  MAX_ATTEMPTS = 5

  # @param operation_id [String] the import's operation id
  # @param attempt [Integer]
  # @return [Symbol, nil] :done, :deferred, or nil when there is no such SQL import or it is done
  def perform(operation_id, attempt = 1)
    operation = OperationProgress.find_by(operation_id: operation_id, operation_type: "import")
    return unless operation && operation.details.to_h["format"] == "sql"
    return if operation.details.dig("follow_up", "status") == "done"

    outcome = SqlImport::FollowUp.call(operation, last_attempt: attempt >= MAX_ATTEMPTS)
    self.class.set(wait: LOCK_RETRY_WAIT).perform_later(operation_id, attempt + 1) if outcome == :deferred
    outcome
  end
end
