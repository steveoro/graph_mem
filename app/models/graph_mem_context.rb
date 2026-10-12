# frozen_string_literal: true

# Per-client store for the active project context.
#
# Each MCP agent identifies itself via the X-MCP-Client header. Context is
# persisted in agent_contexts so it survives restarts and is isolated between
# agents. Agents without the header share the "default" client bucket.
class GraphMemContext
  DEFAULT_CLIENT_ID = "default"
  # NOTE: MAX_SCOPED_ENTITIES is gone — scope is an indexed project_id
  # lookup since project-scoped names landed, so there is nothing to cap
  # and scope_truncated is always false.

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

    def scoped_entity_scope
      self.for(DEFAULT_CLIENT_ID).scoped_entity_scope
    end

    def clear_all!
      AgentContext.delete_all
    end
  end

  attr_reader :client_id

  def initialize(client_id)
    @client_id = self.class.normalize_client_id(client_id)
  end

  # Read path stays non-creating: resolving the context (e.g. during tool
  # arg normalization) must not mint an AgentContext row — that is real
  # client activity and a failed call must not record it. Writers
  # (set_project!/clear!) still go through `record` and create it.
  def current_project_id
    AgentContext.find_by(client_id: client_id)&.current_project_id
  end

  def current_project_id=(id)
    set_project!(id)
  end

  def context_set_at
    record.context_set_at
  end

  # Activates a project and reports what it displaced.
  #
  # Returns the previously active MemoryEntity when this change overwrote a
  # different project that was set moments ago under the same client_id — the
  # signature of two agents sharing one X-MCP-Client. Returns nil otherwise.
  def set_project!(id)
    ctx = record
    displaced = ctx.context_conflict_with?(id) ? ctx.current_project : nil
    ctx.update!(current_project_id: id, last_seen_at: Time.current, context_set_at: Time.current)
    displaced
  end

  def clear!
    record.update!(current_project_id: nil, last_seen_at: Time.current, context_set_at: Time.current)
  end

  def active?
    current_project_id.present?
  end

  # Returns entity IDs related to the current project (via recursive part_of relations).
  # Used by search tools to boost in-context results and by summarization to hard-scope retrieval.
  def scoped_entity_ids
    scoped_entity_scope&.entity_ids
  end

  # Returns scope IDs plus (now vestigial) truncation metadata for
  # diagnostics — always truncated: false since the cap was removed.
  def scoped_entity_scope
    return nil unless active?

    # Project-scoped names made scope an indexed column lookup instead of
    # a capped part_of walk: members carry project_id = their Project root.
    # The 1000-entity cap is gone — the predicate is a single indexed filter
    # (the root itself stays NULL-project, hence the OR on id).
    entity_ids = MemoryEntity.where(project_id: current_project_id)
      .or(MemoryEntity.where(id: current_project_id)).pluck(:id)
    ProjectSubtree::Result.new(entity_ids: entity_ids, truncated: false, max_entities: nil)
  end

  private

  def record
    AgentContext.find_or_create_by!(client_id: client_id) do |ctx|
      ctx.last_seen_at = Time.current
    end.tap(&:touch_last_seen!)
  end
end
