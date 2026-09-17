# frozen_string_literal: true

class GraphWriteService
  TYPES = %w[create_entity create_observation create_relation].freeze
  TYPE_ORDER = TYPES.each_with_index.to_h.freeze
  DEDUP_DISTANCE_THRESHOLD = 0.25

  # Atomically creates entities, observations, and relations.
  #
  # @param operations [Array<Hash>] hashes with a create type from TYPES and
  #   operation-specific attributes
  # @param logger [#debug] logger used when duplicate probing is unavailable
  # @return [Hash] batch result, or `status: "possible_duplicate"` with no writes
  # @raise [FastMcp::Tool::InvalidArgumentsError] for invalid create data
  # @raise [McpGraphMemErrors::Error] when a dependency cannot be created
  def self.call(operations:, logger: Rails.logger)
    new(operations: operations, logger: logger).call
  end

  # Executes one legacy create operation without the batch envelope.
  #
  # @param type [String, Symbol] one of TYPES
  # @param attributes [Hash] operation-specific create fields
  # @param logger [#debug] logger used by duplicate probing
  # @return [Hash] the created record payload or possible-duplicate response
  def self.execute_one(type, attributes, logger: Rails.logger)
    service = new(
      operations: [ attributes.to_h.merge(type: type.to_s) ],
      logger: logger
    )
    service.send(:execute_one)
  end

  # Converts the legacy three-array input into type-discriminated operations.
  #
  # @param entities [Array<Hash>] entity attributes
  # @param observations [Array<Hash>] observation attributes
  # @param relations [Array<Hash>] relation attributes
  # @return [Array<Hash>] canonical create operations in dependency-safe order
  def self.operations_from_buckets(entities: [], observations: [], relations: [])
    Array(entities).map { |attributes| attributes.to_h.merge(type: "create_entity") } +
      Array(observations).map { |attributes| attributes.to_h.merge(type: "create_observation") } +
      Array(relations).map { |attributes| attributes.to_h.merge(type: "create_relation") }
  end

  # @param operations [Array<Hash>] raw type-discriminated create operations
  # @param logger [#debug] logger used by duplicate probing
  def initialize(operations:, logger:)
    @operations = GraphMutationBatch.normalize_operations(operations)
    @logger = logger
  end

  # Runs duplicate preflight, then executes the batch in one transaction.
  #
  # Entity operations run before observations and relations so later
  # operations may reference newly created entities by name. Results are
  # returned in the caller's original order.
  #
  # @return [Hash] canonical batch result or possible-duplicate response
  # @raise [FastMcp::Tool::InvalidArgumentsError, McpGraphMemErrors::Error]
  #   when any operation fails; the transaction is rolled back
  def call
    GraphMutationBatch.validate_operations!(
      @operations,
      allowed_types: TYPES,
      tool_name: "graph_write"
    )
    duplicate = duplicate_response
    return duplicate if duplicate

    results = []
    counts = Hash.new(0)
    ActiveRecord::Base.transaction do
      dependency_ordered_operations.each do |operation|
        payload, additional_counts = execute_operation(operation)
        additional_counts.each { |key, count| counts[key] += count }
        results << GraphMutationBatch.result(operation, payload)
      end
    end

    {
      mode: "batch",
      status: "ok",
      results: results.sort_by { |result| result[:index] },
      summary: {
        operations: @operations.size,
        entities_created: counts[:entities],
        observations_created: counts[:observations],
        relations_created: counts[:relations]
      }
    }
  end

  private

  def dependency_ordered_operations
    @operations.sort_by { |operation| [ TYPE_ORDER.fetch(operation[:type]), operation[:index] ] }
  end

  def execute_operation(operation)
    payload = GraphMutationBatch.execute(operation) do |attributes|
      dispatch(operation[:type], attributes)
    end

    counts =
      case operation[:type]
      when "create_entity"
        { entities: 1, observations: Array(operation.dig(:attributes, :observations)).size }
      when "create_observation" then { observations: 1 }
      when "create_relation" then { relations: 1 }
      end
    [ payload, counts ]
  end

  def execute_one
    duplicate = duplicate_response
    return duplicate if duplicate

    operation = @operations.first
    ActiveRecord::Base.transaction { dispatch(operation[:type], operation[:attributes]) }
  end

  def dispatch(type, attributes)
    case type
    when "create_entity" then create_entity(attributes)
    when "create_observation" then create_observation(attributes)
    when "create_relation" then create_relation(attributes)
    end
  end

  def create_entity(attributes)
    entity = MemoryEntity.create!(
      name: attributes[:name],
      entity_type: attributes[:entity_type],
      aliases: attributes[:aliases],
      description: attributes[:description]
    )
    Array(attributes[:observations]).each do |content|
      MemoryObservation.create!(memory_entity: entity, content: content)
    end

    {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      aliases: entity.aliases,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      memory_observations_count: entity.memory_observations.count
    }
  end

  def create_observation(attributes)
    entity_id = resolve_entity_id(attributes[:entity_id] || attributes[:entity_name])
    entity = MemoryEntity.find_by(id: entity_id)
    unless entity
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Entity with ID=#{entity_id} not found.",
        next_move: "Call `search`, then retry `graph_write` with a known entity_id."
      )
    end
    observation = MemoryObservation.create!(
      memory_entity: entity,
      content: attributes[:text_content] || attributes[:content],
      confidence: attributes[:confidence],
      source: attributes[:source],
      valid_from: attributes[:valid_from],
      valid_until: attributes[:valid_until],
      tags: attributes[:tags] || []
    )

    MemoryObservationSerializer.call(
      observation,
      content_key: :observation_content,
      include_entity_id: true
    )
  end

  def create_relation(attributes)
    from_id = resolve_entity_id(attributes[:from_entity_id] || attributes[:from_entity])
    to_id = resolve_entity_id(attributes[:to_entity_id] || attributes[:to_entity])
    unless MemoryEntity.exists?(id: from_id)
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Entity with ID=#{from_id} not found.",
        next_move: "Call `search`, then retry `graph_write` with a known from_entity_id."
      )
    end
    unless MemoryEntity.exists?(id: to_id)
      raise McpGraphMemErrors::ResourceNotFound.new(
        "Entity with ID=#{to_id} not found.",
        next_move: "Call `search`, then retry `graph_write` with a known to_entity_id."
      )
    end

    canonical_type = MemoryRelation.canonical_relation_type(attributes[:relation_type])
    if MemoryRelation.exists?(from_entity_id: from_id, to_entity_id: to_id, relation_type: canonical_type)
      raise McpGraphMemErrors::OperationFailed.new(
        "A relation of type '#{canonical_type}' already exists from from_entity_id=#{from_id} to to_entity_id=#{to_id}.",
        category: "validation",
        next_move: "Call `traverse_graph` to inspect the existing edge, or use `graph_delete` before replacing it."
      )
    end

    relation = MemoryRelation.create!(
      from_entity_id: from_id,
      to_entity_id: to_id,
      relation_type: canonical_type,
      weight: attributes[:weight],
      confidence: attributes[:confidence],
      properties: attributes[:properties] || {}
    )
    GraphTraversalSerializer.relation_json(relation)
  end

  def resolve_entity_id(value)
    return value unless value.is_a?(String)

    MemoryEntity.find_by(name: value)&.id || value
  end

  def duplicate_response
    @operations.each do |operation|
      next unless operation[:type] == "create_entity"

      attributes = operation[:attributes]
      similar = find_similar_entity(attributes[:name], attributes[:entity_type])
      next unless similar

      return {
        mode: "batch",
        status: "possible_duplicate",
        operation_index: operation[:index],
        candidate: {
          entity_id: similar.entity.id,
          name: similar.entity.name,
          entity_type: similar.entity.entity_type,
          description: similar.entity.description,
          aliases: similar.entity.aliases,
          similarity_distance: similar.distance.round(4)
        },
        next_move: "Use `graph_edit` or add an observation with `graph_write`; retry only if this is a distinct entity."
      }
    end
    nil
  end

  def find_similar_entity(name, entity_type)
    result = VectorSearchStrategy.new.search("#{entity_type}: #{name}", limit: 1, entity_type: entity_type).first
    result if result && result.distance < DEDUP_DISTANCE_THRESHOLD
  rescue *ToolError::TIMEOUT_CLASSES
    raise
  rescue StandardError => e
    @logger.debug "GraphWriteService: dedup check unavailable — #{e.message}"
    nil
  end
end
