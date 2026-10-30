# frozen_string_literal: true

# Fills the actor of change sets and audit rows that MCP writes left empty before 1.65.0
# (`rake audit:backfill_actors`). Only rows whose actor IS NULL, and only the graph.write /
# graph.edit / graph.delete kinds: the MCP tools open them at that level (Explore opens explore.*,
# REST api.write, and a nested ChangeSet.record joins the outer set), so the mapping is exact.
# Other nil-actor sets (review.* and the rest) can come from MCP or from a job: they are left.
#
# Audit rows of those sets get the same actor. A MemoryObservation row also gets the source's
# claim ("backfilled · <who>"; the X-MCP-Client and clientInfo can't be recovered) and, when its
# reason is nil, a reason: the `why` of a create/delete source, or an update's new
# obsolescence_reason / source. Nothing is read from the observation's current row.
#
# No callbacks (update_all), so no audit row is written; batches of BATCH_SIZE, one transaction
# each. A second run changes nothing.
#
#   AuditActorBackfill.new(apply: false, out: $stdout).call
#   # => { "change_sets" => { "graph.write" => 12 }, "audit_logs" => { "graph.write" => 40 }, "claims" => 30, "reasons" => 28 }
class AuditActorBackfill
  KIND_ACTORS = { "graph.write" => "mcp:graph_write", "graph.edit" => "mcp:graph_edit", "graph.delete" => "mcp:graph_delete" }.freeze
  BATCH_SIZE = 500
  CLAIM_PREFIX = "backfilled"

  # @param apply [Boolean] false = dry run (counts only)
  # @param out [#puts] where the report goes
  def initialize(apply:, out: $stdout)
    @apply = apply
    @out = out
    @counts = { "change_sets" => Hash.new(0), "audit_logs" => Hash.new(0), "claims" => 0, "reasons" => 0 }
  end

  # @return [Hash] the counts per table and kind, and the claims and reasons derived
  def call
    backfill_audit_logs
    backfill_change_sets
    report
    @counts
  end

  private

  # Audit rows first: they're found through their set's kind, whatever the set's actor, so an
  # interrupted run picks them up again.
  def backfill_audit_logs
    AuditLog.joins(:change_set).where(actor: nil, change_sets: { kind: KIND_ACTORS.keys })
            .select("audit_logs.*", "change_sets.kind AS set_kind").find_in_batches(batch_size: BATCH_SIZE) do |batch|
      AuditLog.transaction do
        batch.each do |row|
          @counts["audit_logs"][row[:set_kind]] += 1
          updates = { actor: KIND_ACTORS.fetch(row[:set_kind]) }.merge(observation_fields(row))
          AuditLog.where(id: row.id, actor: nil).update_all(updates) if @apply
        end
      end
    end
  end

  def backfill_change_sets
    KIND_ACTORS.each do |kind, actor|
      ChangeSet.where(kind: kind, actor: nil).in_batches(of: BATCH_SIZE) do |batch|
        ChangeSet.transaction do
          @counts["change_sets"][kind] += batch.count
          batch.update_all(actor: actor) if @apply
        end
      end
    end
  end

  # @return [Hash] actor_claim and reason derived from the row's own changed_fields
  def observation_fields(row)
    return {} unless row.auditable_type == "MemoryObservation"

    fields = row.changed_fields.to_h
    if row.action == "update"
      who, why = ActorClaim.source_parts(new_value(fields["source"]))
      obsolescence_reason = new_value(fields["obsolescence_reason"])
      why = ActorClaim.sanitize(obsolescence_reason) if obsolescence_reason.present?
    else
      who, why = ActorClaim.source_parts(fields["source"])
    end
    updates = {}
    updates[:actor_claim] = ActorClaim.join(CLAIM_PREFIX, who) if who && row.actor_claim.nil?
    updates[:reason] = why if why && row.reason.nil?
    @counts["claims"] += 1 if updates[:actor_claim]
    @counts["reasons"] += 1 if updates[:reason]
    updates
  end

  def new_value(change)
    change.is_a?(Hash) ? (change["to"] || change[:to]) : nil
  end

  def report
    @out.puts(@apply ? "Applied:" : "Dry run (APPLY=1 writes):")
    KIND_ACTORS.each do |kind, actor|
      @out.puts "  #{kind} → #{actor}: #{@counts['change_sets'][kind]} change set(s), #{@counts['audit_logs'][kind]} audit row(s)"
    end
    @out.puts "  observation rows given a claim: #{@counts['claims']}, a reason: #{@counts['reasons']}"
    @out.puts "  Other nil-actor change sets (review.* and the rest) are left: MCP and jobs can't be told apart."
    @out.puts "  Review rows already credited to \"generator\" are not rewritten, for the same reason."
  end
end
