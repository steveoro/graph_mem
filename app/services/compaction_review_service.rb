# frozen_string_literal: true

# Loads, edits, and applies MaintenanceReportRow review items for the operator UI.
# Supports both dream-state compaction review queues and ad-hoc suggest_merges output.
class CompactionReviewService
  PER_PAGE = 50
  STATUSES = MaintenanceReportRow::STATUSES

  class << self
    def latest_report(report_type: "compaction_review")
      MaintenanceReport.by_type(report_type).recent.first
    end

    def items(report: nil, report_type: "compaction_review", status: "active", kind: nil, page: 1, q: nil)
      scope = MaintenanceReportRow.by_report_type(report_type)
      scope = scope.where(maintenance_report_id: report.id) if report
      scope = scope.by_status(status) if status.present?
      scope = scope.by_kind(kind) if kind.present?

      rows = scope.to_a
      rows = filter_by_query(rows, q) if q.present?
      sorted = sort_rows(rows)
      Kaminari.paginate_array(sorted).page(page).per(PER_PAGE)
    end

    def active_count(report_type: "compaction_review")
      MaintenanceReportRow.by_report_type(report_type).active.count
    end

    # Tab counts mirror what the list shows: status counts respect the kind
    # filter, kind counts respect the status filter (otherwise the badge on
    # a tab disagrees with the list it opens).
    def status_counts(report_type: "compaction_review", kind: nil)
      scope = MaintenanceReportRow.by_report_type(report_type)
      scope = scope.by_kind(kind) if kind.present?
      scope.group(:status).count
    end

    def kind_counts(report_type: "compaction_review", status: nil)
      scope = MaintenanceReportRow.by_report_type(report_type)
      scope = scope.by_status(status) if status.present?
      scope.group(:kind).count
    end

    # For `delete_entity` rows on the page: how many children are queued
    # for deletion themselves vs would be left parentless. entity.destroy!
    # removes observations + relations via dependent: :destroy, but child
    # ENTITIES keep living without a parent — applying one row NEVER
    # cascades, by (possibly temporary) design choice: the operator
    # approved one deletion, not a subtree wipe. If lone-seeded subtree
    # deletions turn out common, revisit with a separate "apply with
    # children" action rather than a default cascade.
    def delete_children_info(report_type:, items:)
      ids = items.filter_map { |row| row.kind == "delete_entity" ? delete_entity_target(row) : nil }.uniq
      return {} if ids.empty?

      queued = delete_entity_targets(report_type: report_type)
      info = {}
      MemoryRelation.where(relation_type: "part_of", to_entity_id: ids)
                    .pluck(:to_entity_id, :from_entity_id).each do |parent_id, child_id|
        slot = (info[parent_id] ||= { queued: 0, parentless: 0 })
        queued.include?(child_id) ? slot[:queued] += 1 : slot[:parentless] += 1
      end
      info
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
            row.update!(status: "approved", applied_at: Time.current)
          else
            row.update!(resolution_reason: result[:error])
          end
          result
        end
      end
    end

    def dismiss(item_id, reason: nil, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      suppress(row)
      row.update!(status: "dismissed", dismissed_at: Time.current, resolution_reason: reason)
      { success: true, message: "Suggestion dismissed" }
    end

    def bulk_dismiss(item_ids, reason: nil, report_type: "compaction_review")
      rows = MaintenanceReportRow.by_report_type(report_type).where(row_uuid: item_ids)
      rows.each do |row|
        suppress(row)
        row.update!(status: "dismissed", dismissed_at: Time.current, resolution_reason: reason)
      end
      { success: true, message: "#{rows.size} suggestion(s) dismissed" }
    end

    # Bulk-apply iterates `apply` per row: non-actionable rows (already
    # dismissed/approved) are skipped rather than failing the batch, and the
    # summary keeps per-row failures visible for the operator.
    def bulk_apply(item_ids, report_type: "compaction_review")
      rows = MaintenanceReportRow.by_report_type(report_type).where(row_uuid: item_ids)
      return { success: false, error: "No suggestions selected" } if rows.empty?

      applied = 0
      skipped = 0
      failed = []
      rows.each do |row|
        unless row.status.in?(%w[active ignored])
          skipped += 1
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
      message += "; #{failed.size} failed: #{failed.first(3).join('; ')}" if failed.any?
      { success: failed.empty?, message: message }
    end

    def restore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      signature = signature_for(row.kind, row.effective_payload)
      if signature.present?
        MaintenanceReportSuppression.where(report_type: row.report_type, signature: signature).delete_all
      end

      row.update!(status: "active", dismissed_at: nil, applied_at: nil, resolution_reason: nil)
      { success: true, message: "Suggestion restored to active" }
    end

    def ignore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      row.update!(status: "ignored")
      { success: true, message: "Suggestion ignored" }
    end

    def seed_report(report_type:, source:, source_ref: nil, items:)
      return [] if items.empty?

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

        created_rows = items.filter_map do |item|
          item = normalize_item(item)
          kind = item["kind"]
          next if kind.blank?
          payload = item.except("id")

          signature = signature_for(kind, payload)
          next if signature.blank?
          next if MaintenanceReportSuppression.suppressed?(report_type, signature)
          next if MaintenanceReportRow.by_report_type(report_type).pending.where(signature: signature).exists?
          next if absorb_stale_memory?(report_type, payload)

          MaintenanceReportRow.create!(
            maintenance_report_id: report.id,
            report_type: report_type,
            row_uuid: item["id"] || SecureRandom.uuid,
            kind: kind,
            status: "active",
            payload: payload,
            signature: signature
          )
        end

        report.update!(data: report.data.merge(count: created_rows.size))
        created_rows
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
    def absorb_stale_memory?(report_type, payload)
      return false unless payload[:kind] == "stale_memory"

      entity_id = payload[:entity_id].to_i
      signal = payload[:signal].to_s
      return false if entity_id.zero? || signal.blank?

      # effective_payload is a plain string-keyed hash (JSON column) — index
      # it with strings, not symbols.
      rows = MaintenanceReportRow.by_report_type(report_type).active
                                 .where(kind: "stale_memory")
                                 .select do |row|
        row.effective_payload["entity_id"].to_i == entity_id &&
          row.effective_payload["signal"].to_s == signal
      end
      return false if rows.empty?

      # Lock every candidate row in deterministic id order before merging so
      # a concurrent seeder cannot overwrite a just-absorbed payload. The
      # EARLIEST pending row absorbs — it holds the original queue position.
      locked_rows = MaintenanceReportRow.where(id: rows.map(&:id)).order(:id).lock(true).to_a
      keep = locked_rows.min_by(&:id)
      return false unless keep&.active?

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
      # Pre-merge duplicates for the same diagnosis are retired into the
      # row that absorbed them (audit kept via the ignored status).
      (locked_rows - [ keep ]).each { |row| row.update!(status: "ignored") }
      true
    end

    def suppressed?(kind, payload, report_type: "compaction_review")
      signature = signature_for(kind, payload)
      return false if signature.blank?

      MaintenanceReportSuppression.suppressed?(report_type, signature) ||
        MaintenanceReportRow.by_report_type(report_type).where(signature: signature).exists?
    end

    def signature_for(kind, payload)
      payload = payload.to_h.deep_stringify_keys.with_indifferent_access if payload.respond_to?(:to_h)

      case kind.to_s
      when "entity_merge"
        ids = [ payload.dig("entity_a", "entity_id"), payload.dig("entity_b", "entity_id") ].compact
        ids += [ payload[:source_id], payload[:target_id] ].compact if payload[:source_id] && payload[:target_id]
        ids = ids.uniq.sort
        return nil if ids.size < 2

        [ "entity_merge", ids.join("-") ].join("|")
      when "relationship_proposal"
        from_id = payload[:from_entity_id] || payload[:from_id]
        to_id = payload[:to_entity_id] || payload[:to_id]
        relation_type = payload[:relation_type]
        return nil if from_id.blank? || to_id.blank? || relation_type.blank?

        [ "relationship_proposal", from_id, to_id, relation_type ].join("|")
      when "orphan_parent"
        entity_id = payload[:entity_id]
        return nil if entity_id.blank?

        [ "orphan_parent", entity_id ].join("|")
      when "entity_error"
        entity_id = payload[:entity_id]
        phase = payload[:phase]
        return nil if entity_id.blank?

        [ "entity_error", entity_id, phase ].compact.join("|")
      when "embedding_backfill_failed"
        entity_id = payload[:entity_id]
        return nil if entity_id.blank?

        [ "embedding_backfill_failed", entity_id ].join("|")
      when "lifecycle_corruption"
        observation_id = payload[:observation_id]
        return nil if observation_id.blank?

        [ "lifecycle_corruption", observation_id ].join("|")
      when "relation_integrity"
        issue_kind = payload[:issue_kind] || payload.dig("payload", "kind")
        keep_id = payload.dig(:payload, :keep_id) || payload[:keep_id]
        delete_ids = payload.dig(:payload, :delete_ids) || payload[:delete_ids]
        delete_ids ||= [ payload.dig(:payload, :delete_id) || payload[:delete_id] ]
        delete_ids = Array(delete_ids).compact.map(&:to_i).sort
        return nil if issue_kind.blank? || keep_id.blank? || delete_ids.empty?

        [ "relation_integrity", issue_kind, keep_id, delete_ids.join("-") ].join("|")
      when "delete_relation"
        relation_id = payload[:relation_id] || payload.dig("payload", "relation_id")
        return nil if relation_id.blank?

        [ "delete_relation", relation_id.to_i ].join("|")
      when "delete_observation"
        observation_id = payload[:observation_id] || payload.dig("payload", "observation_id")
        return nil if observation_id.blank?

        [ "delete_observation", observation_id.to_i ].join("|")
      when "delete_entity"
        entity_id = payload[:entity_id] || payload.dig("payload", "entity_id")
        return nil if entity_id.blank?

        [ "delete_entity", entity_id.to_i ].join("|")
      when "dismiss_compaction_review"
        review_item_id = payload[:review_item_id] || payload.dig("payload", "review_item_id")
        return nil if review_item_id.blank?

        [ "dismiss_compaction_review", review_item_id.to_s ].join("|")
      when "move_observation"
        observation_id = payload[:observation_id] || payload.dig("payload", "observation_id")
        target_entity_id = payload[:target_entity_id] || payload[:target_id] || payload.dig("payload", "target_entity_id")
        return nil if observation_id.blank? || target_entity_id.blank?

        [ "move_observation", observation_id.to_i, target_entity_id.to_i ].join("|")
      when "reparent_entity"
        entity_id = payload[:entity_id] || payload[:node_id] || payload.dig("payload", "entity_id")
        parent_id = payload[:parent_id] || payload.dig("payload", "parent_id")
        return nil if entity_id.blank? || parent_id.blank?

        [ "reparent_entity", entity_id.to_i, parent_id.to_i ].join("|")
      when "stale_memory"
        # Dedupe on entity + observation set + SIGNAL: distinct diagnoses over
        # the same obs (expiry vs addressed-edge) are different items — a
        # dismissal must only suppress the signal it was taken on.
        entity_id = payload[:entity_id]
        obs_ids = Array(payload[:observation_ids]).compact.map(&:to_i).sort
        return nil if entity_id.blank? || obs_ids.empty?

        [ "stale_memory", entity_id.to_i, obs_ids.join("-"), payload[:signal] ].join("|")
      else
        nil
      end
    end

    def root_first?(row)
      payload = row.effective_payload.with_indifferent_access
      return true if row.kind == "orphan_parent" && payload["suggested_parents"].present?

      root_types = [ NodeOperationsStrategy::PROJECT_ENTITY_TYPE ]
      entity_types(row).any? { |type| root_types.include?(type) }
    end

    def item_score(row)
      row.effective_payload["score"].to_i
    end

    private

    def sort_rows(rows)
      rows.sort_by.with_index do |row, idx|
        [ root_first?(row) ? 0 : 1, -item_score(row), idx ]
      end
    end

    # `q` hits payload VALUES (names, ids, explanations), not JSON keys —
    # a raw `payload.to_json` haystack makes 'entity' or '_' match every
    # row. The human-readable kind label is searchable too ("relationship
    # proposal").
    def filter_by_query(rows, q)
      needle = q.to_s.downcase.strip
      rows.select do |row|
        values = [ row.kind, row.kind.tr("_", " ") ] +
                 payload_values(row.payload) + payload_values(row.edited_payload)
        values.compact.join(" ").downcase.include?(needle)
      end
    end

    def payload_values(obj)
      case obj
      when Hash then obj.flat_map { |_k, v| payload_values(v) }
      when Array then obj.flat_map { |v| payload_values(v) }
      else [ obj.to_s ]
      end
    end

    # All entity ids targeted by ACTIVE delete_entity rows in this queue —
    # the "queued for deletion" set the children warning compares against.
    def delete_entity_targets(report_type:)
      MaintenanceReportRow.by_report_type(report_type).active.where(kind: "delete_entity")
                          .filter_map { |row| delete_entity_target(row) }
    end

    def delete_entity_target(row)
      payload = row.effective_payload.with_indifferent_access
      target = payload[:entity_id] || payload.dig("payload", "entity_id")
      target.to_i.positive? ? target.to_i : nil
    end

    def entity_types(row)
      payload = row.effective_payload.with_indifferent_access
      case row.kind
      when "entity_merge"
        [ payload.dig("entity_a", "entity_type"), payload.dig("entity_b", "entity_type") ].compact
      when "relationship_proposal"
        [ payload[:from_entity_type], payload[:to_entity_type] ].compact
      when "orphan_parent"
        parents = (payload["suggested_parents"] || []).map { |p| MemoryEntity.find_by(id: p["project_id"])&.entity_type }
        [ payload[:entity_type], *parents ].compact
      else
        []
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
      signature = signature_for(row.kind, row.effective_payload)
      return if signature.blank?

      MaintenanceReportSuppression.create_or_find_by!(
        report_type: row.report_type,
        signature: signature
      ) do |s|
        s.kind = row.kind
        s.dismissed_at = Time.current
        s.reason = row.resolution_reason
      end
    end
  end
end
