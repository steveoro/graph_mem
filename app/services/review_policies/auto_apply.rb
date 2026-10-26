# frozen_string_literal: true

module ReviewPolicies
  # Applies rows through CompactionReviewService.apply (membership lock first, then the row lock:
  # the advisory-first rule), inside the policy's change set. Off by default (Settings).
  #
  # Hard rule, whatever the settings or the candidate query say: only SAFE_BULK_KINDS are ever
  # applied; destructive and choice kinds are refused row by row.
  class AutoApply < Base
    def initialize
      super
      @stats["refused"] = 0
    end

    private

    def verb = "applied"

    # @return [Boolean] true when the hard rule allows applying this kind
    def applicable_kind?(kind)
      ReviewRowClassifier::SAFE_BULK_KINDS.include?(kind) &&
        !ReviewRowClassifier::DESTRUCTIVE_KINDS.include?(kind) && !ReviewRowClassifier::CHOICE_KINDS.include?(kind)
    end

    def run_batch(batch)
      allowed, refused = batch.partition { |row| applicable_kind?(row.kind) }
      @stats["refused"] += refused.size
      super(allowed) if allowed.any?
    rescue ProjectMembership::LockTimeout
      # Another import, backfill or merge holds the lock: this step ends for this run, never the job.
      @stats["busy"] += 1
      @stopped = true
    end

    def candidates
      eligible.order(priority: :desc, id: :asc).limit(self.class::PER_RUN).to_a
    end

    # Applies one row; the service takes its own locks and re-checks the status.
    def with_locked_row(row)
      return if @stopped
      return @stats["refused"] += 1 unless applicable_kind?(row.kind)

      result = CompactionReviewService.apply(row.row_uuid, {}, report_type: row.report_type)
      @stats[result[:success] ? "acted" : "skipped"] += 1
    rescue ActiveRecord::StatementInvalid => e
      raise unless TransientDbError.busy?(e)

      @stats["busy"] += 1
    end
  end
end
