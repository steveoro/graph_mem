# frozen_string_literal: true

class GraphWriteService
  include Duplicates

  TYPES = %w[create_entity create_observation create_relation].freeze
  ON_DUPLICATE_MODES = %w[reject skip].freeze
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
  # @param project_id [Integer, nil] `set_context` project — name→entity
  #   resolution prefers it, then the global namespace; created entities
  #   join it (nil = a global entity).
  # @param on_duplicate [String] "reject" (default: a possible duplicate prevents every write) or
  #   "skip" (duplicates are listed under `skipped` and the rest is written)
  def self.call(operations:, logger: Rails.logger, project_id: nil, on_duplicate: "reject")
    new(operations: operations, logger: logger, project_id: project_id, on_duplicate: on_duplicate).call
  end

  # Executes one legacy create operation without the batch envelope.
  #
  # @param type [String, Symbol] one of TYPES
  # @param attributes [Hash] operation-specific create fields
  # @param logger [#debug] logger used by duplicate probing
  # @return [Hash] the created record payload or possible-duplicate response
  def self.execute_one(type, attributes, logger: Rails.logger, project_id: nil)
    service = new(
      operations: [ attributes.to_h.merge(type: type.to_s) ],
      logger: logger,
      project_id: project_id
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
  def initialize(operations:, logger:, project_id: nil, on_duplicate: "reject")
    @operations = GraphMutationBatch.normalize_operations(operations)
    @logger = logger
    @project_id = project_id
    @on_duplicate = on_duplicate.to_s.presence || "reject"
    @skipped = []
    unless ON_DUPLICATE_MODES.include?(@on_duplicate)
      raise FastMcp::Tool::InvalidArgumentsError, "on_duplicate must be one of: #{ON_DUPLICATE_MODES.join(', ')}"
    end
  end

  # Runs the duplicate checks, then executes the batch in one transaction.
  #
  # Semantic duplicates are probed before the write lock (that may call the embedding service);
  # exact duplicates are re-checked under the lock, right before the transaction, so two
  # concurrent writers of the same name get one entity and one structured response (§2.7).
  # Entity operations run before observations and relations so later operations may reference
  # newly created entities by name. Results are returned in the caller's original order.
  #
  # @return [Hash] canonical batch result or possible-duplicate response
  # @raise [FastMcp::Tool::InvalidArgumentsError, McpGraphMemErrors::Error]
  #   when any operation fails; the transaction is rolled back
  def call
    GraphMutationBatch.validate_operations!(@operations, allowed_types: TYPES, tool_name: "graph_write")
    semantic = skip_mode? ? semantic_candidates : semantic_duplicate_response
    return semantic if semantic.is_a?(Hash) && semantic[:status] == "possible_duplicate"

    results = []
    counts = Hash.new(0)
    # Membership lock BEFORE the transaction: GET_LOCK taken while holding
    # row locks deadlocks against the backfill (advisory-first rule).
    ProjectMembership.with_membership_lock do
      if skip_mode?
        plan_skips(semantic)
      elsif (exact = exact_duplicate_response)
        return exact
      end

      ActiveRecord::Base.transaction do
        dependency_ordered_operations.each do |operation|
          payload, additional_counts = execute_operation(operation)
          additional_counts.each { |key, count| counts[key] += count }
          results << GraphMutationBatch.result(operation, payload)
        end
      end
    end

    batch_result(results, counts)
  rescue Duplicates::ConcurrentDuplicate => e
    concurrent_duplicate_response(e)
  rescue ProjectMembership::LockTimeout => e
    # Raised by the OUTER lock wrapper while another session holds it —
    # retryable, not "escalate to a human".
    raise lock_timeout_error(e)
  end

  private

  def skip_mode?
    @on_duplicate == "skip"
  end

  # @return [Hash{Integer => Object}] semantic matches by operation index (skip mode)
  def semantic_candidates
    @operations.each_with_object({}) do |operation, candidates|
      next unless operation[:type] == "create_entity"

      similar = semantic_candidate(operation)
      candidates[operation[:index]] = similar if similar
    end
  end

  def batch_result(results, counts)
    result = {
      mode: "batch",
      status: "ok",
      results: results.sort_by { |entry| entry[:index] },
      summary: {
        operations: results.size + @skipped.size,
        entities_created: counts[:entities],
        observations_created: counts[:observations],
        relations_created: counts[:relations]
      }
    }
    return result unless skip_mode?

    result[:summary][:skipped] = @skipped.size
    result[:skipped] = @skipped.sort_by { |entry| entry[:index] }
    result[:next_move] = "Skipped #{@skipped.size} duplicate(s); use `graph_edit` to change the existing records." if @skipped.any?
    result
  end

  def lock_timeout_error(exception)
    McpGraphMemErrors::OperationFailed.new(
      exception.message,
      category: "concurrency",
      next_move: "Another import, backfill or merge is running; retry shortly."
    )
  end

  def dependency_ordered_operations
    @operations.sort_by { |operation| [ TYPE_ORDER.fetch(operation[:type]), operation[:index] ] }
  end

  def execute_operation(operation)
    payload = begin
      GraphMutationBatch.execute(operation) { |attributes| dispatch(operation[:type], attributes) }
    rescue Duplicates::ConcurrentDuplicate
      raise Duplicates::ConcurrentDuplicate.new(operation)
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

  # The single-operation path runs the same two duplicate layers as #call (§2.7).
  def execute_one
    duplicate = semantic_duplicate_response
    return duplicate if duplicate

    operation = @operations.first
    ProjectMembership.with_membership_lock do
      exact = exact_duplicate_response
      return exact if exact

      ActiveRecord::Base.transaction { dispatch(operation[:type], operation[:attributes]) }
    end
  rescue Duplicates::ConcurrentDuplicate => e
    concurrent_duplicate_response(e)
  rescue ProjectMembership::LockTimeout => e
    raise lock_timeout_error(e)
  end

  # Moving/creating into a project that already holds the name surfaces as
  # OperationFailed, not a bare UNIQUE(project_scope, name) failure; the
  # surrounding transaction rolls the edge/entity back with it.
  def sync_membership!(entity)
    ProjectMembership.sync!(entity)
  rescue ProjectMembership::LockTimeout => e
    # A lock wait is transient, not a name conflict — retry shortly, never
    # "rename the entity".
    raise McpGraphMemErrors::OperationFailed.new(
      e.message,
      category: "concurrency",
      next_move: "Another import, backfill or merge is running; retry shortly."
    )
  rescue ProjectMembership::Collision => e
    raise McpGraphMemErrors::OperationFailed.new(
      e.message,
      category: "validation",
      next_move: "Rename the entity or pick a different project scope, then retry."
    )
  end

  def dispatch(type, attributes)
    case type
    when "create_entity" then create_entity(attributes)
    when "create_observation" then create_observation(attributes)
    when "create_relation" then create_relation(attributes)
    end
  end

  def create_entity(attributes)
    submitted_type = attributes[:entity_type]
    is_project = ImportEntityResolver.canonical_type(attributes[:entity_type]) == "Project"
    entity = create_entity_row!(attributes, is_project)
    # Members join the context project by ATTACHING to it: the part_of
    # edge makes the membership visible in the tree and
    # ProjectMembership.sync! recomputes the column the same way every
    # other writer does (a no-op here — inserted in scope already).
    # Project roots and context-less creates stay global.
    if @project_id && !is_project
      MemoryRelation.create!(from_entity_id: entity.id, to_entity_id: @project_id,
                             relation_type: "part_of")
      sync_membership!(entity)
    end
    Array(attributes[:observations]).each do |content|
      MemoryObservation.create!(memory_entity: entity, content: content)
    end

    entity_payload(entity, submitted_type)
  end

  # A unique-index race (two writers of one name) raises ConcurrentDuplicate, so #call can roll
  # back and answer with the existing entity instead of an error (§2.7).
  def create_entity_row!(attributes, is_project)
    MemoryEntity.create!(
      name: attributes[:name],
      entity_type: attributes[:entity_type],
      aliases: GraphMutationBatch.normalize_aliases(attributes[:aliases]),
      description: attributes[:description],
      # Insert directly in the FINAL scope: inserting at project_scope 0
      # first would collide with a same-named GLOBAL entity even though
      # the row is headed for the project scope (UNIQUE(project_scope,
      # name) is per-scope). The part_of edge + sync! below keep the
      # membership-mirrors-the-chain invariant.
      project_id: (@project_id unless is_project)
    )
  rescue ActiveRecord::RecordNotUnique
    raise Duplicates::ConcurrentDuplicate.new({ type: "create_entity", attributes: attributes })
  end

  def entity_payload(entity, submitted_type)
    payload = {
      entity_id: entity.id,
      name: entity.name,
      entity_type: entity.entity_type,
      description: entity.description,
      aliases: entity.aliases,
      created_at: entity.created_at.iso8601,
      updated_at: entity.updated_at.iso8601,
      memory_observations_count: entity.memory_observations.count
    }
    type_hint = type_hint_for(submitted_type, GraphVocabulary::ENTITY_TYPES, EntityTypeMapping)
    payload[:type_hint] = type_hint if type_hint
    payload
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
      perspective: attributes[:perspective],
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
    # project_id mirrors the part_of chain: every write that creates a
    # hierarchy edge must resync the child's scope, or the tree and the
    # membership column drift apart (and the backfill stops being a no-op).
    # A same-name clash in the target scope surfaces as OperationFailed
    # and rolls the edge back with it (execution is transactional).
    sync_membership!(MemoryEntity.find(from_id)) if canonical_type == "part_of"
    payload = GraphTraversalSerializer.relation_json(relation)
    type_hint = type_hint_for(
      attributes[:relation_type],
      GraphVocabulary::RELATION_TYPES,
      RelationTypeMapping
    )
    payload[:type_hint] = type_hint if type_hint
    payload
  end

  def resolve_entity_id(value)
    return value unless value.is_a?(String)

    ImportEntityResolver.find_by_name(value, project_id: @project_id)&.id || value
  end

  def type_hint_for(value, examples, mapping_class)
    return if mapping_class.canonicalize(value)

    GraphVocabulary.suggestion(value, examples)
  end
end
