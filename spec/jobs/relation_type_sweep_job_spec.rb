# frozen_string_literal: true

require "rails_helper"

RSpec.describe RelationTypeSweepJob, type: :job do
  let(:suffix) { SecureRandom.hex(3) }

  def stored_relation(stored_type)
    from = MemoryEntity.create!(name: "SynthService #{suffix} #{stored_type}", entity_type: "Service")
    to = MemoryEntity.create!(name: "SynthWidget #{suffix} #{stored_type}", entity_type: "Component")
    relation = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "synth_placeholder_#{SecureRandom.hex(4)}")
    relation.update_column(:relation_type, stored_type)
    relation
  end

  it "sweeps every relation with an OperationProgress, as the given actor" do
    variant = stored_relation("requires")
    stored_relation("depends_on")

    summary = described_class.new.perform(actor: "operator:synth@127.0.0.1")

    expect(variant.reload.relation_type).to eq("depends_on")
    progress = OperationProgress.where(operation_type: "relation_type_sweep").sole
    expect(progress).to have_attributes(status: "completed", current_count: 2, total_count: 2)
    expect(progress.message).to eq("1 retyped, 0 merged, 0 queued for review, of 2 relation(s)")
    expect(progress.details).to include("report_id" => summary[:report_id])
    expect(MaintenanceReport.find(summary[:report_id]).data).to include("source" => "operator", "actor" => "operator:synth@127.0.0.1")
    expect(ChangeSet.find_by!(kind: "dream.relation_types").actor).to eq("operator:synth@127.0.0.1")
  end

  it "marks the progress failed and re-raises when the sweep fails" do
    allow(RelationTypeSweep).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "synth failure")

    expect { described_class.new.perform }.to raise_error(ActiveRecord::StatementInvalid)
    expect(OperationProgress.where(operation_type: "relation_type_sweep").sole.status).to eq("failed")
  end
end
