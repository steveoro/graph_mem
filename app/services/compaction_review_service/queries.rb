# frozen_string_literal: true

class CompactionReviewService
  # The read side of the review queue: the paginated list, counts and the delete-children hint.
  # Extended into CompactionReviewService, so these are class methods.
  module Queries
    # A text search runs in Ruby over at most this many SQL-ordered rows (values only, no index).
    SEARCH_SCAN_CAP = 2_000
    PROJECT = NodeOperationsStrategy::PROJECT_ENTITY_TYPE

    # Rows root_first? used to put on top: orphans with project suggestions, and suggestions
    # involving a Project entity. Kept as the first sort key ahead of priority.
    ROOT_FIRST_SQL = begin
      json = ->(path) { "COALESCE(JSON_VALUE(edited_payload, '#{path}'), JSON_VALUE(payload, '#{path}'))" }
      types = ->(*paths) { "'#{PROJECT}' IN (#{paths.map { |path| json.call(path) }.join(', ')})" }
      "CASE WHEN (kind = 'orphan_parent' AND COALESCE(JSON_LENGTH(COALESCE(JSON_EXTRACT(edited_payload, '$.suggested_parents'), " \
        "JSON_EXTRACT(payload, '$.suggested_parents'))), 0) > 0) " \
        "OR (kind = 'orphan_parent' AND #{types.call('$.entity_type')}) " \
        "OR (kind = 'entity_merge' AND #{types.call('$.entity_a.entity_type', '$.entity_b.entity_type')}) " \
        "OR (kind = 'relationship_proposal' AND #{types.call('$.from_entity_type', '$.to_entity_type')}) " \
        "THEN 0 ELSE 1 END"
    end

    # One page of rows: root-first rows, then by priority, oldest first. Paginated in SQL, so
    # total_count / total_pages stay cheap. With `q`, the search scans at most SEARCH_SCAN_CAP rows
    # and the result answers `search_capped?`.
    # @return [ActiveRecord::Relation, Kaminari::PaginatableArray]
    def items(report: nil, report_type: "compaction_review", status: "active", kind: nil, page: 1, q: nil)
      scope = MaintenanceReportRow.by_report_type(report_type)
      scope = scope.where(maintenance_report_id: report.id) if report
      scope = scope.by_status(status) if status.present?
      scope = scope.by_kind(kind) if kind.present?
      scope = scope.order(Arel.sql(ROOT_FIRST_SQL)).order(priority: :desc, id: :asc)
      return scope.page(page).per(CompactionReviewService::PER_PAGE) if q.blank?

      scanned = scope.limit(SEARCH_SCAN_CAP).to_a
      capped = scanned.size == SEARCH_SCAN_CAP
      Kaminari.paginate_array(filter_by_query(scanned, q)).page(page).per(CompactionReviewService::PER_PAGE).tap do |result|
        result.define_singleton_method(:search_capped?) { capped }
      end
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

    def root_first?(row)
      payload = row.effective_payload.with_indifferent_access
      return true if row.kind == "orphan_parent" && payload["suggested_parents"].present?

      entity_types(row).include?(PROJECT)
    end

    # The generator's own score, kept for MCP output compatibility (not comparable across kinds).
    def item_score(row)
      row.effective_payload["score"].to_i
    end

    private

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
  end
end
