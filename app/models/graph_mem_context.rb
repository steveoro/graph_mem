# frozen_string_literal: true

# Per-client store for the active project context.
#
# Each MCP agent identifies itself via the X-MCP-Client header. Context is
# persisted in agent_contexts so it survives restarts and is isolated between
# agents. Agents without the header share the "default" client bucket.
class GraphMemContext
  DEFAULT_CLIENT_ID = "default"

  class << self
    def for(client_id = DEFAULT_CLIENT_ID)
      new(normalize_client_id(client_id))
    end

    def normalize_client_id(client_id)
      client_id.to_s.strip.presence || DEFAULT_CLIENT_ID
    end

    # Class-level accessors delegate to the default client for backward compatibility.
    def current_project_id
      self.for(DEFAULT_CLIENT_ID).current_project_id
    end

    def current_project_id=(id)
      self.for(DEFAULT_CLIENT_ID).current_project_id = id
    end

    def clear!
      self.for(DEFAULT_CLIENT_ID).clear!
    end

    def active?
      self.for(DEFAULT_CLIENT_ID).active?
    end

    def scoped_entity_ids
      self.for(DEFAULT_CLIENT_ID).scoped_entity_ids
    end

    def clear_all!
      AgentContext.delete_all
    end
  end

  attr_reader :client_id

  def initialize(client_id)
    @client_id = self.class.normalize_client_id(client_id)
  end

  def current_project_id
    record.current_project_id
  end

  def current_project_id=(id)
    record.update!(current_project_id: id, last_seen_at: Time.current)
  end

  def clear!
    record.update!(current_project_id: nil, last_seen_at: Time.current)
  end

  def active?
    current_project_id.present?
  end

  # Returns entity IDs related to the current project (via part_of relations).
  # Used by search tools to boost in-context results.
  def scoped_entity_ids
    return nil unless active?

    ids = [ current_project_id ]
    ids += MemoryRelation
      .where(relation_type: "part_of", to_entity_id: current_project_id)
      .pluck(:from_entity_id)
    ids.uniq
  end

  private

  def record
    AgentContext.find_or_create_by!(client_id: client_id) do |ctx|
      ctx.last_seen_at = Time.current
    end.tap(&:touch_last_seen!)
  end
end
