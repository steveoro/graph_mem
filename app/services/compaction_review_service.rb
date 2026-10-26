# frozen_string_literal: true

# Loads, edits, and applies MaintenanceReportRow review items for the operator UI.
# Supports both dream-state compaction review queues and ad-hoc suggest_merges output.
class CompactionReviewService
  PER_PAGE = 50
  STATUSES = MaintenanceReportRow::STATUSES
  # MariaDB ER_CHECKREAD — a locking read found a row changed since the
  # transaction's consistent read was taken (snapshot isolation).
  CHECKREAD_ERRNO = TransientDbError::CHECKREAD_ERRNO
  # Bounded retries for a seed racing a concurrent apply/dismiss — the
  # index-narrowed candidate lock makes cross-entity collisions impossible,
  # so a few attempts cover the residual same-entity race.
  CHECKREAD_MAX_ATTEMPTS = 3

  extend ChangeRecording
  extend Queries
  extend Signatures

  class << self
    def latest_report(report_type: "compaction_review")
      MaintenanceReport.by_type(report_type).recent.first
    end

    def find_item(item_id, report_type: "compaction_review")
      MaintenanceReportRow.by_report_type(report_type).find_by(row_uuid: item_id)
    end

    def edit_item(item_id, edits, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      edits_hash = normalize_edits(edits)
      validate_edits!(row, edits_hash)
      row.update!(edited_payload: (row.edited_payload || {}).merge(edits_hash))
      { success: true }
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: e.message }
    end

    def apply(item_id, action_params = {}, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      record_review("apply", row) { apply_row(row, action_params) }
    end

    def dismiss(item_id, reason: nil, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      record_review("dismiss", row) do
        suppress(row)
        track_review_row(row) { row.update!(status: "dismissed", dismissed_at: Time.current, resolution_reason: reason) }
      end
      { success: true, message: "Suggestion dismissed" }
    end

    def bulk_dismiss(item_ids, reason: nil, report_type: "compaction_review")
      rows = MaintenanceReportRow.by_report_type(report_type).where(row_uuid: item_ids)
      record_review("bulk_dismiss") do
        rows.each do |row|
          suppress(row)
          track_review_row(row) { row.update!(status: "dismissed", dismissed_at: Time.current, resolution_reason: reason) }
        end
      end
      { success: true, message: "#{rows.size} suggestion(s) dismissed" }
    end

    # Bulk-apply iterates `apply` per row: non-actionable rows (already
    # dismissed/approved) are skipped rather than failing the batch, and the
    # summary keeps per-row failures visible for the operator.
    def bulk_apply(item_ids, report_type: "compaction_review")
      record_review("bulk_apply") { bulk_apply_rows(item_ids, report_type) }
    end

    def restore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      record_review("restore", row) do
        signatures = suppression_signatures(row)
        if signatures.any?
          scope = MaintenanceReportSuppression.where(report_type: row.report_type, signature: signatures)
          deleted = scope.map { |suppression| ChangeSet.snapshot_attributes(suppression) }
          scope.delete_all
          note_suppressions(deleted: deleted)
        end

        track_review_row(row) { row.update!(status: "active", dismissed_at: nil, applied_at: nil, resolution_reason: nil) }
      end
      { success: true, message: "Suggestion restored to active" }
    end

    def ignore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      record_review("ignore", row) { track_review_row(row) { row.update!(status: "ignored") } }
      { success: true, message: "Suggestion ignored" }
    end

    def seed_report(report_type:, source:, source_ref: nil, items:)
      return [] if items.empty?

      # Retry the whole transaction — not the statement — on ER_CHECKREAD:
      # under MariaDB snapshot isolation the read view is fixed at the
      # transaction's first consistent read, so re-running the same locking
      # read inside it would fail again. A fresh transaction sees the state
      # the concurrent apply/dismiss settled into.
      with_checkread_retry do
        MaintenanceReport.transaction do
          report = MaintenanceReport.create!(
            report_type: report_type,
            data: {
              source: source,
              source_ref: source_ref,
              count: 0,
              seeded_at: Time.current.iso8601
            }
          )

          classifier = ReviewRowClassifier.new
          limits = SeedLimits.new(report_type: report_type, source: source, source_ref: source_ref)
          candidates = seed_candidates(items, report_type, classifier)
          created_rows = limits.admit(candidates).map do |candidate|
            MaintenanceReportRow.create!(maintenance_report_id: report.id, report_type: report_type, status: "active",
                                         **candidate.symbolize_keys)
          end

          report.update!(data: report.data.merge(count: created_rows.size, **limits.stats))
          created_rows
        end
      end
    end

    # The items that would become new rows, classified, in their original order. The checks run
    # as they always have (suppressed, already pending, absorbed into a pending stale_memory row);
    # a signature seen earlier in the same call counts as pending.
    def seed_candidates(items, report_type, classifier)
      seen = Set.new
      items.filter_map do |item|
        item = normalize_item(item)
        kind = item["kind"]
        next if kind.blank?

        payload = item.except("id")
        signature = signature_for(kind, payload)
        next if signature.blank? || seen.include?(signature)
        next if MaintenanceReportSuppression.suppressed?(report_type, signature)
        next if MaintenanceReportRow.by_report_type(report_type).pending.where(signature: signature).exists?
        next if absorb_stale_memory?(report_type, payload, classifier)

        seen << signature
        { "row_uuid" => item["id"] || SecureRandom.uuid, "kind" => kind, "payload" => payload, "signature" => signature }
          .merge(classifier.classify(kind: kind, payload: payload, row_uuid: item["id"]).stringify_keys)
      end
    end

    # stale_memory rows dedupe per (entity, signal): a re-detection whose
    # observation set grew on an already-queued entity ABSORBS into the
    # pending row — union of obs ids, refreshed signature — instead of
    # stacking a second row for the same diagnosis. Only ACTIVE rows absorb:
    # merging into an ignored/dismissed row would hide the new obs behind a
    # row the operator already set aside. A merged set that was suppressed
    # before is never resurrected (the row keeps its previous obs set).
    # Returns true when the item was absorbed — no new row is created.
    def absorb_stale_memory?(report_type, payload, classifier = ReviewRowClassifier.new)
      return false unless payload[:kind] == "stale_memory"

      entity_id = payload[:entity_id].to_i
      signal = payload[:signal].to_s
      return false if entity_id.zero? || signal.blank?

      # The candidate read IS the locking read: under MariaDB snapshot
      # isolation a plain read followed by FOR UPDATE on a row changed in
      # between aborts the statement with ER_CHECKREAD (1020). Locking first
      # reads the CURRENT committed state and holds it — no read-then-lock
      # window for a concurrent apply/dismiss to strike through.
      # effective_payload is a plain string-keyed hash (JSON column) — index
      # it with strings, not symbols.
      locked_rows = stale_memory_candidates(report_type, entity_id).select do |row|
        row.effective_payload["entity_id"].to_i == entity_id &&
          row.effective_payload["signal"].to_s == signal
      end
      # A row settled (approved/dismissed) between the lock and this merge is
      # never merged into nor retired — its obs ids were already acted on.
      locked_rows.select!(&:active?)
      return false if locked_rows.empty?

      # The EARLIEST active row absorbs — it holds the original queue
      # position.
      keep = locked_rows.min_by(&:id)

      merged_ids = (locked_rows.flat_map { |r| Array(r.effective_payload["observation_ids"]).map(&:to_i) } +
                    Array(payload[:observation_ids]).map(&:to_i)).uniq.sort
      merged_payload = keep.effective_payload
                           .merge(payload.slice("entity_name", "reason"))
                           .merge(observation_ids: merged_ids)
      merged_sig = signature_for("stale_memory", merged_payload)

      if merged_sig.present? && merged_sig != keep.signature &&
         !MaintenanceReportSuppression.suppressed?(report_type, merged_sig)
        if keep.edited_payload.present?
          keep.update!(signature: merged_sig,
                       edited_payload: keep.edited_payload.merge("observation_ids" => merged_ids))
        else
          keep.update!(signature: merged_sig, payload: merged_payload)
        end
      end
      # The merged observation set changes the row's impact: classify it again.
      keep.update_columns(classifier.classify(keep))
      # Pre-merge duplicates for the same diagnosis are retired into the
      # row that absorbed them (audit kept via the ignored status).
      (locked_rows - [ keep ]).each { |row| row.update!(status: "ignored") }
      true
    end

    def suppressed?(kind, payload, report_type: "compaction_review")
      signature = signature_for(kind, payload)
      return false if signature.blank?

      # An expired row doesn't block on its own: its (expiring) suppression decides.
      MaintenanceReportSuppression.suppressed?(report_type, signature) ||
        MaintenanceReportRow.by_report_type(report_type).where(signature: signature).where.not(status: "expired").exists?
    end

    private

    def apply_row(row, action_params)
      # Dismissed/approved rows must never apply: rescan review relies on
      # "dismissed = no longer actionable" to retire stale proposals safely.
      unless row.status.in?(%w[active ignored])
        return { success: false, error: "Suggestion is not actionable (status: #{row.status})" }
      end

      # Advisory membership lock FIRST (the advisory-first rule — part_of
      # applies call sync! which takes it anyway, so hoisting keeps GET_LOCK
      # outside every transaction), then the row lock + status re-check so
      # a racing dismiss/rescan edit can never be overwritten by the apply.
      # LockTimeout propagates: callers map it to the transient "retry
      # shortly" concurrency envelope (tool category: concurrency, web
      # flash "retry shortly") — never an operator escalation.
      ProjectMembership.with_membership_lock do
        row.with_lock do
          row.reload
          unless row.status.in?(%w[active ignored])
            return { success: false, error: "Suggestion is not actionable (status: #{row.status})" }
          end

          result = CompactionReviewApplier.apply(row, action_params)
          if result[:success]
            track_review_row(row) { row.update!(status: "approved", applied_at: Time.current) }
          else
            row.update!(resolution_reason: result[:error])
          end
          result
        end
      end
    end

    def bulk_apply_rows(item_ids, report_type)
      rows = MaintenanceReportRow.by_report_type(report_type).where(row_uuid: item_ids)
      return { success: false, error: "No suggestions selected" } if rows.empty?

      applied = 0
      skipped = 0
      not_bulk = 0
      failed = []
      rows.each do |row|
        unless row.status.in?(%w[active ignored])
          skipped += 1
          next
        end
        # Only safe kinds are applied in bulk: merges, deletes, moves and contradictions are
        # applied one by one (and a merge mixed with other writes couldn't be undone).
        unless ReviewRowClassifier::SAFE_BULK_KINDS.include?(row.kind)
          not_bulk += 1
          next
        end

        result = apply(row.row_uuid, {}, report_type: report_type)
        if result[:success]
          applied += 1
        else
          failed << "#{row.kind} #{row.row_uuid.to_s.first(8)}: #{result[:error]}"
        end
      end

      message = "#{applied} suggestion(s) applied"
      message += ", #{skipped} skipped (not actionable)" if skipped.positive?
      message += ", #{not_bulk} skipped (not bulk-applicable: apply one by one)" if not_bulk.positive?
      message += "; #{failed.size} failed: #{failed.first(3).join('; ')}" if failed.any?
      { success: failed.empty?, message: message }
    end

    # Locking read of the active stale_memory rows for this entity, in
    # deterministic id order. `stale_entity_id` is an indexed generated
    # column (COALESCE of edited/payload entity_id — same semantics as
    # effective_payload). FORCE INDEX pins the FOR UPDATE to that index:
    # the optimizer otherwise prefers broader indexes (e.g. report_type),
    # which would X-lock every scanned queue row — the exact blocking
    # behavior this index exists to remove. A seed locks only the rows it
    # can absorb into; seeds on different entities can never collide. The
    # full entity+signal match still runs in Ruby on the locked set.
    def stale_memory_candidates(report_type, entity_id)
      MaintenanceReportRow.by_report_type(report_type)
                          .active
                          .where(kind: "stale_memory", stale_entity_id: entity_id)
                          .order(:id)
                          .lock(true)
                          .from("#{MaintenanceReportRow.quoted_table_name} FORCE INDEX (index_mrr_stale_candidates)")
                          .to_a
    end

    # MariaDB 11.8 raises ER_CHECKREAD (errno 1020) when a locking read finds
    # a row changed since the transaction's consistent read was taken, and
    # InnoDB kills a waiting transaction with ER_LOCK_DEADLOCK (1213 —
    # ActiveRecord::Deadlocked, a TransactionRollbackError under
    # StatementInvalid) when two writers hold locks the other needs. Both
    # are transient forms of the same "read-write during jobs must block
    # or queue, never race" collision: retry around the WHOLE transaction
    # with a small backoff; the fresh read view sees the settled row
    # states and the lock order re-forms.
    def with_checkread_retry
      attempts = 0
      begin
        yield
      rescue ActiveRecord::StatementInvalid => e
        raise unless TransientDbError.retryable?(e) && attempts < CHECKREAD_MAX_ATTEMPTS - 1

        attempts += 1
        sleep(0.05 * attempts)
        retry
      end
    end

    def validate_edits!(row, edits)
      edits = (edits || {}).with_indifferent_access.compact
      return if edits.empty?

      case row.kind
      when "entity_merge"
        validate_entity_ids!([ edits[:source_id], edits[:target_id] ].compact)
      when "relationship_proposal"
        validate_entity_ids!([ edits[:from_id], edits[:to_id] ].compact)
        validate_relation_type!(edits[:relation_type]) if edits[:relation_type].present?
      when "orphan_parent"
        validate_entity_ids!([ edits[:parent_id] ].compact) if edits[:parent_id].present?
      when "move_observation"
        validate_observation_id!(edits[:observation_id]) if edits[:observation_id].present?
        validate_entity_ids!([ edits[:target_entity_id] || edits[:target_id] ].compact) if (edits[:target_entity_id] || edits[:target_id]).present?
      when "delete_observation"
        validate_observation_id!(edits[:observation_id]) if edits[:observation_id].present?
      when "reparent_entity"
        validate_entity_ids!([ edits[:entity_id] || edits[:node_id], edits[:parent_id] ].compact)
      end
    end

    def validate_entity_ids!(ids)
      ids.each do |id|
        next if MemoryEntity.exists?(id: id.to_i)

        record = MaintenanceReportRow.new
        record.errors.add(:base, "Entity ##{id} does not exist")
        raise ActiveRecord::RecordInvalid.new(record)
      end
    end

    def validate_relation_type!(relation_type)
      # Gate on the canonical vocabulary, not the discovery proposal
      # allowlist: seeded rows legitimately carry types like `belongs_to`
      # or `routes_to` that RelationshipDiscoveryStrategy never proposes
      # itself.
      return if GraphVocabulary::RELATION_TYPES.include?(relation_type.to_s)

      record = MaintenanceReportRow.new
      record.errors.add(:base, "Invalid relation type: #{relation_type}")
      raise ActiveRecord::RecordInvalid.new(record)
    end

    def validate_observation_id!(observation_id)
      return if MemoryObservation.exists?(id: observation_id.to_i)

      record = MaintenanceReportRow.new
      record.errors.add(:base, "Observation ##{observation_id} does not exist")
      raise ActiveRecord::RecordInvalid.new(record)
    end

    def normalize_item(item)
      hash = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item.to_h
      hash.deep_stringify_keys.with_indifferent_access
    end

    def normalize_edits(edits)
      hash = if edits.respond_to?(:to_unsafe_h)
               edits.to_unsafe_h
      elsif edits.respond_to?(:to_h)
               edits.to_h
      else
               edits || {}
      end
      hash.deep_stringify_keys.with_indifferent_access.compact_blank
    end

    def suppress(row)
      created = suppression_signatures(row).filter_map do |signature|
        suppression = MaintenanceReportSuppression.create_or_find_by!(
          report_type: row.report_type,
          signature: signature
        ) do |s|
          s.kind = row.kind
          s.dismissed_at = Time.current
          s.reason = row.resolution_reason
        end
        suppression if suppression.previously_new_record?
      end
      note_suppressions(created: created)
    end

    # An edit can change the signature (relation_type, source/target ids), while
    # row.signature keeps the generator's original. Suppress both, so the original
    # proposal stays blocked after MaintenanceReportRowCleanupJob prunes the row.
    def suppression_signatures(row)
      [ signature_for(row.kind, row.effective_payload), row.signature ].compact_blank.uniq
    end
  end
end
