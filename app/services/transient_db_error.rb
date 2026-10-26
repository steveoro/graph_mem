# frozen_string_literal: true

# Classifies the MariaDB errors that mean "another writer got there first" rather than a bug.
#
#   TransientDbError.retryable?(error) # a fresh transaction can succeed (deadlock, ER_CHECKREAD)
#   TransientDbError.busy?(error)      # answer "busy, retry shortly" (adds lock-wait timeouts)
module TransientDbError
  # MariaDB ER_CHECKREAD: a locking read found a row changed since the transaction's read view
  # (snapshot isolation). The same statement fails again in the same transaction.
  CHECKREAD_ERRNO = 1020

  module_function

  # @param error [Exception]
  # @return [Boolean]
  def checkread?(error)
    cause = error.cause
    cause.respond_to?(:error_number) && cause.error_number == CHECKREAD_ERRNO
  end

  # @param error [Exception]
  # @return [Boolean] true when retrying in a new transaction can succeed
  def retryable?(error)
    error.is_a?(ActiveRecord::Deadlocked) || checkread?(error)
  end

  # @param error [Exception]
  # @return [Boolean] true when the caller should be told to retry shortly
  def busy?(error)
    retryable?(error) || error.is_a?(ActiveRecord::LockWaitTimeout)
  end
end
