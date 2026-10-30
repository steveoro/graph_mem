# frozen_string_literal: true

require "rails_helper"
require "rake"

# Audit actor (1.65.0, B6): rake audit:backfill_actors fills the actor of pre-1.65.0 MCP writes.
# Dry run by default; with APPLY=1 only nil actors of graph.* sets and their rows, no callbacks,
# idempotent. Synthetic rows only.
RSpec.describe "audit:backfill_actors", type: :task do
  before do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?("environment")
    Rake::Task["audit:backfill_actors"].clear if Rake::Task.task_defined?("audit:backfill_actors")
    load Rails.root.join("lib/tasks/audit.rake")
  end

  after do
    Rake::Task["audit:backfill_actors"].reenable
    ENV.delete("APPLY")
  end

  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  # A pre-1.65.0 MCP write: no actor, no claim and no reason (only deletes had one), as the old
  # code wrote it.
  def old_write(kind = "graph.write")
    context = Current.set(actor: nil) do
      ChangeSet.record(kind: kind) do |change_set|
        observation = MemoryObservation.create!(memory_entity: widget, content: "SynthWidget note #{SecureRandom.hex(3)}",
                                                source: "synth-agent/model-x: synthetic task")
        observation.mark_obsolete!(reason: "superseded by a synthetic fact") if kind == "graph.delete"
        change_set
      end
    end
    AuditLog.where(change_set_id: context.id).update_all(reason: nil, actor_claim: nil)
    context
  end

  def run(apply: false)
    ENV["APPLY"] = "1" if apply
    expect { Rake::Task["audit:backfill_actors"].invoke }.to output(/#{apply ? 'Applied' : 'Dry run'}/).to_stdout
    Rake::Task["audit:backfill_actors"].reenable
  end

  def set_for(context) = ChangeSet.find_by!(uuid: context.uuid)

  it "writes nothing without APPLY=1" do
    context = old_write

    expect { run }.not_to(change { [ set_for(context).actor, AuditLog.where.not(actor: nil).count ] })
  end

  it "fills graph.* sets and their rows, with the source's claim and reason, and leaves everything else" do
    write = old_write
    delete = old_write("graph.delete")
    review = Current.set(actor: nil) { ChangeSet.record(kind: "review.apply") { |context| MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") && context } }
    operator = Current.set(actor: "operator:synth@127.0.0.1") { ChangeSet.record(kind: "graph.write") { |context| widget.update!(description: "synthetic") && context } }

    expect { run(apply: true) }.not_to change(AuditLog, :count)

    expect(set_for(write).actor).to eq("mcp:graph_write")
    created = set_for(write).audit_logs.find_by!(auditable_type: "MemoryObservation", action: "create")
    expect(created).to have_attributes(actor: "mcp:graph_write", actor_claim: "backfilled · synth-agent/model-x", reason: "synthetic task")
    retired = set_for(delete).audit_logs.find_by!(action: "update")
    expect(retired).to have_attributes(actor: "mcp:graph_delete", reason: "superseded by a synthetic fact", actor_claim: nil)
    expect(set_for(review).actor).to be_nil
    expect(set_for(review).audit_logs.pluck(:actor)).to all(be_nil)
    expect(set_for(operator).audit_logs.pluck(:actor)).to all(eq("operator:synth@127.0.0.1"))
  end

  it "changes nothing on a second run" do
    old_write
    run(apply: true)
    snapshot = -> { [ ChangeSet.pluck(:id, :actor), AuditLog.pluck(:id, :actor, :actor_claim, :reason) ] }

    expect { run(apply: true) }.not_to(change { snapshot.call })
    expect(AuditActorBackfill.new(apply: true, out: StringIO.new).call["audit_logs"].values.sum).to eq(0)
  end
end
