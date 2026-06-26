# frozen_string_literal: true

# Aggregates per-MCP-client project context and recent activity for the operator dashboard.
class AgentContextsSnapshot
  ACTIVE_THRESHOLD = 5.minutes
  IDLE_THRESHOLD = 1.hour

  def self.call
    new.call
  end

  def call
    contexts = AgentContext.includes(:current_project).order(Arel.sql("last_seen_at IS NULL"), last_seen_at: :desc)

    {
      summary: summary(contexts),
      clients: contexts.map { |context| client_row(context) }
    }
  end

  private

  def summary(contexts)
    recent = contexts.select { |context| recent?(context.last_seen_at) }
    with_context = contexts.select(&:current_project_id?)

    {
      total: contexts.size,
      recent_count: recent.size,
      with_context_count: with_context.size,
      default_bucket: contexts.any? { |context| context.client_id == GraphMemContext::DEFAULT_CLIENT_ID }
    }
  end

  def client_row(context)
    project = context.current_project

    {
      client_id: context.client_id,
      activity_status: activity_status(context.last_seen_at),
      last_seen_at: context.last_seen_at,
      last_tool_name: context.last_tool_name,
      project: project_payload(project),
      shared_default_bucket: context.client_id == GraphMemContext::DEFAULT_CLIENT_ID
    }
  end

  def project_payload(project)
    return nil unless project

    {
      id: project.id,
      name: project.name,
      entity_type: project.entity_type
    }
  end

  def activity_status(last_seen_at)
    return "unknown" if last_seen_at.blank?
    return "active" if last_seen_at >= ACTIVE_THRESHOLD.ago
    return "idle" if last_seen_at >= IDLE_THRESHOLD.ago

    "stale"
  end

  def recent?(last_seen_at)
    last_seen_at.present? && last_seen_at >= ACTIVE_THRESHOLD.ago
  end
end
