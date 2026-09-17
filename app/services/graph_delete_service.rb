# frozen_string_literal: true

class GraphDeleteService
  TYPES = %w[delete_entity delete_observation delete_relation merge_entities].freeze

  # Atomically applies a batch of delete, obsolete, and merge operations.
  #
  # @param operations [Array<Hash>] hashes with a `type` from TYPES and the
  #   corresponding IDs/reason fields
  # @return [Hash] batch status, per-operation results, and summary counts
  # @raise [FastMcp::Tool::InvalidArgumentsError] for invalid/conflicting input
  # @raise [McpGraphMemErrors::Error] when a requested record or operation fails
  def self.call(operations:)
    new(operations: operations).call
  end

  # Executes one legacy delete/merge operation without the batch envelope.
  #
  # @param type [String, Symbol] one of TYPES
  # @param attributes [Hash] the operation-specific IDs and optional reason
  # @return [Hash] the legacy-compatible operation result
  def self.execute_one(type, attributes)
    new(operations: []).send(:dispatch, type.to_s, attributes.to_h.deep_symbolize_keys)
  end

  # @param operations [Array<Hash>] raw type-discriminated operation hashes
  def initialize(operations:)
    @operations = GraphMutationBatch.normalize_operations(operations)
  end

  # Executes normalized operations in request order inside one transaction.
  #
  # @return [Hash] `{ mode: "batch", status: "ok", results:, summary: }`
  # @raise [FastMcp::Tool::InvalidArgumentsError] when validation fails
  # @raise [McpGraphMemErrors::Error] when an operation cannot be completed
  def call
    GraphMutationBatch.validate_operations!(
      @operations,
      allowed_types: TYPES,
      tool_name: "graph_delete"
    )
    validate_conflicts!

    results = []
    summary = Hash.new(0)
    ActiveRecord::Base.transaction do
      @operations.each do |operation|
        payload = GraphMutationBatch.execute(operation) do |attributes|
          dispatch(operation[:type], attributes)
        end
        summary[operation[:type]] += 1
        results << GraphMutationBatch.result(operation, payload)
      end
    end

    {
      mode: "batch",
      status: "ok",
      results: results,
      summary: {
        operations: @operations.size,
        entities_deleted: summary["delete_entity"],
        observations_obsoleted: summary["delete_observation"],
        relations_deleted: summary["delete_relation"],
        entities_merged: summary["merge_entities"]
      }
    }
  end

  private

  def dispatch(type, attributes)
    case type
    when "delete_entity" then delete_entity(attributes)
    when "delete_observation" then delete_observation(attributes)
    when "delete_relation" then delete_relation(attributes)
    when "merge_entities" then merge_entities(attributes)
    end
  end

  def delete_entity(attributes)
    entity_id = attributes[:entity_id]
    entity = MemoryEntity.find(entity_id)
    if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      raise McpGraphMemErrors::OperationFailed.new(
        NodeOperationsStrategy::PROJECT_ROOT_PROTECTED_ERROR,
        category: "validation",
        next_move: "Use `graph_edit` or `graph_write` on a Project root instead."
      )
    end

    snapshot = entity.attributes
    with_deletion_reason(attributes[:reason]) { entity.destroy! }
    {
      entity_id: snapshot["id"],
      name: snapshot["name"],
      entity_type: snapshot["entity_type"],
      aliases: snapshot["aliases"],
      memory_observations_count: snapshot["memory_observations_count"],
      created_at: snapshot["created_at"].iso8601(3),
      updated_at: snapshot["updated_at"].iso8601(3),
      message: "Entity with ID=#{entity_id} and its associated data deleted successfully."
    }
  rescue ActiveRecord::RecordNotFound
    raise McpGraphMemErrors::ResourceNotFound.new(
      "Entity with ID=#{entity_id} not found.",
      next_move: "Call `search`, then retry `graph_delete` with a known entity_id."
    )
  end

  def delete_observation(attributes)
    observation_id = attributes[:observation_id]
    observation = MemoryObservation.find(observation_id)
    observation.mark_obsolete!(reason: attributes[:reason])
    MemoryObservationSerializer.call(
      observation,
      content_key: :observation_content,
      include_entity_id: true
    ).merge(message: "Observation with ID=#{observation_id} marked obsolete successfully.")
  rescue ActiveRecord::RecordNotFound
    raise McpGraphMemErrors::ResourceNotFound.new(
      "Observation with ID=#{observation_id} not found.",
      next_move: "Call `get_entities` to inspect observation ids, then retry `graph_delete`."
    )
  end

  def delete_relation(attributes)
    relation_id = attributes[:relation_id]
    relation = MemoryRelation.find(relation_id)
    snapshot = relation.attributes
    with_deletion_reason(attributes[:reason]) { relation.destroy! }
    {
      relation_id: snapshot["id"],
      from_entity_id: snapshot["from_entity_id"],
      to_entity_id: snapshot["to_entity_id"],
      relation_type: snapshot["relation_type"],
      weight: snapshot["weight"],
      confidence: snapshot["confidence"],
      properties: snapshot["properties"] || {},
      created_at: snapshot["created_at"].iso8601(3),
      updated_at: snapshot["updated_at"].iso8601(3),
      message: "Relation with ID=#{relation_id} deleted successfully."
    }
  rescue ActiveRecord::RecordNotFound
    raise McpGraphMemErrors::ResourceNotFound.new(
      "Relation with ID=#{relation_id} not found.",
      next_move: "Call `traverse_graph` to inspect relation ids, then retry `graph_delete`."
    )
  end

  def merge_entities(attributes)
    source_id = attributes[:source_entity_id]
    target_id = attributes[:target_entity_id]
    result = NodeOperationsStrategy.new.merge_into(source_id, target_id)
    raise map_merge_error(result[:error]) unless result[:success]

    {
      status: "merged",
      message: result[:message],
      source_entity_id: source_id,
      target_entity_id: target_id
    }
  end

  def map_merge_error(message)
    text = message.to_s
    if text.match?(/not found/i)
      return McpGraphMemErrors::ResourceNotFound.new(
        text,
        next_move: "Call `search` to find valid entity ids, then retry `graph_delete`."
      )
    end
    if text.match?(/into itself/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Pass different entity ids, or use a delete_entity operation with `graph_delete`."
      )
    end
    if text.match?(/Project root|protected/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Use `graph_edit` or `graph_write` on the existing Project root."
      )
    end
    if text.match?(/different types/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Merge only same-type entities, or use a delete_entity operation with `graph_delete`."
      )
    end
    if text.match?(/Cannot merge|cycle/i)
      return FastMcp::Tool::InvalidArgumentsError.new(
        "#{text}. Choose different endpoints, or use a delete_entity operation with `graph_delete`."
      )
    end

    McpGraphMemErrors::OperationFailed.new(
      "The merge could not be completed.",
      next_move: "Call `suggest_merges` or `get_entities` to inspect the pair, then retry `graph_delete`."
    )
  end

  def with_deletion_reason(reason)
    Current.deletion_reason = reason
    yield
  ensure
    Current.deletion_reason = nil
  end

  def validate_conflicts!
    duplicate_conflict!(:observation_id, "delete_observation")
    duplicate_conflict!(:relation_id, "delete_relation")

    entity_ids = @operations.flat_map do |operation|
      case operation[:type]
      when "delete_entity" then [ operation.dig(:attributes, :entity_id) ]
      when "merge_entities"
        [ operation.dig(:attributes, :source_entity_id), operation.dig(:attributes, :target_entity_id) ]
      else []
      end
    end.compact
    return if entity_ids.uniq.size == entity_ids.size

    raise FastMcp::Tool::InvalidArgumentsError,
          "graph_delete cannot target the same entity more than once in one batch."
  end

  def duplicate_conflict!(id_field, type)
    ids = @operations.filter_map do |operation|
      operation.dig(:attributes, id_field) if operation[:type] == type
    end
    return if ids.uniq.size == ids.size

    raise FastMcp::Tool::InvalidArgumentsError,
          "graph_delete cannot target the same #{id_field} more than once in one batch."
  end
end
