# frozen_string_literal: true

require "rails_helper"

# UI-4a C2: block or queue, never race. An undo and a writer on the same target serialize on the
# membership lock; the undo then succeeds or refuses, never a crash, a partial state or a leaked lock.
RSpec.describe ChangeSetUndo, "concurrency" do
  # Real commits from two connections: no wrapping transaction, explicit cleanup.
  self.use_transactional_tests = false

  let(:tag) { SecureRandom.hex(4) }
  let!(:source) { MemoryEntity.create!(name: "SynthWidget #{tag}", entity_type: "Component", aliases: "Widget") }
  let!(:target) { MemoryEntity.create!(name: "SynthWidget keeper #{tag}", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "SynthWidget beta #{tag}", entity_type: "Component") }
  let!(:observation) { MemoryObservation.create!(memory_entity: source, content: "SynthWidget synthetic fact #{tag}") }
  let!(:uuid) { NodeOperationsStrategy.new.merge_into(source.id, target.id).fetch(:change_set_uuid) }

  around do |example|
    started_at = Time.current
    example.run
  ensure
    MemoryObservation.where(created_at: started_at..).delete_all
    MemoryRelation.where(created_at: started_at..).delete_all
    MemoryEntity.where("name LIKE ?", "SynthWidget %").delete_all
    AuditLog.where(created_at: started_at..).delete_all
    ChangeSet.where(created_at: started_at..).delete_all
  end

  # Holds the membership lock on another connection, runs `write` under it once the undo is
  # waiting, then returns the undo's result.
  def race_undo_against(&write)
    locked = Queue.new
    release = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ProjectMembership.with_membership_lock do
          locked << true
          release.pop
          write.call
        end
      end
    end
    locked.pop
    undo = Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.call(uuid, actor: "operator:test") } }
    expect(undo.join(0.5)).to be_nil # still waiting on the lock
    release << true
    writer.join
    undo.value
  end

  # Pauses the undo inside its lock and transaction (in `method` of ChangeSetUndo::Merge), starts
  # `write` on another connection, checks it waits, then lets both finish.
  def race_writer_against_undo(method, &write)
    paused = Queue.new
    release = Queue.new
    allow_any_instance_of(ChangeSetUndo::Merge).to receive(method).and_wrap_original do |original, *args|
      paused << true
      release.pop
      original.call(*args)
    end
    undo = Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.call(uuid, actor: "operator:test") } }
    paused.pop
    writer = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&write) }
    writer.report_on_exception = false
    expect(writer.join(0.5)).to be_nil # waiting on the undo
    release << true
    [ undo.value, begin
      writer.value
    rescue StandardError => e
      e
    end ]
  end

  it "makes a graph_write part_of create wait on the undo's membership lock, then see the restored source" do
    undo_result, = race_writer_against_undo(:call) do
      GraphWriteService.call(operations: [
        { type: "create_entity", name: "SynthWidget part #{tag}", entity_type: "Component" },
        { type: "create_relation", from_entity: "SynthWidget part #{tag}", to_entity_id: source.id, relation_type: "part_of" }
      ])
    end

    expect(undo_result).to be_ok
    part = MemoryEntity.find_by!(name: "SynthWidget part #{tag}")
    expect(MemoryRelation.where(from_entity_id: part.id, to_entity_id: source.id, relation_type: "part_of")).to exist
    expect(membership_lock_free?).to be(true)
  end

  # graph_edit reads the row before it waits, so once the undo commits MariaDB's snapshot isolation
  # refuses the stale write (ER_CHECKREAD), as it does after any concurrent writer: queued, then
  # refused, never interleaved.
  it "makes a graph_edit (no membership lock) wait on the undo's row locks, then refuses its stale write" do
    undo_result, edit = race_writer_against_undo(:finish) do
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: target.id, description: "edited during the undo" } ])
    end

    expect(undo_result).to be_ok
    expect(edit).to be_a(ActiveRecord::StatementInvalid)
    expect(edit.message).to match(/Record has changed since last read/)
    expect(target.reload).to have_attributes(description: nil, aliases: nil)
    expect(MemoryEntity.exists?(source.id)).to be(true)
    expect(membership_lock_free?).to be(true)
  end

  it "waits for a concurrent alias edit on the target, then undoes the merge and keeps the new alias" do
    result = race_undo_against do
      GraphEditService.call(operations: [ { type: "update_entity", entity_id: target.id, aliases: "#{target.reload.aliases},Later" } ])
    end

    expect(result).to be_ok
    expect(MemoryEntity.find(source.id)).to have_attributes(name: "SynthWidget #{tag}")
    expect(observation.reload.memory_entity_id).to eq(source.id)
    expect(target.reload.aliases).to eq("Later")
    expect(membership_lock_free?).to be(true)
  end

  it "refuses cleanly when the concurrent write moved an observation the merge brought over" do
    result = race_undo_against { observation.reload.update!(memory_entity_id: beta.id) }

    expect(result.status).to eq(:conflict)
    expect(MemoryEntity.find_by(id: source.id)).to be_nil
    expect(ChangeSet.find_by!(uuid: uuid).undone_at).to be_nil
    expect(ChangeSet.where(kind: "undo")).not_to exist
    expect(membership_lock_free?).to be(true)
  end
end
