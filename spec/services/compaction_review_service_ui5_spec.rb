# frozen_string_literal: true

require "rails_helper"

# UI-5a additions to the review queue service (classification, limits, undo links, snooze,
# contradiction rows). The existing behaviour stays pinned by compaction_review_service_spec.rb.
RSpec.describe CompactionReviewService, "UI-5a" do
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }

  def proposal(from, to, type: "depends_on", band: "high", score: 12)
    { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: from.id, to_entity_id: to.id,
      relation_type: type, confidence_band: band, score: score }
  end

  def seed(items, source_ref: nil)
    described_class.seed_report(report_type: "compaction_review", source: "test", source_ref: source_ref, items: items)
  end

  describe "classification at seed time" do
    it "writes the group key, anchor, project, confidence and priority" do
      MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of")
      ProjectMembership.sync!(widget)

      row = seed([ proposal(widget, beta) ]).sole

      expected = ReviewRowClassifier.call(kind: row.kind, payload: row.payload, row_uuid: row.row_uuid)
      expect(row.reload).to have_attributes(group_key: expected[:group_key], anchor_entity_id: [ widget.id, beta.id ].min,
                                            confidence: expected[:confidence], priority: expected[:priority])
      expect(row.project_id).to eq(widget.id < beta.id ? project.id : nil)
    end
  end

  describe "symmetric dedupe" do
    it "seeds A→B and B→A relates_to once, and a dismissal blocks both directions" do
      first = seed([ proposal(widget, beta, type: "relates_to") ])
      second = seed([ proposal(beta, widget, type: "relates_to") ])

      expect(first.size).to eq(1)
      expect(second).to be_empty

      described_class.dismiss(first.sole.row_uuid, reason: "not related")
      expect(described_class.suppressed?("relationship_proposal",
                                         { from_entity_id: beta.id, to_entity_id: widget.id, relation_type: "relates_to" })).to be(true)
    end

    it "keeps directed relation types apart" do
      expect(seed([ proposal(widget, beta), proposal(beta, widget) ]).size).to eq(2)
    end
  end
end
