# frozen_string_literal: true

class AgentContext < ApplicationRecord
  belongs_to :current_project, class_name: "MemoryEntity", optional: true

  validates :client_id, presence: true, uniqueness: true

  def self.record_activity!(client_id:, tool_name:)
    normalized_id = GraphMemContext.normalize_client_id(client_id)
    record = find_or_create_by!(client_id: normalized_id)
    record.update_columns(last_seen_at: Time.current, last_tool_name: tool_name)
  end

  def touch_last_seen!
    update_column(:last_seen_at, Time.current)
  end
end
