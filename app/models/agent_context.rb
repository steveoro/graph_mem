# frozen_string_literal: true

class AgentContext < ApplicationRecord
  # How recently another agent must have touched this row for its activity to
  # count as concurrent rather than as a previous session.
  CONFLICT_WINDOW = 5.minutes

  belongs_to :current_project, class_name: "MemoryEntity", optional: true

  validates :client_id, presence: true, uniqueness: true

  # Set on the instance returned by .record_activity! when a different MCP
  # session was seen under the same client_id inside CONFLICT_WINDOW. Not
  # persisted: it describes this call, not the row.
  attr_accessor :concurrent_session

  def self.record_activity!(client_id:, tool_name:, session_id: nil)
    normalized_id = GraphMemContext.normalize_client_id(client_id)
    record = find_or_create_by!(client_id: normalized_id)
    record.concurrent_session = record.concurrent_session?(session_id)

    updates = { last_seen_at: Time.current, last_tool_name: tool_name }
    updates[:last_session_id] = session_id if session_id.present?
    record.update_columns(updates)

    record
  end

  def touch_last_seen!
    update_column(:last_seen_at, Time.current)
  end

  # True when a *different* Streamable HTTP session used this same client_id
  # moments ago. Both sessions share this one row, so whichever calls
  # set_context last silently rescopes the other.
  #
  # Always false on the legacy /mcp/sse endpoint, which carries no session id —
  # use #context_conflict_with? to detect clobbering there.
  def concurrent_session?(session_id)
    return false if session_id.blank? || last_session_id.blank?
    return false if last_session_id == session_id
    return false if last_seen_at.blank?

    last_seen_at > CONFLICT_WINDOW.ago
  end

  # True when switching to new_project_id would overwrite a *different* project
  # that was set under this same client_id inside CONFLICT_WINDOW.
  #
  # This is the transport-independent clobbering signal: a single agent rarely
  # rescopes itself twice in a few minutes, whereas two agents sharing one
  # client id do it constantly.
  def context_conflict_with?(new_project_id)
    return false if current_project_id.blank?
    return false if current_project_id == new_project_id
    return false if context_set_at.blank?

    context_set_at > CONFLICT_WINDOW.ago
  end
end
