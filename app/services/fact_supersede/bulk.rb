# frozen_string_literal: true

module FactSupersede
  # The Find & supersede page's bulk action (fact supersede F5): supersede the selected
  # observations with one replacement text (or the fact's text), or retire them, in one
  # `explore.bulk_supersede` change set (undoable, like Explore's edits). Never across projects:
  # every row must belong to the chosen project. With a source fact, each row records it in
  # `outdated_by`, and rows the legacy guard keeps are skipped. Rows that are no longer active,
  # or changed after the page was rendered, are skipped and counted.
  #
  #   FactSupersede::Bulk.call(project: gadget, observation_ids: [15, 16], action: "retire", fact: fact)
  #   # => { success: true, message: "Retired 2 observations.", changed: 2, skipped: {}, change_set_uuid: "…", undoable: true }
  class Bulk
    ACTIONS = %w[supersede retire].freeze
    MAX_ROWS = 200
    SKIP_LABELS = {
      inactive: "no longer active", outside: "not in the project", changed: "changed since you looked", kept: "kept by the legacy guard"
    }.freeze

    # @param project [MemoryEntity] a Project root
    # @param observation_ids [Array<#to_i>] at most MAX_ROWS
    # @param action [String] "supersede" or "retire"
    # @param replacement [String, nil] the replacement text (supersede)
    # @param use_fact_text [Boolean] supersede with the fact's text
    # @param reason [String, nil] at most ExploreEdits::MAX_REASON_LENGTH characters
    # @param fact [MemoryObservation, nil] an active source fact of `project`
    # @param rendered_at [Time, nil] rows updated after it are skipped
    # @return [Hash] `{ success:, message:, changed:, skipped:, change_set_uuid:, undoable: }` or `{ success: false, error: }`
    def self.call(project:, observation_ids:, action:, replacement: nil, use_fact_text: false, reason: nil, fact: nil, rendered_at: nil)
      new(project, observation_ids, action, replacement, use_fact_text, reason, fact, rendered_at).call
    end

    def initialize(project, observation_ids, action, replacement, use_fact_text, reason, fact, rendered_at)
      @project = project
      @ids = Array(observation_ids).map(&:to_i).select(&:positive?).uniq
      @action = action.to_s
      @fact = fact
      @replacement = (use_fact_text && fact ? fact.content : replacement).to_s.strip.presence
      @reason = reason.to_s.strip.presence
      @rendered_at = rendered_at
      @skipped = Hash.new(0)
    end

    # @see .call
    def call
      error = refusal
      return { success: false, error: error } if error

      changed = 0
      result = ChangeSet.record(kind: "explore.bulk_supersede", subject: @project, summary: summary) do |context|
        MemoryObservation.transaction do
          MemoryObservation.where(id: @ids).includes(:memory_entity).lock.order(:id).each { |observation| changed += 1 if change(observation) }
        end
        { success: true }.merge(context.undo_handle)
      end
      result.merge(changed: changed, skipped: @skipped.transform_keys(&:to_s), message: message(changed))
    end

    private

    def refusal
      return "Choose a project: a bulk change never crosses projects." unless @project&.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE
      return "Select at least one observation." if @ids.empty?
      return "Select at most #{MAX_ROWS} observations per change (#{@ids.size} selected)." if @ids.size > MAX_ROWS
      return "Choose supersede or retire." unless ACTIONS.include?(@action)
      return "The source fact must be an active fact of this project." if @fact && !(@fact.source_fact? && @fact.fact_project_id == @project.id)
      return "Give the replacement text, or supersede with the fact's text." if @action == "supersede" && @replacement.nil?
      return "The replacement is too long." if @replacement.to_s.length > ExploreEdits::Observations::MAX_OBSERVATION_LENGTH

      "The reason is too long (at most #{ExploreEdits::MAX_REASON_LENGTH} characters)." if @reason.to_s.length > ExploreEdits::MAX_REASON_LENGTH
    end

    # @return [Boolean] changed
    def change(observation)
      skip = skip_reason(observation)
      if skip
        @skipped[skip] += 1
        return false
      end

      reason = @reason || (@fact ? "Outdated by source fact ##{@fact.id}" : "#{@action == 'retire' ? 'Retired' : 'Superseded'} in Find & supersede")
      if @action == "supersede"
        observation.supersede!({ content: @replacement }, reason: reason, outdated_by: @fact)
      else
        observation.mark_obsolete!(reason: reason, outdated_by: @fact)
      end
      true
    end

    def skip_reason(observation)
      return :inactive unless observation.active?
      return :outside unless observation.fact_project_id == @project.id
      return :changed if @rendered_at && observation.updated_at > @rendered_at

      :kept if @fact && guard.check(observation).first == LegacyGuard::KEEP
    end

    def guard
      @guard ||= LegacyGuard.new(@fact)
    end

    def summary
      "#{@action == 'retire' ? 'retired' : 'superseded'} #{@ids.size} observation(s) of '#{@project.name}'#{" (source fact ##{@fact.id})" if @fact}"
    end

    def message(changed)
      verb = @action == "retire" ? "Retired" : "Superseded"
      text = "#{verb} #{changed} observation#{'s' unless changed == 1}."
      skipped = SKIP_LABELS.filter_map { |key, label| "#{@skipped[key]} skipped: #{label}" if @skipped[key].positive? }
      skipped.empty? ? text : "#{text} #{skipped.join('; ')}."
    end
  end
end
