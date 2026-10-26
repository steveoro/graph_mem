# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeSetUndo::AuditInverse do
  include ActiveSupport::Testing::TimeHelpers

  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", description: "original") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  around do |example|
    Current.actor = "mcp:synthetic"
    example.run
  ensure
    Current.reset
  end

  def recorded(kind = "graph.write")
    ChangeSet.record(kind: kind) do |context|
      yield
      context.uuid
    end
  end

  def undo(uuid)
    ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")
  end

  it "destroys what a graph_write created, newest first" do
    uuid = recorded do
      GraphWriteService.call(operations: [
        { type: "create_entity", name: "SynthGadget", entity_type: "Component" },
        { type: "create_observation", entity_name: "SynthGadget", text_content: "synthetic gadget fact" },
        { type: "create_relation", from_entity: "SynthGadget", to_entity: "SynthWidget", relation_type: "depends_on" }
      ])
    end

    result = undo(uuid)

    expect(result).to be_ok
    expect(MemoryEntity.where(name: "SynthGadget")).not_to exist
    expect(MemoryObservation.where(content: "synthetic gadget fact")).not_to exist
    expect(ChangeSet.find_by!(uuid: uuid)).to have_attributes(undone_by: "operator:steve@127.0.0.1")
    expect(result.change_set).to have_attributes(kind: "undo", undo_of_id: ChangeSet.find_by!(uuid: uuid).id)
    # Destroying an entity is a hard delete: this undo itself can't be undone.
    expect(result.change_set.not_undoable_reason).to eq("hard_delete")
  end

  it "restores the from values of an update and recounts nothing it shouldn't" do
    uuid = recorded("graph.edit") do
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "edited", aliases: "Widget" } ])
    end

    expect(undo(uuid)).to be_ok
    expect(widget.reload).to have_attributes(description: "original", aliases: nil, embedded_at: nil)
  end

  it "turns an obsolete mark back into an active observation with obsoleted_at cleared" do
    observation = MemoryObservation.create!(memory_entity: widget, content: "synthetic fact to retire")
    uuid = recorded("graph.delete") do
      GraphDeleteService.call(operations: [ { type: "delete_observation", observation_id: observation.id } ])
    end
    expect(observation.reload.status).to eq("obsolete")

    expect(undo(uuid)).to be_ok
    expect(observation.reload).to have_attributes(status: "active", obsoleted_at: nil, obsolescence_reason: nil)
  end

  it "re-inserts a deleted relation with its original id and re-syncs part_of membership" do
    relation = MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    ProjectMembership.sync!(widget)
    expect(widget.reload.project_id).to eq(alpha.id)
    uuid = recorded("graph.delete") { GraphDeleteService.call(operations: [ { type: "delete_relation", relation_id: relation.id } ]) }
    expect(widget.reload.project_id).to be_nil

    expect(undo(uuid)).to be_ok
    restored = MemoryRelation.find(relation.id)
    expect(restored).to have_attributes(from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "part_of")
    expect(restored.created_at).to be_within(0.001).of(relation.created_at)
    expect(widget.reload.project_id).to eq(alpha.id)
  end

  it "refuses when a record changed since, naming the actor and the time, and changes nothing" do
    uuid = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "edited" } ]) }
    travel_to(Time.utc(2026, 10, 26, 9, 30)) do
      Current.actor = "mcp:graph_edit"
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "edited again" } ])
    end

    result = undo(uuid)

    expect(result.status).to eq(:conflict)
    expect(result.conflicts).to eq([ "Can't undo: MemoryEntity 'SynthWidget' changed since (by mcp:graph_edit at 2026-10-26 10:30 CET)" ])
    expect(widget.reload.description).to eq("edited again")
    expect(ChangeSet.find_by!(uuid: uuid).undone_at).to be_nil
    expect(ChangeSet.where(kind: "undo")).not_to exist
  end

  it "refuses a set with a hard delete, an undone set and a set past its window" do
    hard = recorded("graph.delete") { GraphDeleteService.call(operations: [ { type: "delete_entity", entity_id: beta.id } ]) }
    expect(undo(hard)).to have_attributes(status: :not_undoable, message: "Not undoable: hard_delete")

    edit = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "x" } ]) }
    expect(undo(edit)).to be_ok
    expect(undo(edit).message).to start_with("Already undone")

    late = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "y" } ]) }
    travel_to(31.days.from_now) do
      expect(undo(late)).to have_attributes(status: :not_undoable)
      expect(undo(late).message).to start_with("The undo window passed on")
    end
    expect(undo("no-such-uuid").status).to eq(:not_found)
  end

  it "redoes an undone update by undoing the undo, and the redo is undoable again" do
    uuid = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "edited" } ]) }
    undo_set = undo(uuid).change_set
    expect(widget.reload.description).to eq("original")

    redo_result = undo(undo_set.uuid)
    expect(redo_result).to be_ok
    expect(redo_result.change_set).to have_attributes(kind: "redo", undo_strategy: "audit")
    expect(widget.reload.description).to eq("edited")
    expect(ChangeSet.find_by!(uuid: uuid).undone_at).to be_present

    expect(undo(redo_result.change_set.uuid)).to be_ok
    expect(widget.reload.description).to eq("original")
  end

  it "answers a deadlock or a lock-wait timeout as busy" do
    uuid = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, description: "x" } ]) }
    [ ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout ].each do |error|
      allow(ChangeSet).to receive(:lock).and_raise(error, "synthetic")
      expect(undo(uuid)).to have_attributes(status: :busy, message: "Busy, retry shortly")
    end
  end

  it "re-embeds the restored text after the lock (best effort)" do
    uuid = recorded("graph.edit") { GraphEditService.call(operations: [ { type: "update_entity", entity_id: widget.id, name: "SynthWidget 2" } ]) }
    allow(EmbeddingService).to receive(:embed_entity)

    expect(undo(uuid)).to be_ok
    expect(EmbeddingService).to have_received(:embed_entity).with(have_attributes(id: widget.id, name: "SynthWidget"))
  end
end
