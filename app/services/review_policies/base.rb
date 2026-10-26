# frozen_string_literal: true

module ReviewPolicies
  # Shared mechanics of a review policy (UI-5a). A policy picks candidate rows, then acts on them in
  # batches of POLICY_BATCH; each batch is one change set (`policy.<name>`, actor `policy:<name>`),
  # so "Undo run" undoes at most 200 rows at once. Each row is re-read under its row lock and
  # re-checked first: an operator action that landed in between wins and the row is skipped.
  #
  #   ReviewPolicies::Dangling.new.call # => { "acted" => 3, "skipped" => 0, "busy" => 0, "change_sets" => [...] }
  class Base
    POLICY_BATCH = 200
    TRANSIENT_ATTEMPTS = 3
    # Most rows one run may act on (Decision 12: hygiene policies drain a backlog gradually).
    PER_RUN = 500

    def self.policy_name
      name.demodulize.underscore
    end

    def initialize
      @stats = { "acted" => 0, "skipped" => 0, "busy" => 0, "change_sets" => [] }
    end

    # @return [Hash] counts and the change-set uuids of this run
    def call
      return @stats.merge("disabled" => true) unless enabled?

      candidates.each_slice(POLICY_BATCH) { |batch| run_batch(batch) }
      @stats
    end

    private

    def policy_name = self.class.policy_name

    def enabled?
      AppSettings.review_policy_enabled?(policy_name)
    end

    # @return [Array<MaintenanceReportRow>] at most per_run rows
    def candidates
      raise NotImplementedError
    end

    # Acts on one locked, freshly read row; returns false when it no longer qualifies.
    def act(_row)
      raise NotImplementedError
    end

    def verb = "resolved"

    def run_batch(batch)
      acted_before = @stats["acted"]
      uuid = Current.set(actor: "policy:#{policy_name}") do
        ChangeSet.record(kind: "policy.#{policy_name}") do |context|
          batch.each { |row| with_locked_row(row) }
          next unless context.id

          ChangeSet.where(id: context.id).update_all(summary: "policy #{policy_name}: #{verb} #{@stats['acted'] - acted_before} rows")
          context.uuid
        end
      end
      @stats["change_sets"] << uuid if uuid
    end

    def with_locked_row(row)
      attempts = 0
      begin
        attempts += 1
        acted = MaintenanceReportRow.transaction do
          locked = MaintenanceReportRow.lock.find_by(id: row.id)
          locked ? act(locked) : false
        end
        @stats[acted ? "acted" : "skipped"] += 1
      rescue ActiveRecord::StatementInvalid => e
        raise unless TransientDbError.busy?(e)
        retry if TransientDbError.retryable?(e) && attempts < TRANSIENT_ATTEMPTS

        @stats["busy"] += 1
      end
    end

    def change!(row, attrs, **options)
      CompactionReviewService.policy_change!(row, attrs, **options)
      true
    end
  end
end
