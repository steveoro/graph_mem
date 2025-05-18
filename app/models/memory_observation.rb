class MemoryObservation < ApplicationRecord
  belongs_to :memory_entity, counter_cache: true

  # Add validations if needed, e.g., for content presence
  validates :content, presence: true
end
