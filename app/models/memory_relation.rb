class MemoryRelation < ApplicationRecord
  belongs_to :from_entity, class_name: "MemoryEntity", foreign_key: "from_entity_id"
  belongs_to :to_entity, class_name: "MemoryEntity", foreign_key: "to_entity_id"

  # Add validations if needed
  validates :relation_type, presence: true
end
