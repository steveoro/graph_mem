# frozen_string_literal: true

module Auditable
  extend ActiveSupport::Concern

  included do
    after_create  :audit_create
    after_update  :audit_update
    after_destroy :audit_destroy
  end

  private

  def audit_create
    write_audit("create", auditable_snapshot)
  end

  def audit_update
    return if previous_changes.except("updated_at").empty?

    changes = previous_changes.except("updated_at").transform_values do |old_new|
      { from: old_new.first, to: old_new.last }
    end
    write_audit("update", changes)
  end

  def audit_destroy
    write_audit("delete", auditable_snapshot)
  end

  def write_audit(action, changed_fields)
    AuditLog.create!(
      auditable_type: self.class.name,
      auditable_id: id,
      action: action,
      actor: Current.actor,
      changed_fields: changed_fields
    )
  rescue StandardError => e
    Rails.logger.warn "Audit write failed for #{self.class.name}##{id}: #{e.message}"
  end

  def auditable_snapshot
    attributes.except("embedding")
  end
end
