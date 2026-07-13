# frozen_string_literal: true

# Loads and modifies the latest compaction review report for the operator UI.
class CompactionReviewService
  PER_PAGE = 50
  STATUSES = %w[active ignored approved].freeze

  class << self
    def latest_report
      MaintenanceReport.by_type("compaction_review").recent.first
    end

    def items(report, page: 1, status: "active")
      all = report&.data&.dig("items") || []
      filtered = all.select { |item| item_status(item) == status }
      sorted = sort_items(filtered)
      Kaminari.paginate_array(sorted).page(page).per(PER_PAGE)
    end

    def active_count(report)
      all = report&.data&.dig("items") || []
      all.count { |item| item_status(item) == "active" }
    end

    def mark_ignored(report, item_id)
      update_item_status(report, item_id, "ignored")
    end

    def mark_approved(report, item_id)
      update_item_status(report, item_id, "approved")
    end

    def find_item(report, item_id)
      report&.data&.dig("items")&.find { |item| item["id"] == item_id }
    end

    def apply_action(item, action_params)
      case item["kind"]
      when "entity_merge"
        merge_entities(item, action_params)
      when "relationship_proposal"
        create_relation(item, action_params)
      when "orphan_parent"
        move_to_parent(item, action_params)
      else
        { success: false, error: "Unknown review kind: #{item['kind']}" }
      end
    end

    def root_first?(item)
      return true if item["kind"] == "orphan_parent" && item["suggested_parents"].present?

      root_types = [ NodeOperationsStrategy::PROJECT_ENTITY_TYPE ]
      entity_types(item).any? { |type| root_types.include?(type) }
    end

    private

    def item_status(item)
      item["status"].presence || "active"
    end

    def update_item_status(report, item_id, status)
      return false unless report

      items = report.data["items"] || []
      item = items.find { |i| i["id"] == item_id }
      return false unless item

      item["status"] = status
      report.update!(data: report.data)
    end

    def sort_items(items)
      items.sort_by.with_index do |item, idx|
        [ root_first?(item) ? 0 : 1, -item_score(item), idx ]
      end
    end

    def item_score(item)
      item["score"].to_i
    end

    def entity_types(item)
      case item["kind"]
      when "entity_merge"
        [ item["entity_a"]["entity_type"], item["entity_b"]["entity_type"] ].compact
      when "relationship_proposal"
        [ item["from_entity_type"], item["to_entity_type"] ].compact
      when "orphan_parent"
        [ item["entity_type"], *(item["suggested_parents"] || []).map { |p| MemoryEntity.find_by(id: p["project_id"])&.entity_type } ].compact
      else
        []
      end
    end

    def merge_entities(item, action_params)
      source_id = action_params[:source_id].to_i
      target_id = action_params[:target_id].to_i
      source_id = item["entity_a"]["entity_id"] if source_id.zero?
      target_id = item["entity_b"]["entity_id"] if target_id.zero?

      NodeOperationsStrategy.new.merge_into(source_id, target_id)
    end

    def create_relation(item, action_params)
      from_id = action_params[:from_id].to_i
      to_id = action_params[:to_id].to_i
      relation_type = action_params[:relation_type] || item["relation_type"]

      from_id = item["from_entity_id"] if from_id.zero?
      to_id = item["to_entity_id"] if to_id.zero?

      return { success: false, error: "Invalid relation" } if from_id.zero? || to_id.zero? || relation_type.blank?

      MemoryRelation.create!(
        from_entity_id: from_id,
        to_entity_id: to_id,
        relation_type: relation_type
      )
      { success: true, message: "Relation created" }
    end

    def move_to_parent(item, action_params)
      node_id = action_params[:node_id].to_i
      parent_id = action_params[:parent_id].to_i

      node_id = item["entity_id"] if node_id.zero?

      return { success: false, error: "Parent is required" } if parent_id.zero?

      NodeOperationsStrategy.new.move_to_parent(node_id, parent_id)
    end
  end
end
