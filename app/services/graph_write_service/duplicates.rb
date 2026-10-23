# frozen_string_literal: true

class GraphWriteService
  # Duplicate detection for graph_write (mcp plan PR-2 §2.7-§2.8).
  #
  # Two layers, so concurrent writers never race and the global write lock is never held across a
  # slow embedding call:
  # - semantic: vector similarity (may call the embedding service), outside the lock;
  # - exact: the same name in the target scope, an existing relation, an identical observation,
  #   re-checked inside the lock right before the transaction.
  # A unique-index race that still slips through surfaces as a structured response too.
  #
  # With on_duplicate: "skip", duplicates (stored or repeated within the batch) are listed under
  # `skipped` and the rest of the batch is written.
  module Duplicates
    # Raised inside the transaction when the UNIQUE(project_scope, name) index rejects an insert.
    class ConcurrentDuplicate < StandardError
      attr_reader :operation

      def initialize(operation)
        @operation = operation
        super("concurrent duplicate")
      end
    end

    private

    # Semantic layer (outside the lock). @return [Hash, nil] a possible_duplicate response
    def semantic_duplicate_response
      @operations.each do |operation|
        next unless operation[:type] == "create_entity"

        similar = semantic_candidate(operation)
        return entity_duplicate_response(operation, similar.entity, "similar", similar.distance) if similar
      end
      nil
    end

    # Exact layer (inside the lock). @return [Hash, nil] a possible_duplicate response
    def exact_duplicate_response
      @operations.each do |operation|
        case operation[:type]
        when "create_entity"
          existing = same_name_entity(operation[:attributes])
          return entity_duplicate_response(operation, existing, "same_name") if existing
        when "create_relation"
          relation = existing_relation(operation[:attributes])
          return relation_duplicate_response(operation, relation) if relation
        end
      end
      nil
    end

    # Splits the batch into operations to run and +skipped+ entries (on_duplicate: "skip").
    # The semantic candidates were computed outside the lock and are passed in.
    def plan_skips(semantic_candidates)
      seen = Set.new
      kept, skipped = @operations.partition do |operation|
        reason, existing_id = skip_reason(operation, semantic_candidates[operation[:index]], seen)
        @skipped << skip_entry(operation, reason, existing_id) if reason
        reason.nil?
      end
      @operations = kept
      skipped
    end

    def skip_reason(operation, similar, seen)
      attributes = operation[:attributes]
      case operation[:type]
      when "create_entity"
        return [ "duplicate_in_batch", nil ] unless seen.add?([ :entity, entity_scope(attributes), attributes[:name].to_s.downcase ])
        return [ "exists", same_name_entity(attributes).id ] if same_name_entity(attributes)
        return [ "similar", similar.entity.id ] if similar
      when "create_relation"
        key = [ :relation, attributes[:from_entity_id] || attributes[:from_entity], attributes[:to_entity_id] || attributes[:to_entity],
                MemoryRelation.canonical_relation_type(attributes[:relation_type]) ]
        return [ "duplicate_in_batch", nil ] unless seen.add?(key)
        relation = existing_relation(attributes)
        return [ "exists", relation.id ] if relation
      when "create_observation"
        entity_ref = attributes[:entity_id] || attributes[:entity_name]
        content = (attributes[:text_content] || attributes[:content]).to_s
        return [ "duplicate_in_batch", nil ] unless seen.add?([ :observation, entity_ref, content ])
        observation = existing_observation(entity_ref, content)
        return [ "exists", observation.id ] if observation
      end
      nil
    end

    def skip_entry(operation, reason, existing_id)
      attributes = operation[:attributes]
      { index: operation[:index], type: operation[:type],
        name: attributes[:name] || attributes[:relation_type] || attributes[:text_content] || attributes[:content],
        existing_id: existing_id, reason: reason }.compact
    end

    def semantic_candidate(operation)
      find_similar_entity(operation.dig(:attributes, :name), operation.dig(:attributes, :entity_type))
    end

    def find_similar_entity(name, entity_type)
      canonical_type = EntityTypeMapping.canonicalize(entity_type) || entity_type.to_s.strip
      result = VectorSearchStrategy.new.search("#{canonical_type}: #{name}", limit: 1, entity_type: canonical_type).first
      result if result && result.distance < DEDUP_DISTANCE_THRESHOLD
    rescue *ToolError::TIMEOUT_CLASSES
      raise
    rescue StandardError => e
      @logger.debug "GraphWriteService: dedup check unavailable — #{e.message}"
      nil
    end

    # The scope a create_entity lands in: the context project, except for Project roots (global).
    def entity_scope(attributes)
      ImportEntityResolver.canonical_type(attributes[:entity_type]) == "Project" ? nil : @project_id
    end

    def same_name_entity(attributes)
      return if attributes[:name].blank?

      MemoryEntity.find_by(name: attributes[:name], project_id: entity_scope(attributes))
    end

    def existing_relation(attributes)
      from_id = resolve_entity_id(attributes[:from_entity_id] || attributes[:from_entity])
      to_id = resolve_entity_id(attributes[:to_entity_id] || attributes[:to_entity])
      MemoryRelation.find_by(from_entity_id: from_id, to_entity_id: to_id,
                             relation_type: MemoryRelation.canonical_relation_type(attributes[:relation_type]))
    end

    def existing_observation(entity_ref, content)
      entity_id = resolve_entity_id(entity_ref)
      return unless entity_id.is_a?(Integer) || entity_id.to_s.match?(/\A\d+\z/)

      MemoryObservation.active.find_by(memory_entity_id: entity_id, content: content)
    end

    def entity_duplicate_response(operation, entity, reason, distance = nil)
      attributes = operation[:attributes]
      candidate = { entity_id: entity.id, name: entity.name, entity_type: entity.entity_type,
                    description: entity.description, aliases: entity.aliases }
      candidate[:similarity_distance] = distance.round(4) if distance
      possible_duplicate(
        operation, kind: "entity", reason: reason,
                   submitted: attributes.slice(:name, :entity_type, :aliases, :description),
                   candidates: [ candidate ],
                   next_move: "Use `graph_edit` or add an observation with `graph_write`; retry only if distinct."
      )
    end

    def relation_duplicate_response(operation, relation)
      possible_duplicate(
        operation, kind: "relation", reason: "same_relation",
                   submitted: { from_entity_id: relation.from_entity_id, to_entity_id: relation.to_entity_id,
                                relation_type: relation.relation_type },
                   candidates: [ GraphTraversalSerializer.relation_json(relation) ],
                   next_move: "Use the existing relation, or remove it with `graph_delete` before replacing it."
      )
    end

    # The insert lost a race on UNIQUE(project_scope, name): report the winner.
    def concurrent_duplicate_response(error)
      existing = same_name_entity(error.operation[:attributes])
      return entity_duplicate_response(error.operation, existing, "concurrent_insert") if existing

      raise McpGraphMemErrors::OperationFailed.new(
        "#{error.operation[:type]}[#{error.operation[:index]}]: an entity with this name was created concurrently",
        category: "concurrency", next_move: "Retry shortly; graph_write will report the existing entity."
      )
    end

    def possible_duplicate(operation, kind:, reason:, submitted:, candidates:, next_move:)
      {
        mode: "batch",
        status: "possible_duplicate",
        kind: kind,
        reason: reason,
        operation_index: operation[:index],
        submitted: submitted,
        candidates: candidates,
        next_move: next_move
      }
    end
  end
end
