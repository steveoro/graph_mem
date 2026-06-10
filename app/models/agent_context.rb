# frozen_string_literal: true

class AgentContext < ApplicationRecord
  belongs_to :current_project, class_name: "MemoryEntity", optional: true

  validates :client_id, presence: true, uniqueness: true

  def touch_last_seen!
    update_column(:last_seen_at, Time.current)
  end
end
