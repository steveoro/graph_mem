# frozen_string_literal: true

class DetectContradictionsTool < ApplicationTool
  MODES = %w[contradictions outdated_by_fact].freeze
  FACT_MODE_ARGUMENTS = %i[fact_observation_id terms seed_review].freeze
  FACT_MODE_MAX_RESULTS = 50
  # The judge's batches one tool call may wait for (8 candidates each); the rest come back unjudged.
  FACT_MODE_JUDGE_BATCHES = 2

  def self.tool_name
    "detect_contradictions"
  end

  mcp_metadata(
    profiles: %i[maintenance],
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Scan an entity's active observations and 1-hop related observations for semantically similar pairs with " \
    "opposite polarity; returns candidates and stores a contradictions MaintenanceReport. Pass required `entity_id` " \
    "(integer; also accepts entity name); optional `max_distance` (float, default 0.35), `max_results` (integer, default 20). " \
    "With `mode: \"outdated_by_fact\"` it instead finds what one source fact (an observation tagged `source-fact`) outdates " \
    "in the fact's own project: pass `entity_id` = the fact's entity, required `fact_observation_id`, optional `terms` " \
    "(up to 5 strings), `seed_review` (bool, default true) and `max_results` (at most 50; `max_distance` is ignored); it " \
    "returns new proposals with their review row ids (pairs already queued or dismissed are skipped) and never writes " \
    "observations. With the LLM judge on it waits for at most 2 judge calls (16 candidates); the rest come back unjudged. " \
    "Apply them with `apply_maintenance_review` " \
    "(`action_params.fact_action` supersede or retire, optional `replacement`). Does not merge or delete. " \
    "Do not use for trust ranking; use `rank_observations` instead. " \
    "Do not use for duplicate entities; use `suggest_merges` instead. " \
    "Do not use to read stored reports; use `get_maintenance_reports` instead. " \
    "Do not use to resolve a conflicting fact; use `graph_edit` or `graph_delete` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to scan for contradictions.")
    optional(:max_distance).filled(:float).description("Maximum cosine distance threshold (smaller = stricter). Defaults to 0.35.")
    optional(:max_results).filled(:integer).description("Maximum candidate pairs to return. Defaults to 20.")
    optional(:mode).filled(:string).description('"contradictions" (default) or "outdated_by_fact".')
    optional(:fact_observation_id).filled(:integer).description("outdated_by_fact only (required there): the source fact, an observation of entity_id.")
    optional(:terms).array(:string).description("outdated_by_fact only: up to 5 search terms (2-100 characters each) besides the fact's replaces: tags.")
    optional(:seed_review).filled(:bool).description("outdated_by_fact only: seed the proposals as review rows. Defaults to true.")
  end

  def call(entity_id:, max_distance: 0.35, max_results: 20, mode: nil, **fact_arguments)
    logger.info "Performing DetectContradictionsTool with entity_id: #{entity_id}"
    begin
      entity = MemoryEntity.find(entity_id)
      mode = check_mode!(mode, fact_arguments)
      return outdated_by_fact(entity, max_results, **fact_arguments) if mode == "outdated_by_fact"

      pairs = ContradictionDetector.detect(
        entity_id,
        max_distance: max_distance,
        max_results: max_results,
        persist: true
      )

      {
        entity_id: entity.id,
        name: entity.name,
        candidate_count: pairs.length,
        candidates: pairs.map do |p|
          {
            observation_id_1: p.observation_id_1,
            observation_id_2: p.observation_id_2,
            distance: p.distance,
            confidence: p.confidence
          }
        end
      }
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in DetectContradictionsTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search` to find the entity, then retry `detect_contradictions`."
      )
    rescue McpGraphMemErrors::InvalidArguments
      raise
    rescue StandardError => e
      raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }

      logger.error "InternalServerError in DetectContradictionsTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end

  private

  def check_mode!(mode, fact_arguments)
    mode = (mode.presence || "contradictions").to_s
    invalid!("Unknown mode #{mode.inspect}; use \"contradictions\" or \"outdated_by_fact\".") unless MODES.include?(mode)
    extra = fact_arguments.compact.keys & FACT_MODE_ARGUMENTS
    if mode == "contradictions" && extra.any?
      invalid!("#{extra.map { |key| "`#{key}`" }.join(', ')} only work with mode \"outdated_by_fact\".",
               next_move: "Retry `detect_contradictions` with `mode: \"outdated_by_fact\"`, or without those arguments.")
    end
    mode
  end

  # The fact-supersede scan (fact supersede F6): FactSupersede::Proposals, in the fact's project only.
  def outdated_by_fact(entity, max_results, fact_observation_id: nil, terms: nil, seed_review: nil)
    fact = fact_for!(entity, fact_observation_id)
    invalid!("`max_results` must be between 1 and #{FACT_MODE_MAX_RESULTS} in this mode.") unless (1..FACT_MODE_MAX_RESULTS).cover?(max_results.to_i)
    terms = Array(terms)
    if terms.size > SourceFact::MAX_TERMS || terms.any? { |term| !SourceFact::TERM_LENGTH.cover?(term.to_s.strip.length) }
      invalid!("`terms` takes at most #{SourceFact::MAX_TERMS} strings of 2-100 characters.")
    end

    result = FactSupersede::Proposals.call(fact, terms: terms, limit: max_results.to_i, seed: seed_review != false,
                                           max_batches: FACT_MODE_JUDGE_BATCHES)
    rows = result.rows.index_by { |row| row.payload["observation_id"].to_i }
    {
      mode: "outdated_by_fact", entity_id: entity.id, name: entity.name, fact_observation_id: fact.id, searched: result.searched,
      judged: result.judged, candidate_count: result.candidates, kept_by_guard: result.kept, already_known: result.known,
      proposal_count: result.items.size,
      seeded_count: result.rows.size, proposals: result.items.map { |item| proposal(item, rows) }
    }
  end

  def fact_for!(entity, fact_observation_id)
    unless fact_observation_id
      invalid!("`fact_observation_id` is required with mode \"outdated_by_fact\".",
               next_move: "Call `get_entities` on the entity to find its source-fact observation, then retry `detect_contradictions`.")
    end
    fact = MemoryObservation.find_by(id: fact_observation_id, memory_entity_id: entity.id)
    return fact if fact&.source_fact?

    invalid!("Observation ##{fact_observation_id} is not an active source fact of entity ##{entity.id}.",
             next_move: "Tag the observation `source-fact` with `graph_edit` (its entity must be in a project), or pass the fact's own entity_id.")
  end

  def proposal(item, rows)
    item.slice("observation_id", "entity_id", "entity_name", "project_id", "content", "verdict", "confidence", "reason", "replacement",
               "guard", "guard_reason", "signals").merge("review_row_id" => rows[item["observation_id"]]&.row_uuid)
  end

  def invalid!(message, next_move: "Correct the arguments and retry `detect_contradictions`.")
    raise McpGraphMemErrors::InvalidArguments.new(message, next_move: next_move)
  end
end
