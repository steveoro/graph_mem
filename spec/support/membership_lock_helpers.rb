# frozen_string_literal: true

# Helpers for specs around ProjectMembership's advisory lock.
module MembershipLockHelpers
  # Observes GET_LOCK via sql.active_record and returns how many
  # transactions were open ABOVE the spec-fixture baseline when the lock
  # was first acquired — 0 means "advisory lock BEFORE the transaction"
  # (the advisory-first rule); >0 means a mid-transaction GET_LOCK, which
  # deadlocks against the backfill.
  def open_transactions_at_get_lock
    baseline = ActiveRecord::Base.connection.open_transactions
    count = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      count ||= ActiveRecord::Base.connection.open_transactions if payload[:sql].to_s.include?("GET_LOCK")
    end
    yield
    count - baseline
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # true while NO session holds the membership advisory lock. Uncached:
  # a query-cached IS_USED_LOCK could mask a leaked lock (that cache
  # poisoning is exactly what conn.uncached in with_membership_lock
  # guards against).
  def membership_lock_free?
    conn = ActiveRecord::Base.connection
    name = ProjectMembership.lock_name(conn)
    conn.uncached { conn.select_value("SELECT IS_USED_LOCK(#{conn.quote(name)})") }.nil?
  end
end

RSpec.configure do |config|
  config.include MembershipLockHelpers
end
