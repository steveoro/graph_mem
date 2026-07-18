# frozen_string_literal: true

# Loads, edits, and applies MaintenanceReportRow review items for the operator UI.
# Supports both dream-state compaction review queues and ad-hoc suggest_merges output.
class CompactionReviewService
  PER_PAGE = 50
  STATUSES = MaintenanceReportRow::STATUSES

  class << self
    def latest_report
      MaintenanceReport.by_type("compaction_review").recent.first
    end

    def items(report: nil, report_type: "compaction_review", status: "active", kind: nil, page: 1)
      scope = MaintenanceReportRow.by_report_type(report_type)
      scope = scope.where(maintenance_report_id: report.id) if report
      scope = scope.by_status(status) if status.present?
      scope = scope.by_kind(kind) if kind.present?

      rows = scope.to_a
      sorted = sort_rows(rows)
      Kaminari.paginate_array(sorted).page(page).per(PER_PAGE)
    end

    def active_count(report_type: "compaction_review")
      MaintenanceReportRow.by_report_type(report_type).active.count
    end

    def status_counts(report_type: "compaction_review")
      MaintenanceReportRow.by_report_type(report_type).group(:status).count
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

      result = apply_action(row, action_params)
      if result[:success]
        row.update!(status: "approved", applied_at: Time.current)
      else
        row.update!(resolution_reason: result[:error])
      end
      result
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

    def restore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      row.update!(status: "active", dismissed_at: nil, applied_at: nil, resolution_reason: nil)
      { success: true }
    end

    def ignore(item_id, report_type: "compaction_review")
      row = find_item(item_id, report_type: report_type)
      return { success: false, error: "Suggestion not found" } unless row

      row.update!(status: "ignored")
      { success: true }
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
      return if RelationshipDiscoveryStrategy::ALLOWED_RELATION_TYPES.include?(relation_type.to_s)

      record = MaintenanceReportRow.new
      record.errors.add(:base, "Invalid relation type: #{relation_type}")
      raise ActiveRecord::RecordInvalid.new(record)
    end

    def apply_action(row, action_params)
      effective = row.effective_payload.with_indifferent_access

      case row.kind
      when "entity_merge"
        merge_entities(row, effective, action_params)
      when "relationship_proposal"
        create_relation(row, effective, action_params)
      when "orphan_parent"
        move_to_parent(row, effective, action_params)
      else
        { success: false, error: "Unknown review kind: #{row.kind}" }
      end
    end

    def merge_entities(row, effective, action_params)
      source_id = pick_id(action_params, :source_id, effective, [ :source_id, [ :entity_a, :entity_id ] ])
      target_id = pick_id(action_params, :target_id, effective, [ :target_id, [ :entity_b, :entity_id ] ])

      return { success: false, error: "Source and target entities are required" } if source_id.zero? || target_id.zero?
      return { success: false, error: "Cannot merge an entity into itself" } if source_id == target_id

      NodeOperationsStrategy.new.merge_into(source_id, target_id)
    end

    def create_relation(row, effective, action_params)
      from_id = pick_id(action_params, :from_id, effective, [ :from_id, :from_entity_id ])
      to_id = pick_id(action_params, :to_id, effective, [ :to_id, :to_entity_id ])
      relation_type = action_params[:relation_type].presence || effective[:relation_type]

      return { success: false, error: "Invalid relation" } if from_id.zero? || to_id.zero? || relation_type.blank?
      return { success: false, error: "Invalid relation type" } unless RelationshipDiscoveryStrategy::ALLOWED_RELATION_TYPES.include?(relation_type.to_s)

      MemoryRelation.create!(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: relation_type
      )
      { success: true, message: "Relation created" }
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      { success: false, error: "Failed to create relation: #{e.message}" }
    end

    def move_to_parent(row, effective, action_params)
      node_id = pick_id(action_params, :node_id, effective, [ :node_id, :entity_id ])
      parent_id = pick_id(action_params, :parent_id, effective, [ :parent_id ])

      return { success: false, error: "Node and parent are required" } if node_id.zero? || parent_id.zero?

      NodeOperationsStrategy.new.move_to_parent(node_id, parent_id)
    end

    def pick_id(action_params, key, effective, fallback_keys)
      value = action_params[key].presence || action_params[key.to_s].presence
      return value.to_i if value.present?

      fallback_keys.each do |fk|
        value = if fk.is_a?(Array)
                  effective.dig(*fk.map(&:to_s))
        else
                  effective[fk.to_s]
        end
        return value.to_i if value.present?
      end

      0
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
