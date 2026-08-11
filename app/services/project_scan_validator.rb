# frozen_string_literal: true

# Validates an existing project subtree after a project scan.
#
# Checks observations and relations on pre-existing entities for
# mis-assignment. When the correct target can be resolved unambiguously the
# validator repairs the graph automatically; ambiguous or manually-created
# facts are collected as `scan_review` items so the operator/agent can decide.
#
# The validator is intentionally isolated from the scanner orchestrator and
# can be unit-tested on its own.
class ProjectScanValidator
  # Relation types that imply the source project actually uses the target.
  USAGE_RELATION_TYPES = %w[
    depends_on
    requires
    used_by
    configured_by
    implements
    extends
    integrates_with
  ].freeze

  Result = Struct.new(
    :observations_moved,
    :observations_obsoleted,
    :relations_deleted,
    :entities_reparented,
    :scan_review_items,
    :errors,
    keyword_init: true
  ) do
    def initialize(observations_moved: 0, observations_obsoleted: 0, relations_deleted: 0,
                   entities_reparented: 0, scan_review_items: [], errors: [])
      super
    end
  end

  def initialize(project_entity:, scan_id:, created_entity_ids:, context_text:, extracted_data:,
                 project_root:, dry_run: false, logger: Rails.logger, operation_progress: nil)
    @project_entity = project_entity
    @scan_id = scan_id
    @created_entity_ids = created_entity_ids || Set.new
    @context_text = context_text.to_s
    @extracted_data = extracted_data || {}
    @project_root = project_root.to_s
    @dry_run = dry_run == true
    @logger = logger
    @operation_progress = operation_progress

    @observations_moved = 0
    @observations_obsoleted = 0
    @relations_deleted = 0
    @entities_reparented = 0
    @scan_review_items = []
    @errors = []
  end

  def call
    return result if @project_entity.nil?
    return result unless AppSettings.project_scan_validation_enabled?

    report_progress(phase: "validating_subtree", message: "Validating existing project subtree")

    entity_ids = ProjectSubtree.resolve(@project_entity.id).entity_ids - @created_entity_ids.to_a - [ @project_entity.id ]
    return result if entity_ids.empty?

    total = entity_ids.size
    processed = 0

    MemoryEntity.where(id: entity_ids).find_each do |entity|
      validate_entity_observations(entity)
      validate_entity_relations(entity)
      processed += 1

      if (processed % 10).zero? || processed == total
        report_progress(
          phase: "validating_subtree",
          message: "Validated #{processed}/#{total} entities",
          current: processed,
          total: total
        )
      end
    end

    result
  end

  private

  def result
    Result.new(
      observations_moved: @observations_moved,
      observations_obsoleted: @observations_obsoleted,
      relations_deleted: @relations_deleted,
      entities_reparented: @entities_reparented,
      scan_review_items: @scan_review_items,
      errors: @errors
    )
  end

  def validate_entity_observations(entity)
    entity.active_memory_observations.find_each do |observation|
      next if from_current_scan?(observation.source)
      next if observation.content.blank?

      action = resolve_observation_action(observation, entity)
      case action[:type]
      when :move
        move_observation_to_entity(observation, action[:target_entity])
      when :obsolete
        mark_observation_obsolete(observation, action[:reason])
      when :review
        queue_scan_review(action[:payload])
      end
    end
  rescue StandardError => e
    @logger.warn "ProjectScanValidator: failed to validate observations for entity #{entity.id}: #{e.message}"
  end

  def resolve_observation_action(observation, entity)
    content = observation.content.to_s

    if mentions_owned_terms?(content, entity) || mentions_owned_terms?(content, @project_entity)
      return { type: :keep }
    end

    candidates = find_observation_candidates(content, exclude: entity)
    best = select_best_candidate(candidates)
    scan_sourced = from_project_scan_source?(observation.source)

    if candidates.size > 1
      return queue_move_review(observation, best, candidates, scan_sourced)
    end

    if best
      return scan_sourced ? { type: :move, target_entity: best[:entity] }
                          : queue_move_review(observation, best, candidates, scan_sourced)
    end

    if scan_sourced
      {
        type: :obsolete,
        reason: "Observation does not reference its entity or project and no matching target was found"
      }
    else
      {
        type: :review,
        payload: {
          id: SecureRandom.uuid,
          kind: "delete_observation",
          observation_id: observation.id,
          reason: "Observation does not reference its entity or project and no matching target was found"
        }
      }
    end
  end

  def queue_move_review(observation, best, candidates, scan_sourced)
    candidate_ids = candidates.map { |c| c[:entity].id }
    target = best || candidates.first
    return { type: :review, payload: delete_observation_payload(observation) } if target.nil?

    {
      type: :review,
      payload: {
        id: SecureRandom.uuid,
        kind: "move_observation",
        observation_id: observation.id,
        target_entity_id: target[:entity].id,
        target_name: target[:entity].name,
        candidate_ids: candidate_ids,
        reason: move_review_reason(observation, candidates, scan_sourced)
      }
    }
  end

  def move_review_reason(observation, candidates, scan_sourced)
    prefix = scan_sourced ? "Ambiguous scan target" : "Review move"
    target_names = candidates.map { |c| "#{c[:entity].name} (#{c[:entity].entity_type})" }
    "#{prefix}: observation does not match #{observation.memory_entity&.name || 'its entity'}; " \
      "candidates are #{target_names.join(', ')}"
  end

  def delete_observation_payload(observation)
    {
      id: SecureRandom.uuid,
      kind: "delete_observation",
      observation_id: observation.id,
      reason: "Observation does not reference its entity or project and no matching target was found"
    }
  end

  def find_observation_candidates(content, exclude:)
    candidates = []

    EntitySearchStrategy.new.search(content, limit: 50).each do |result|
      next if result.entity == exclude

      matched_term = content_matches_entity?(content, result.entity)
      next unless matched_term

      candidates << { entity: result.entity, score: result.score, matched_term: matched_term }
    end

    # Project roots are often short/generic and can be missed by token search,
    # so also walk all known projects explicitly.
    MemoryEntity.where(entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE).where.not(id: exclude.id).find_each do |project|
      next if project == @project_entity

      matched_term = content_matches_entity?(content, project)
      next unless matched_term

      candidates << { entity: project, score: 0.0, matched_term: matched_term }
    end

    candidates.uniq { |c| c[:entity].id }
  end

  def select_best_candidate(candidates)
    return nil if candidates.empty?

    candidates.sort_by.with_index do |c, idx|
      # Prefer concrete entities over project roots, then longer matched names,
      # then higher search score, then stable insertion order.
      [
        c[:entity].entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE ? 1 : 0,
        -c[:matched_term].length,
        -c[:score].to_f,
        idx
      ]
    end.first
  end

  def move_observation_to_entity(observation, target_entity)
    return if observation.memory_entity_id == target_entity.id
    return if @dry_run

    ActiveRecord::Base.transaction do
      MemoryObservation.create!(
        memory_entity: target_entity,
        content: observation.content,
        source: scan_source("validation_move"),
        confidence: 1.0
      )
      observation.mark_obsolete!(reason: "Moved to entity #{target_entity.name} (#{target_entity.id}) by project scan validation")
      observation.update!(confidence: 1.0)
    end

    @observations_moved += 1
  rescue StandardError => e
    @logger.warn "ProjectScanValidator: failed to move observation #{observation.id} to #{target_entity.id}: #{e.message}"
    @errors << "Failed to move observation #{observation.id}: #{e.message}"
  end

  def mark_observation_obsolete(observation, reason)
    return if @dry_run

    observation.mark_obsolete!(reason: reason)
    observation.update!(confidence: 1.0)
    @observations_obsoleted += 1
  rescue StandardError => e
    @logger.warn "ProjectScanValidator: failed to obsolete observation #{observation.id}: #{e.message}"
    @errors << "Failed to obsolete observation #{observation.id}: #{e.message}"
  end

  def validate_entity_relations(entity)
    entity.relations_from.find_each do |relation|
      next if from_current_scan?(relation.properties.to_h["source"])
      next if relation.properties.to_h["scan_id"] == @scan_id

      if relation.relation_type == "part_of" && wrong_part_of_to_project_root?(relation)
        delete_relation(relation, "part_of to wrong project root")
        next
      end

      if @context_text.present? && usage_relation?(relation) && !relation_target_in_scan_context?(relation.to_entity)
        queue_scan_review({
          id: SecureRandom.uuid,
          kind: "delete_relation",
          relation_id: relation.id,
          reason: "Target #{relation.to_entity&.name} not found in project scan context"
        })
      end
    end
  rescue StandardError => e
    @logger.warn "ProjectScanValidator: failed to validate relations for entity #{entity.id}: #{e.message}"
  end

  def wrong_part_of_to_project_root?(relation)
    return false unless relation.to_entity

    relation.to_entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE &&
      relation.to_entity_id != @project_entity.id
  end

  def usage_relation?(relation)
    USAGE_RELATION_TYPES.include?(relation.relation_type)
  end

  def relation_target_in_scan_context?(target_entity)
    return true if target_entity.nil?

    terms = entity_terms(target_entity)
    return true if terms.any? { |term| content_matches_term?(@context_text, term) }

    architecture_names.any? { |name| terms.any? { |term| content_matches_term?(name, term) } }
  end

  def delete_relation(relation, reason)
    return if @dry_run

    Current.deletion_reason = reason
    relation.destroy!
    @relations_deleted += 1
  rescue StandardError => e
    @logger.warn "ProjectScanValidator: failed to delete relation #{relation.id}: #{e.message}"
    @errors << "Failed to delete relation #{relation.id}: #{e.message}"
  ensure
    Current.deletion_reason = nil
  end

  def mentions_owned_terms?(content, owner)
    return false unless owner

    terms = entity_terms(owner)
    terms.any? { |term| content_matches_term?(content, term) }
  end

  def entity_terms(entity)
    terms = [ entity.name.to_s.strip ]
    terms += entity.aliases.to_s.split(/[,|;]/).map(&:strip) if entity.aliases.present?
    terms.map(&:downcase).reject(&:blank?).reject { |t| t.length < 3 }.uniq
  end

  def content_matches_entity?(content, entity)
    entity_terms(entity).find { |term| content_matches_term?(content, term) }
  end

  def content_matches_term?(content, term)
    return false if term.blank? || term.length < 3

    words = term.split(/\s+/)
    pattern = words.map { |w| Regexp.escape(w) }.join("\\W+")
    content.to_s.match?(/(?:^|\W)#{pattern}(?:$|\W)/i)
  end

  def architecture_names
    @architecture_names ||= begin
      names = (@extracted_data["architecture"] || []).map { |item| item.dig("entity", "name").to_s }
      names.reject(&:blank?)
    end
  end

  def from_current_scan?(source)
    source.to_s.include?(@scan_id)
  end

  def from_project_scan_source?(source)
    source = source.to_s
    return false if source.include?(@scan_id)

    source.start_with?("project_scan") || source.start_with?("project_scan_skill")
  end

  def scan_source(phase = "reconcile")
    "project_scan:#{@scan_id}:#{phase}"
  end

  def queue_scan_review(item)
    @scan_review_items << item
  end

  def report_progress(phase:, message:, current: nil, total: nil)
    return unless @operation_progress

    @operation_progress.update_progress!(
      current: current || @operation_progress.current_count.to_i + 1,
      total: total || [ @operation_progress.total_count.to_i, 5 ].max,
      phase: phase,
      message: message,
      counters: {
        observations_moved: @observations_moved,
        observations_obsoleted: @observations_obsoleted,
        relations_deleted: @relations_deleted,
        entities_reparented: @entities_reparented
      }
    )

    OperationProgressBroadcaster.call(@operation_progress)
  end
end
