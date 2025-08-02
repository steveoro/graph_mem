class MemoryEntity < ApplicationRecord
  has_many :memory_observations, dependent: :destroy
  has_many :relations_from, class_name: "MemoryRelation", foreign_key: "to_entity_id", dependent: :destroy, inverse_of: :to_entity
  has_many :relations_to, class_name: "MemoryRelation", foreign_key: "from_entity_id", dependent: :destroy, inverse_of: :from_entity

  # Add validations if needed, e.g., for name presence and uniqueness
  validates :name, presence: true, uniqueness: true
  validates :entity_type, presence: true

  # Ensure counter cache defaults to 0
  after_initialize :set_default_counter_cache

  private

  def set_default_counter_cache
    self.memory_observations_count ||= 0
  end
end
