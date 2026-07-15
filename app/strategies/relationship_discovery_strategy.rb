# frozen_string_literal: true

# Deterministic, review-only relationship proposals for dream-state discovery.
# Uses observation text and entity metadata only (no embeddings / LLM).
class RelationshipDiscoveryStrategy
  ALLOWED_RELATION_TYPES = %w[relates_to implements solves depends_on part_of].freeze
  MAX_PROPOSALS_PER_ENTITY = 3
  MIN_SHARED_CONTENT_LENGTH = 15

  ISSUE_MARKERS = %w[block blocks blocked blocking error fail failure problem issue].freeze
  SOLUTION_MARKERS = %w[fix fixes fixed solve solves solving resolve resolved].freeze
  DEPENDENCY_MARKERS = %w[depend depends depending dependency].freeze
  # With MIN_SHARED_TERMS = 2, score is (size * 3) + 5 → 11 at minimum; high band starts at 14 (3+ shared terms).
  ISSUE_SOLUTION_HIGH_SCORE = 14

  def proposals_for_entity(entity_id)
    entity = MemoryEntity.find_by(id: entity_id)
    return [] unless entity
    return [] if project_root?(entity)

    proposals = []
    proposals.concat(shared_observation_proposals(entity))
    proposals.concat(issue_solution_proposals(entity))
    proposals.concat(dependency_proposals(entity))

    dedupe_and_limit(proposals)
  end

  private

  def project_root?(entity)
    entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
  end

  def shared_observation_proposals(entity)
    entity.active_memory_observations.flat_map do |observation|
      next [] if observation.content.to_s.length < MIN_SHARED_CONTENT_LENGTH

      MemoryObservation
        .active
        .where(content: observation.content)
        .where.not(memory_entity_id: entity.id)
        .includes(:memory_entity)
        .filter_map do |other_observation|
          other_entity = other_observation.memory_entity
          next if other_entity.nil? || project_root?(other_entity)

          from_id, to_id = ordered_pair(entity.id, other_entity.id)
          next unless from_id == entity.id

          build_proposal(
            from_entity_id: from_id,
            to_entity_id: to_id,
            relation_type: "relates_to",
            confidence_band: "high",
            score: 10,
            supporting_observation_ids: [ observation.id, other_observation.id ],
            explanation: "Shared observation evidence on both entities",
            evidence_terms: shared_significant_tokens(observation.content, other_observation.content),
            from_entity: entity,
            to_entity: other_entity
          )
        end
    end
  end

  def issue_solution_proposals(entity)
    return [] unless entity.entity_type == "PossibleSolution"

    MemoryEntity.where(entity_type: "Issue").order(:id).filter_map do |issue|
      next if project_root?(issue)

      solution_observations = entity.active_memory_observations.to_a
      issue_observations = issue.active_memory_observations.to_a
      next if solution_observations.empty? || issue_observations.empty?

      pair = best_issue_solution_pair(solution_observations, issue_observations)
      next unless pair

      build_proposal(
        from_entity_id: entity.id,
        to_entity_id: issue.id,
        relation_type: "solves",
        confidence_band: pair[:confidence_band],
        score: pair[:score],
        supporting_observation_ids: [ pair[:solution_observation].id, pair[:issue_observation].id ],
        explanation: pair[:explanation],
        evidence_terms: pair[:evidence_terms],
        from_entity: entity,
        to_entity: issue
      )
    end
  end

  def dependency_proposals(entity)
    entity.active_memory_observations.flat_map do |observation|
      next [] unless dependency_marked?(observation.content)

      entities_mentioned_in_text(observation.content).filter_map do |mentioned|
        next if mentioned.id == entity.id
        next if project_root?(mentioned)

        build_proposal(
          from_entity_id: entity.id,
          to_entity_id: mentioned.id,
          relation_type: "depends_on",
          confidence_band: "medium",
          score: 8,
          supporting_observation_ids: [ observation.id ],
          explanation: "Observation references dependency on #{mentioned.name}",
          evidence_terms: [ mentioned.name.downcase ],
          from_entity: entity,
          to_entity: mentioned
        )
      end
    end
  end

  def best_issue_solution_pair(solution_observations, issue_observations)
    best = nil

    solution_observations.each do |solution_observation|
      issue_observations.each do |issue_observation|
        next unless solution_marked?(solution_observation.content)
        next unless issue_marked?(issue_observation.content)

        shared_terms = shared_significant_tokens(solution_observation.content, issue_observation.content)
        next if shared_terms.size < 2

        score = (shared_terms.size * 3) + 5
        candidate = {
          solution_observation: solution_observation,
          issue_observation: issue_observation,
          score: score,
          confidence_band: score >= ISSUE_SOLUTION_HIGH_SCORE ? "high" : "medium",
          evidence_terms: shared_terms,
          explanation: "Issue and solution observations share topic tokens: #{shared_terms.join(', ')}"
        }

        best = candidate if best.nil? || candidate[:score] > best[:score]
      end
    end

    best
  end

  def entities_mentioned_in_text(text)
    return [] if text.blank?

    lowered = text.to_s.downcase
    MemoryEntity.where.not(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).select do |entity|
      names = [ entity.name, entity.aliases ].compact.flat_map { |value| value.to_s.split(/[,|;]/) }
      names.any? do |name|
        token = name.to_s.strip.downcase
        token.length >= 3 && lowered.include?(token)
      end
    end
  end

  def build_proposal(from_entity_id:, to_entity_id:, relation_type:, confidence_band:, score:,
                     supporting_observation_ids:, explanation:, evidence_terms: [],
                     from_entity: nil, to_entity: nil)
    return nil if from_entity_id == to_entity_id
    return nil unless ALLOWED_RELATION_TYPES.include?(relation_type)
    return nil if relation_exists?(from_entity_id, to_entity_id, relation_type)

    from = from_entity || MemoryEntity.find_by(id: from_entity_id)
    to = to_entity || MemoryEntity.find_by(id: to_entity_id)

    {
      id: SecureRandom.uuid,
      kind: "relationship_proposal",
      from_entity_id: from_entity_id,
      from_name: from&.name,
      from_entity_type: from&.entity_type,
      to_entity_id: to_entity_id,
      to_name: to&.name,
      to_entity_type: to&.entity_type,
      relation_type: relation_type,
      confidence_band: confidence_band,
      score: score,
      supporting_observation_ids: supporting_observation_ids,
      explanation: explanation,
      evidence_terms: evidence_terms
    }
  end

  def relation_exists?(from_entity_id, to_entity_id, relation_type)
    MemoryRelation.exists?(
      from_entity_id: from_entity_id,
      to_entity_id: to_entity_id,
      relation_type: relation_type
    )
  end

  def ordered_pair(first_id, second_id)
    first_id < second_id ? [ first_id, second_id ] : [ second_id, first_id ]
  end

  def dedupe_and_limit(proposals)
    proposals
      .compact
      .uniq { |proposal| [ proposal[:from_entity_id], proposal[:to_entity_id], proposal[:relation_type] ] }
      .sort_by { |proposal| [ proposal[:from_entity_id], proposal[:to_entity_id], proposal[:relation_type] ] }
      .first(MAX_PROPOSALS_PER_ENTITY)
  end

  def shared_significant_tokens(left, right)
    tokenize(left) & tokenize(right)
  end

  def tokenize(text)
    text.to_s.downcase.split(/[\s_\-\.]+/).map(&:strip).reject { |token| token.length < 3 }.uniq
  end

  def issue_marked?(text)
    tokens = tokenize(text)
    ISSUE_MARKERS.any? { |marker| tokens.include?(marker) || text.to_s.downcase.include?(marker) }
  end

  def solution_marked?(text)
    tokens = tokenize(text)
    SOLUTION_MARKERS.any? { |marker| tokens.include?(marker) || text.to_s.downcase.include?(marker) }
  end

  def dependency_marked?(text)
    tokens = tokenize(text)
    DEPENDENCY_MARKERS.any? { |marker| tokens.include?(marker) || text.to_s.downcase.include?(marker) }
  end
end
