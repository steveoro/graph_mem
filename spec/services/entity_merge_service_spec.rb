# frozen_string_literal: true

require "rails_helper"

RSpec.describe EntityMergeService do
  let!(:source) { MemoryEntity.create!(name: "SynthWidget A", entity_type: "Component") }
  let!(:target) { MemoryEntity.create!(name: "SynthWidget B", entity_type: "Component") }
  let(:actor) { "operator:synth@127.0.0.1" }

  before { MemoryObservation.create!(memory_entity: source, content: "SynthWidget A renders tiles.") }

  def digest = EntityMergePreview.new(source.id, target.id).call.digest

  it "merges in an explore.merge change set with the actor and an undo handle" do
    result = described_class.call(source_id: source.id, target_id: target.id, digest: digest, actor: actor)

    expect(result).to include(success: true, status: :ok, undoable: true)
    expect(ChangeSet.find_by(uuid: result[:change_set_uuid])).to have_attributes(kind: "explore.merge", actor: actor, undo_strategy: "merge")
  end

  it "refuses with :conflict and writes nothing when something changed between preview and merge" do
    seen = digest
    MemoryObservation.create!(memory_entity: source, content: "SynthWidget A added after the preview.")

    expect do
      result = described_class.call(source_id: source.id, target_id: target.id, digest: seen, actor: actor)
      expect(result).to eq(success: false, status: :conflict, error: described_class::CONFLICT_MESSAGE)
    end.not_to change { [ MemoryEntity.count, MemoryObservation.where(memory_entity_id: target.id).count, ChangeSet.count, AuditLog.count ] }
  end
end
