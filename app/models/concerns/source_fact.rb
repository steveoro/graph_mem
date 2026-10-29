# frozen_string_literal: true

# Source facts (fact supersede, 1.64.0): an active observation tagged `source-fact` is
# authoritative for its entity's project, and may outdate (retire or supersede) other
# observations of that project. `outdated_by` records which fact did it.
#
#   observation.source_fact?            # => true (active, tagged, inside a project)
#   observation.replaces_terms          # => ["fast-mcp"] from a "replaces:fast-mcp" tag
#   observation.fact_project_id         # => 12 (the entity's project, or the entity itself when it is a Project root)
#   observation.operator_confirmed_fact? # => true when an operator added the tag
#
# Included by MemoryObservation.
module SourceFact
  extend ActiveSupport::Concern

  SOURCE_FACT_TAG = "source-fact"
  REPLACES_TAG_PREFIX = "replaces:"
  # A `replaces:` term (and any search term) is 2-100 characters; at most MAX_TERMS are used.
  TERM_LENGTH = (2..100)
  MAX_TERMS = 5
  OPERATOR_ACTOR_PREFIX = "operator:"

  included do
    belongs_to :outdated_by, class_name: "MemoryObservation", optional: true, inverse_of: :outdated_observations
    has_many :outdated_observations, class_name: "MemoryObservation", foreign_key: :outdated_by_id,
                                     dependent: :nullify, inverse_of: :outdated_by

    # Tagged rows, whatever their status (tags is a JSON array column).
    scope :fact_tagged, -> { where("JSON_CONTAINS(memory_observations.tags, ?)", [ SOURCE_FACT_TAG ].to_json) }

    validate :source_fact_is_in_a_project, if: -> { fact_tagged? && active? && (new_record? || will_save_change_to_tags?) }
    validate :outdated_by_is_consistent, if: -> { outdated_by_id.present? }
  end

  # @param terms [Array<String>, String, nil]
  # @return [Array<String>] stripped, unique (case-insensitive), TERM_LENGTH long, at most MAX_TERMS
  def self.normalize_terms(terms)
    Array(terms).filter_map { |term| term.to_s.strip.presence }.select { |term| TERM_LENGTH.cover?(term.length) }
                .uniq(&:downcase).first(MAX_TERMS)
  end

  # @return [Boolean] carries the `source-fact` tag (any status)
  def fact_tagged?
    Array(tags).include?(SOURCE_FACT_TAG)
  end

  # @return [Boolean] an active, tagged observation inside a project
  def source_fact?
    active? && fact_tagged? && fact_project_id.present?
  end

  # @return [Array<String>] the terms of this fact's `replaces:<term>` tags (a search hint)
  def replaces_terms
    SourceFact.normalize_terms(Array(tags).filter_map { |tag| tag.delete_prefix(REPLACES_TAG_PREFIX) if tag.to_s.start_with?(REPLACES_TAG_PREFIX) })
  end

  # @return [Integer, nil] the project root id of the owner entity (the entity itself for a root)
  def fact_project_id
    entity = memory_entity
    return unless entity

    entity.project_id || (entity.id if entity.entity_type == NodeOperationsStrategy::PROJECT_ENTITY_TYPE)
  end

  # Only operator-confirmed facts may be auto-applied: the latest audit row that added the tag
  # (on create or on an update) has an `operator:` actor. Agent-marked facts only ever propose.
  #
  # @return [Boolean]
  def operator_confirmed_fact?
    return false unless source_fact?

    added = AuditLog.where(auditable_type: "MemoryObservation", auditable_id: id).order(id: :desc).find { |log| added_fact_tag?(log) }
    added&.actor.to_s.start_with?(OPERATOR_ACTOR_PREFIX)
  end

  private

  def added_fact_tag?(log)
    fields = log.changed_fields.to_h
    case log.action
    when "create" then Array(fields["tags"]).include?(SOURCE_FACT_TAG)
    when "update"
      change = fields["tags"]
      change.is_a?(Hash) && Array(change["to"]).include?(SOURCE_FACT_TAG) && !Array(change["from"]).include?(SOURCE_FACT_TAG)
    else false
    end
  end

  def source_fact_is_in_a_project
    errors.add(:tags, "#{SOURCE_FACT_TAG} needs an entity inside a project") if fact_project_id.blank?
  end

  def outdated_by_is_consistent
    errors.add(:outdated_by, "is only valid for inactive observations") if active?
    return errors.add(:outdated_by, "cannot reference itself") if outdated_by_id == id

    fact = outdated_by
    return errors.add(:outdated_by, "must exist") unless fact
    return unless will_save_change_to_outdated_by_id?

    same_project = fact.fact_project_id.present? && fact.fact_project_id == fact_project_id
    errors.add(:outdated_by, "must be a source fact in the same project") unless fact.fact_tagged? && same_project
  end
end
