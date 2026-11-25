# frozen_string_literal: true

require "rails_helper"

# The trust-score recompute both imports share (and the relation hook): the active facts of the
# given entities, plus the listed facts of any status, written without touching updated_at.
RSpec.describe ObservationTrustRecompute do
  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component") }

  it "rewrites the entities' active facts and the listed ones of any status, leaving updated_at alone" do
    active = fs_observe!(widget, "SynthWidget renders tiles.", confidence: 0.9)
    retired = fs_observe!(widget, "SynthWidget used the old renderer.")
    active.update_columns(trust_score: 0)
    retired.update_columns(status: "obsolete", obsoleted_at: Time.current, trust_score: 0.7)
    stamps = [ active, retired ].map { |observation| observation.reload.updated_at }

    expect(described_class.call(entity_ids: [ widget.id ])).to eq(1)
    expect(retired.reload.trust_score).to eq(0.7)
    expect(described_class.call(entity_ids: [ widget.id ], observation_ids: [ retired.id, active.id ])).to eq(2)

    expect(active.reload.trust_score).to eq(ObservationTrustRanker.rank(active)).and be_positive
    expect(retired.reload.trust_score).to eq(ObservationTrustRanker.rank(retired)).and be < 0.7
    expect([ active, retired ].map(&:updated_at)).to eq(stamps)
  end
end
