# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeSetUndo::Merge do
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:source) do
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", aliases: "Widget", description: "synthetic")
  end
  let!(:target) { MemoryEntity.create!(name: "Synth Widget", entity_type: "Component", aliases: "SW") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:child) { MemoryEntity.create!(name: "SynthWidget Part", entity_type: "Component") }
  let!(:observation) { MemoryObservation.create!(memory_entity: source, content: "SynthWidget renders synthetic tiles.") }
  let!(:project_edge) { MemoryRelation.create!(from_entity: source, to_entity: project, relation_type: "part_of") }
  let!(:duplicate_edge) { MemoryRelation.create!(from_entity: source, to_entity: beta, relation_type: "depends_on") }
  let!(:target_edge) { MemoryRelation.create!(from_entity: target, to_entity: beta, relation_type: "depends_on") }
  let!(:child_edge) { MemoryRelation.create!(from_entity: child, to_entity: source, relation_type: "part_of") }
  let(:vector) { Array.new(768) { |i| Math.sin(i + 0.123456789) } }

  before do
    ProjectMembership.sync!(source)
    conn = MemoryEntity.connection
    conn.update("UPDATE memory_entities SET embedding = VEC_FromText(#{conn.quote("[#{vector.join(',')}]")}), " \
                "embedded_at = '2026-10-20 08:00:00.123456' WHERE id = #{source.id}")
  end

  def state
    {
      entities: MemoryEntity.order(:id).pluck(:id, :name, :aliases, :project_id, :memory_observations_count),
      source_vector: MemoryEntity.where(id: source.id).pick(Arel.sql("HEX(embedding)")),
      source_times: MemoryEntity.where(id: source.id).pick(:embedded_at, :created_at),
      observations: MemoryObservation.order(:id).pluck(:id, :memory_entity_id),
      relations: MemoryRelation.order(:id).pluck(:id, :from_entity_id, :to_entity_id, :relation_type)
    }
  end

  def merge!(from = source, into = target)
    NodeOperationsStrategy.new.merge_into(from.id, into.id).fetch(:change_set_uuid)
  end

  def undo(uuid)
    ChangeSetUndo.call(uuid, actor: "operator:steve@127.0.0.1")
  end

  it "restores ids, names, aliases, owners, edges, project scope and the source's vector bytes", :with_test_embeddings do
    before_state = state
    uuid = merge!
    expect(MemoryEntity.find_by(id: source.id)).to be_nil

    allow(EmbeddingService.instance).to receive(:embed).and_return(vector)
    result = undo(uuid)

    expect(result).to be_ok
    expect(result.change_set).to have_attributes(kind: "undo", undo_strategy: "merge")
    expect(state.except(:entities)).to eq(before_state.except(:entities))
    expect(state[:entities].map { |row| row.first(4) }).to eq(before_state[:entities].map { |row| row.first(4) })
    expect(source.reload.memory_observations_count).to eq(1)
    expect(target.reload.embedded_at).to be_present # NULLed by the alias change, then re-embedded after the lock
  end

  it "keeps aliases added to the target since the merge" do
    uuid = merge!
    target.reload.update!(aliases: "#{target.aliases},Later Alias")

    expect(undo(uuid)).to be_ok
    expect(target.reload.aliases).to eq("SW,Later Alias")
  end

  describe "refusals (all-or-nothing)" do
    it "refuses when the source's name is taken again in its scope" do
      uuid = merge!
      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id)

      result = undo(uuid)
      expect(result.status).to eq(:conflict)
      expect(result.conflicts).to include("Can't undo: an entity named 'SynthWidget' exists again in its scope")
      expect(ChangeSet.find_by!(uuid: uuid).undone_at).to be_nil
    end

    it "refuses when a moved observation or a moved child changed since" do
      uuid = merge!
      observation.reload.update!(memory_entity_id: beta.id)
      MemoryRelation.find(child_edge.id).update!(to_entity_id: beta.id)

      result = undo(uuid)
      expect(result.conflicts).to include("Can't undo: 1 observation(s) moved or deleted since the merge",
                                          "Can't undo: relation ##{child_edge.id} (part_of) was moved since the merge")
      expect(MemoryEntity.find_by(id: source.id)).to be_nil
    end

    it "refuses when a later merge removed the target, naming that change" do
      first = merge!
      second = merge!(target, beta)

      result = undo(first)
      expect(result.conflicts.first).to eq(
        "Can't undo: the merge target ##{target.id} was removed by change #{second} (merge); undo #{second} first"
      )
    end

    it "refuses when the source's id is taken" do
      uuid = merge!
      MemoryEntity.create!(id: source.id, name: "Beta Gadget", entity_type: "Component")

      expect(undo(uuid).conflicts).to include("Can't undo: an entity with id #{source.id} exists again")
    end

    it "refuses after the 7-day window" do
      uuid = merge!
      expect(ChangeSet.find_by!(uuid: uuid).undoable_until).to be_within(1.minute).of(7.days.from_now)
      ChangeSet.find_by!(uuid: uuid).update!(undoable_until: 1.second.ago)

      expect(undo(uuid)).to have_attributes(status: :not_undoable)
    end
  end

  # graph_delete refuses to touch one entity twice per batch, so open the set by hand: two merges
  # recorded in one change set, the shape a policy run or a bulk action produces.
  describe "a set with several merges (A -> B, then B -> C)" do
    let!(:gadget) { MemoryEntity.create!(name: "SynthGadget", entity_type: "Component") }
    let!(:gadget_fact) { MemoryObservation.create!(memory_entity: gadget, content: "SynthGadget is synthetic.") }

    def batch!
      ChangeSet.record(kind: "review.bulk_apply") do |context|
        NodeOperationsStrategy.new.merge_into(gadget.id, source.id)
        NodeOperationsStrategy.new.merge_into(source.id, target.id)
        expect(ChangeSet.find(context.id).section(:merges).map { |step| step.dig("source", "id") }).to eq([ gadget.id, source.id ])
        context.uuid
      end
    end

    it "undoes the steps newest first and restores both sources" do
      uuid = batch!
      expect(MemoryEntity.where(id: [ gadget.id, source.id ])).to be_empty

      expect(undo(uuid)).to be_ok
      expect(gadget_fact.reload.memory_entity_id).to eq(gadget.id)
      expect(observation.reload.memory_entity_id).to eq(source.id)
      expect(MemoryEntity.find(source.id).aliases).to eq("Widget")
      expect(target.reload.aliases).to eq("SW")
    end

    it "lists the refusals of every step at once" do
      uuid = batch!
      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: project.id)
      MemoryEntity.create!(name: "SynthGadget", entity_type: "Component")

      conflicts = undo(uuid).conflicts
      expect(conflicts).to include("Can't undo: an entity named 'SynthWidget' exists again in its scope",
                                   "Can't undo: an entity named 'SynthGadget' exists again in its scope")
      expect(conflicts).to include(a_string_matching(/merged away later in this change/))
    end
  end

  it "answers a validation failure as a conflict with its reason, not an error" do
    uuid = merge!
    invalid = MemoryRelation.new.tap { |relation| relation.errors.add(:base, "synthetic semantics failure") }
    allow(MemoryRelation).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

    result = undo(uuid)

    expect(result.status).to eq(:conflict)
    expect(result.conflicts.sole).to include("synthetic semantics failure")
    expect(MemoryEntity.find_by(id: source.id)).to be_nil
  end

  it "refuses a destroyed part_of edge that would now close a cycle, with the friendly reason" do
    uuid = merge!
    allow(RelationSemantics).to receive(:would_create_cycle?).and_return(true)

    expect(undo(uuid).conflicts).to eq([ "Can't undo: restoring the part_of edges would create a cycle" ])
  end

  it "skips (and reports) a destroyed relation whose id is taken again" do
    uuid = merge!
    MemoryRelation.create!(id: duplicate_edge.id, from_entity: beta, to_entity: child, relation_type: "depends_on")

    result = undo(uuid)
    expect(result).to be_ok
    expect(result.message).to include("skipped: relation ##{duplicate_edge.id} (depends_on) exists again")
    expect(MemoryRelation.find(duplicate_edge.id).from_entity_id).to eq(beta.id)
  end

  it "redoes by undoing the undo, and the redo is undoable again" do
    before_state = state
    uuid = merge!
    undo_set = undo(uuid).change_set

    redo_result = undo(undo_set.uuid)
    expect(redo_result).to be_ok
    expect(redo_result.change_set).to have_attributes(kind: "redo", undo_strategy: "merge")
    expect(MemoryEntity.find_by(id: source.id)).to be_nil
    expect(observation.reload.memory_entity_id).to eq(target.id)
    expect(redo_result.change_set.section(:merges).size).to eq(1)

    expect(undo(redo_result.change_set.uuid)).to be_ok
    expect(state.except(:entities)).to eq(before_state.except(:entities))
  end
end
