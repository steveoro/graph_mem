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

  # Audit rows join the open change set (UI-4a). Neither a failed change set nor a failed audit
  # row ever blocks the write; either one only marks the set as not undoable.
  def write_audit(action, changed_fields)
    change_set_id = change_set_id_for(action)
    AuditLog.create!(
      auditable_type: self.class.name,
      auditable_id: id,
      action: action,
      actor: Current.actor,
      changed_fields: changed_fields,
      reason: action == "delete" ? Current.deletion_reason : nil,
      change_set_id: change_set_id
    )
  rescue StandardError => e
    Rails.logger.warn "Audit write failed for #{self.class.name}##{id}: #{e.message}"
    note_audit_failure(Current.change_set)
  end

  # @return [Integer, nil] the open set's id; nil when there is none or it can't be written
  def change_set_id_for(action)
    change_set = Current.change_set
    return unless change_set

    change_set.note_audit!(self, action)
    change_set.persist!
  rescue StandardError => e
    Rails.logger.warn "Change set update failed for #{self.class.name}##{id}: #{e.message}"
    note_audit_failure(change_set)
    nil
  end

  def note_audit_failure(change_set)
    change_set&.note_audit_failure!
  rescue StandardError => e
    Rails.logger.warn "Change set update failed for #{self.class.name}##{id}: #{e.message}"
  end

  def auditable_snapshot
    attributes.except("embedding")
  end
end
