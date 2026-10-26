# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompactionReviewApplier::Contradiction do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:kept) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget supports dark mode.") }
  let!(:other) { MemoryObservation.create!(memory_entity: beta, content: "SynthWidget does not support dark mode.") }
  let(:effective) { { observation_id_1: other.id, observation_id_2: kept.id }.with_indifferent_access }

  it "refuses a missing or foreign keep_observation_id, writing nothing" do
    [ {}, { keep_observation_id: 999_999 } ].each do |params|
      result = described_class.apply(effective, params)

      low, high = [ kept.id, other.id ].sort
      expect(result).to eq(success: false, error: "Choose which observation to keep (##{low} or ##{high})")
    end
    expect([ kept.reload.status, other.reload.status ]).to eq(%w[active active])
    expect(AuditLog.where(auditable_type: "MemoryObservation", action: "update")).not_to exist
  end

  it "refuses when the kept side is no longer active" do
    kept.mark_obsolete!(reason: "synthetic")

    result = described_class.apply(effective, { "keep_observation_id" => kept.id.to_s })

    expect(result[:error]).to eq("Observation ##{kept.id} is no longer active; dismiss this row or restore it first")
    expect(other.reload.status).to eq("active")
  end

  it "succeeds without a write when the retired side is already inactive" do
    other.mark_obsolete!(reason: "synthetic")

    expect { expect(described_class.apply(effective, { keep_observation_id: kept.id })).to include(success: true) }
      .not_to change { other.reload.updated_at }
  end

  it "marks only the other side obsolete and leaves the kept one untouched" do
    result = described_class.apply(effective, ActionController::Parameters.new(keep_observation_id: kept.id.to_s))

    expect(result).to eq(success: true, message: "Kept observation ##{kept.id}; marked ##{other.id} obsolete")
    expect(other.reload).to have_attributes(status: "obsolete", obsolescence_reason: "Contradicted by observation ##{kept.id} (contradiction review)")
    expect(kept.reload).to have_attributes(status: "active", obsoleted_at: nil)
  end
end
