# frozen_string_literal: true

module Auditable
  extend ActiveSupport::Concern

  MCP_ACTOR_PREFIX = "mcp:"

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
      actor_claim: audit_actor_claim,
      changed_fields: changed_fields,
      reason: audit_reason(action, changed_fields),
      change_set_id: change_set_id
    )
  rescue StandardError => e
    Rails.logger.warn "Audit write failed for #{self.class.name}##{id}: #{e.message}"
    note_audit_failure(Current.change_set)
  end

  # MCP calls only (the web UI and REST have a server-side actor and no claim): the call's
  # transport claim plus the `who` of the record's "<client>/<model>: <task>" source. Display only.
  #
  # @return [String, nil]
  def audit_actor_claim
    return unless Current.actor.to_s.start_with?(MCP_ACTOR_PREFIX)

    ActorClaim.join(Current.actor_claim, audit_source_parts&.first)
  end

  # The first present of: a delete's Current.deletion_reason; an update's new obsolescence_reason
  # (supersede, retire, soft delete); the `why` of the record's "<client>/<model>: <task>" source,
  # but only on a create, an update that set the source, or an MCP call: an operator's edit or a
  # job's update of an agent-written record is not that agent's task. The derived ones are
  # sanitized and truncated (they can be model-written text).
  #
  # @return [String, nil]
  def audit_reason(action, changed_fields)
    return Current.deletion_reason if action == "delete" && Current.deletion_reason.present?

    if action == "update"
      change = changed_fields["obsolescence_reason"]
      new_reason = change.is_a?(Hash) ? (change[:to] || change["to"]) : nil
      return ActorClaim.sanitize(new_reason) if new_reason.present?
    end
    source_set = action == "create" || (action == "update" && changed_fields.key?("source"))
    audit_source_parts&.last if source_set || Current.actor.to_s.start_with?(MCP_ACTOR_PREFIX)
  end

  # @return [Array(String, String), nil] see ActorClaim.source_parts
  def audit_source_parts
    respond_to?(:source) ? ActorClaim.source_parts(source) : nil
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
