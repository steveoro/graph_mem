# frozen_string_literal: true

module FactSupersede
  # The Find & supersede page's listing (fact supersede F5): observations whose text matches the
  # search (escaped LIKE), in one project or across all of them, inactive ones too when asked;
  # with a source fact chosen, the fact's candidates (vector and terms), each with its legacy
  # guard and the verdict of its pending "Outdated by a fact" row. No LLM call.
  #
  #   search = FactSupersede::Search.new(q: "fast-mcp", project_id: "12", fact_id: "40")
  #   search.entries.first # => #<struct Entry observation=…, guard="context", verdict="unjudged", changeable=true, …>
  #   search.all_projects? # => false (actions are only offered for one project)
  class Search
    MAX_MATCHES = 500
    ALL_PROJECTS = "all"

    # @!attribute changeable [Boolean] can be selected: active, in the chosen project, one project chosen, not kept
    Entry = Struct.new(:observation, :project_id, :project_name, :scoped, :guard, :guard_reason, :verdict, :confidence, :changeable,
                       keyword_init: true)

    attr_reader :q, :project, :fact, :include_inactive

    # @param q [String, nil] search text (2-100 characters)
    # @param project_id [String, nil] a Project root id, or "all"
    # @param fact_id [String, nil] a source fact of that project
    # @param include_inactive [Boolean]
    def initialize(q: nil, project_id: nil, fact_id: nil, include_inactive: false)
      @q = q.to_s.strip.presence
      @all = project_id.to_s == ALL_PROJECTS
      @project = MemoryEntity.find_by(id: project_id.to_i, entity_type: NodeOperationsStrategy::PROJECT_ENTITY_TYPE) unless @all
      @fact = MemoryObservation.includes(:memory_entity).find_by(id: fact_id.to_i) if @project && fact_id.present?
      @fact = nil unless @fact&.source_fact? && @fact.fact_project_id == @project&.id
      @include_inactive = include_inactive
    end

    def all_projects? = @all

    # @return [String, nil] why there is nothing to list yet
    def missing
      return "Choose a project (or all projects)." unless @project || @all
      return "Type at least #{SourceFact::TERM_LENGTH.min} characters to search all projects." if @all && term.nil?

      "Type at least #{SourceFact::TERM_LENGTH.min} characters, or choose a source fact." if term.nil? && !@fact
    end

    # @return [Boolean, nil] whether similarity search ran (nil without a fact)
    def vector? = @fact ? candidates_result.vector : nil

    # @return [Array<MemoryObservation>] the chosen project's active source facts (the picker)
    def facts
      return [] unless @project

      members = MemoryEntity.where(project_id: @project.id).or(MemoryEntity.where(id: @project.id)).select(:id)
      MemoryObservation.active.fact_tagged.where(memory_entity_id: members).order(:id).limit(MAX_MATCHES).to_a
    end

    # @return [Array<Entry>] at most MAX_MATCHES, by score (with a fact) or by project then id
    def entries
      @entries ||= missing ? [] : (@fact ? fact_entries : text_entries)
    end

    # @return [Boolean] more than MAX_MATCHES matched
    def capped? = entries.size >= MAX_MATCHES

    private

    def term
      @q if @q && SourceFact::TERM_LENGTH.cover?(@q.length)
    end

    def candidates_result
      @candidates_result ||= Candidates.call(@fact, query: term, limit: MAX_MATCHES, include_inactive: @include_inactive)
    end

    def fact_entries
      candidates = LegacyGuard.new(@fact).apply(candidates_result.candidates)
      verdicts = pending_verdicts
      candidates.map do |candidate|
        observation = candidate.observation
        verdict, confidence = verdicts[observation.id]
        Entry.new(observation: observation, project_id: candidate.scoped ? @project.id : nil, project_name: candidate.scoped ? @project.name : nil,
                  scoped: candidate.scoped, guard: candidate.guard, guard_reason: candidate.guard_reason, verdict: verdict, confidence: confidence,
                  changeable: observation.active? && candidate.scoped && candidate.guard != LegacyGuard::KEEP)
      end
    end

    def text_entries
      scope = MemoryObservation.where("memory_observations.content LIKE ?", "%#{MemoryObservation.sanitize_sql_like(term)}%")
      scope = scope.active unless @include_inactive
      scope = scope.where(memory_entity_id: MemoryEntity.where(project_id: @project.id).or(MemoryEntity.where(id: @project.id)).select(:id)) if @project
      observations = scope.includes(:memory_entity).order(:id).limit(MAX_MATCHES).to_a
      names = project_names(observations)
      observations.map do |observation|
        project_id = observation.fact_project_id
        Entry.new(observation: observation, project_id: project_id, project_name: names[project_id], scoped: !project_id.nil?,
                  changeable: !@all && observation.active?)
      end.sort_by { |entry| [ entry.project_name.to_s, entry.observation.id ] }
    end

    def project_names(observations)
      ids = observations.filter_map(&:fact_project_id).uniq
      MemoryEntity.where(id: ids).pluck(:id, :name).to_h
    end

    # @return [Hash{Integer => Array(String, Float)}] the pending row's verdict and confidence per observation
    def pending_verdicts
      MaintenanceReportRow.pending.where(kind: Proposals::KIND)
                          .where("JSON_VALUE(payload, '$.fact_observation_id') = ?", @fact.id.to_s)
                          .each_with_object({}) do |row, verdicts|
        verdicts[row.payload["observation_id"].to_i] = [ row.payload["verdict"], row.payload["confidence"] ]
      end
    end
  end
end
