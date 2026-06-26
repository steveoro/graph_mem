# frozen_string_literal: true

module AuditLogsHelper
  AUDITABLE_TYPES = %w[MemoryEntity MemoryObservation MemoryRelation].freeze
  AUDIT_ACTIONS = %w[create update delete].freeze

  def audit_log_since_days_options
    [
      [ t("operator.audit_logs.since_days_options.days_7"), 7 ],
      [ t("operator.audit_logs.since_days_options.days_30"), 30 ],
      [ t("operator.audit_logs.since_days_options.days_90"), 90 ],
      [ t("operator.audit_logs.since_days_options.all"), "all" ]
    ]
  end

  def audit_log_action_options
    [ [ t("operator.audit_logs.filters.all_actions"), "" ] ] +
      AUDIT_ACTIONS.map { |action| [ t("operator.audit_logs.actions.#{action}"), action ] }
  end

  def audit_log_auditable_type_options
    [ [ t("operator.audit_logs.filters.all_types"), "" ] ] +
      AUDITABLE_TYPES.map { |type| [ type, type ] }
  end

  def audit_log_action_badge(action)
    css = case action.to_s
          when "create" then "dashboard-badge--completed"
          when "update" then "dashboard-badge--running"
          when "delete" then "dashboard-badge--failed"
          else "dashboard-badge--idle"
          end

    content_tag(:span, t("operator.audit_logs.actions.#{action}", default: action.to_s.humanize),
                class: "dashboard-badge #{css}")
  end

  def audit_log_record_label(log)
    label = "#{log.auditable_type}##{log.auditable_id}"

    if log.auditable_type == "MemoryEntity" && MemoryEntity.exists?(log.auditable_id)
      link_to label, graph_path(scoped_entity_id: log.auditable_id), class: "audit-logs-table__record-link"
    elsif log.auditable.present?
      safe_join([ label, tag.br, content_tag(:span, audit_log_auditable_name(log.auditable), class: "audit-logs-table__record-meta") ])
    else
      label
    end
  end

  def audit_log_actor_label(actor)
    actor.presence || t("operator.audit_logs.unknown_actor")
  end

  def audit_log_changed_fields_json(log)
    return "{}" if log.changed_fields.blank?

    JSON.pretty_generate(log.changed_fields)
  end

  private

  def audit_log_auditable_name(record)
    case record
    when MemoryEntity then record.name
    when MemoryObservation then record.content.to_s.truncate(80)
    when MemoryRelation then "#{record.relation_type}: #{record.from_entity&.name} → #{record.to_entity&.name}"
    else record.id.to_s
    end
  end
end
