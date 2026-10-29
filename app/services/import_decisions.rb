# frozen_string_literal: true

# The import review's decisions (moved from DataExchangeController in UI-6 P4): root nodes take
# the operator's choice from the review form, child nodes the decision precomputed at matching.
#
#   decisions = ImportDecisions.merge(params[:decisions], ImportSession.load_matches(session_id))
#   ImportDecisions.project_entity_id(import_data, decisions) # => the Project the import landed in
module ImportDecisions
  module_function

  # @param root_decisions [ActionController::Parameters, Hash, nil] decisions[i][node_path|action|target_id|parent_id]
  # @param stored_matches [Array<Hash>] the session's match results
  # @return [Array<Hash>] one decision per matched node
  def merge(root_decisions, stored_matches)
    submitted = submitted_lookup(root_decisions)
    Array(stored_matches).map do |match|
      if fetch(match, :is_child)
        child_decision(match)
      else
        root_decision(match, submitted[fetch(match, :node_path)])
      end
    end
  end

  # @return [String, nil] the first root node's name
  def root_name(import_data)
    roots = fetch(import_data, :root_nodes)
    (roots.is_a?(Array) ? fetch(roots.first, :name) : nil).presence
  end

  # The Project root the import merged into or created: a Project root node's chosen target, else
  # an existing Project root of that name.
  #
  # @return [Integer, nil]
  def project_entity_id(import_data, decisions)
    roots = Array(fetch(import_data, :root_nodes))
    project_type = NodeOperationsStrategy::PROJECT_ENTITY_TYPE
    by_path = Array(decisions).index_by { |decision| fetch(decision, :node_path).to_s }
    roots.each_with_index do |root, index|
      next unless fetch(root, :entity_type).to_s == project_type

      target_id = fetch(by_path[index.to_s], :target_id)
      entity = target_id.present? && MemoryEntity.find_by(id: target_id)
      return entity.id if entity
    end
    roots.each do |root|
      next unless fetch(root, :entity_type).to_s == project_type

      found = MemoryEntity.find_by(name: fetch(root, :name), entity_type: project_type, project_id: nil)
      return found.id if found
    end
    nil
  end

  def fetch(hash, key)
    return nil unless hash.is_a?(Hash) || hash.is_a?(ActionController::Parameters)

    hash[key].nil? ? hash[key.to_s] : hash[key]
  end

  def submitted_lookup(root_decisions)
    return {} if root_decisions.blank?

    decisions = root_decisions.respond_to?(:each_value) ? root_decisions.each_value : Array(root_decisions)
    decisions.each_with_object({}) do |decision, lookup|
      node_path = fetch(decision, :node_path)
      next if node_path.blank?

      lookup[node_path] = {
        action: fetch(decision, :action) || "create",
        target_id: fetch(decision, :target_id).presence&.to_i,
        parent_id: fetch(decision, :parent_id).presence&.to_i
      }
    end
  end

  def child_decision(match)
    action = fetch(match, :child_action) || "create"
    exact = fetch(match, :exact_match)
    { node_path: fetch(match, :node_path), action: action, child_action: action, target_id: fetch(exact, :entity_id)&.to_i }
  end

  def root_decision(match, submitted)
    node_path = fetch(match, :node_path)
    return { node_path: node_path, **submitted, action: submitted[:action] || "create" } if submitted

    selected = fetch(match, :selected_match_id)
    { node_path: node_path, action: selected.present? ? "merge" : "create", target_id: selected&.to_i, parent_id: nil }
  end
end
