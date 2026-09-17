# frozen_string_literal: true

class GraphEditService
  TYPES = %w[update_entity update_observation].freeze

  # Atomically applies entity and observation update operations.
  #
  # @param operations [Array<Hash>] hashes with `type: "update_entity"` or
  #   `type: "update_observation"` plus the target ID and mutable fields
  # @return [Hash] batch status, per-operation results, and summary counts
  # @raise [FastMcp::Tool::InvalidArgumentsError] for invalid update data
  # @raise [McpGraphMemErrors::Error] when a target cannot be found
  def self.call(operations:)
    new(operations: operations).call
  end

  # Executes one legacy edit operation without the batch envelope.
  #
  # @param type [String, Symbol] one of TYPES
  # @param attributes [Hash] the target ID and mutable entity/observation fields
  # @return [Hash] the legacy-compatible updated record payload
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
  # @raise [FastMcp::Tool::InvalidArgumentsError] when any edit is invalid
  # @raise [McpGraphMemErrors::Error] when any target cannot be updated
  def call
    GraphMutationBatch.validate_operations!(
      @operations,
      allowed_types: TYPES,
      tool_name: "graph_edit"
    )

    results = []
    summary = { entities_updated: 0, observations_updated: 0, observations_superseded: 0 }
    ActiveRecord::Base.transaction do
      @operations.each do |operation|
        payload = GraphMutationBatch.execute(operation) do |attributes|
          dispatch(operation[:type], attributes)
        end
        increment_summary(summary, operation, payload)
        results << GraphMutationBatch.result(operation, payload)
      end
    end

    {
      mode: "batch",
      status: "ok",
      results: results,
      summary: summary.merge(operations: @operations.size)
    }
  end

  private

  def dispatch(type, attributes)
    case type
    when "update_entity" then update_entity(attributes)
    when "update_observation" then update_observation(attributes)
    end
  end

  def update_entity(attributes)
    entity_id = attributes.delete(:entity_id)
    updates = attributes.slice(:name, :entity_type, :aliases, :description)
    unless updates[:name].present? || updates[:entity_type].present? ||
           updates.key?(:aliases) || updates.key?(:description)
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one attribute (name, entity_type, aliases, or description) must be provided for update."
    end

    entity = MemoryEntity.find_by(id: entity_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Entity with ID=#{entity_id} not found.",
        next_move: "Call `search`, then retry `graph_edit` with a known entity_id."
      )
    end

    entity.name = updates[:name] if updates[:name].present?
    entity.entity_type = updates[:entity_type] if updates[:entity_type].present?
    entity.aliases = updates[:aliases] if updates.key?(:aliases)
    entity.description = updates[:description] if updates.key?(:description)
    entity.save!

    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      aliases: entity.aliases,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      memory_observations_count: entity.memory_observations_count
    }
  end

  def update_observation(attributes)
    observation_id = attributes.delete(:observation_id)
    supersede = attributes.delete(:supersede) == true
    reason = attributes.delete(:reason)
    updates = attributes.slice(:text_content, :confidence, :source, :valid_from, :valid_until, :tags)
    updates[:content] = updates.delete(:text_content) if updates.key?(:text_content)
    if updates.empty?
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one observation attribute must be provided for update. " \
            "Provide `text_content`, `confidence`, `source`, `valid_from`, `valid_until`, or `tags` and retry `graph_edit`."
    end

    observation = MemoryObservation.find(observation_id)
    result = supersede ? observation.supersede!(updates, reason: reason) : observation.update_active!(updates)

    MemoryObservationSerializer.call(
      result,
      content_key: :observation_content,
      include_entity_id: true
    ).merge(superseded_observation_id: supersede ? observation.id : nil)
  rescue ActiveRecord::RecordNotFound
    raise McpGraphMemErrors::ResourceNotFound.new(
      "Observation with ID=#{observation_id} not found.",
      next_move: "Call `get_entities` to inspect observation ids, then retry `graph_edit`."
    )
  rescue MemoryObservation::InactiveObservationError => e
    raise FastMcp::Tool::InvalidArgumentsError,
          "#{e.message} Use `graph_delete` to obsolete data or `graph_write` to append a replacement."
  end

  def increment_summary(summary, operation, payload)
    if operation[:type] == "update_entity"
      summary[:entities_updated] += 1
    elsif payload[:superseded_observation_id]
      summary[:observations_superseded] += 1
    else
      summary[:observations_updated] += 1
    end
  end
end
