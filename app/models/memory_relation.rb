# frozen_string_literal: true

class MemoryRelation < ApplicationRecord
  include Auditable

  belongs_to :from_entity, class_name: "MemoryEntity", foreign_key: "from_entity_id"
  belongs_to :to_entity, class_name: "MemoryEntity", foreign_key: "to_entity_id"

  serialize :properties, coder: JSON

  before_validation :canonicalize_relation_type

  validates :relation_type, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :properties_are_an_object

  def self.canonical_relation_type(raw_type)
    RelationTypeMapping.canonicalize(raw_type) || raw_type
  end

  private

  def canonicalize_relation_type
    return if relation_type.blank?

    canonical = RelationTypeMapping.canonicalize(relation_type)
    self.relation_type = canonical if canonical.present?
  end

  def properties_are_an_object
    return if properties.is_a?(Hash)

    errors.add(:properties, "must be an object")
  end
end
