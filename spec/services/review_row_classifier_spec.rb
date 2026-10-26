# frozen_string_literal: true

require "rails_helper"

RSpec.describe ReviewRowClassifier do
  include ActiveSupport::Testing::TimeHelpers

  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:fact) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.") }
  let!(:relation) { MemoryRelation.create!(from_entity: beta, to_entity: widget, relation_type: "depends_on") }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of")
    ProjectMembership.sync!(widget)
  end

  def classify(kind, payload, created_at: nil)
    described_class.call(kind: kind, payload: payload, created_at: created_at, row_uuid: "row-1")
  end

  # Each generator's real payload shape (see the seed sites), and the §2.5.1 confidence/impact.
  describe "the per-kind table" do
    {
      "relationship_proposal (discovery, high band)" => [
        "relationship_proposal", ->(w, b) { { from_entity_id: w.id, to_entity_id: b.id, relation_type: "depends_on", confidence_band: "high", score: 14 } },
        ->(w, b) { "relationship_proposal|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.9
      ],
      "relationship_proposal (graphify, low band, score = confidence x 10)" => [
        "relationship_proposal", ->(w, b) { { from_entity_id: w.id, to_entity_id: b.id, relation_type: "depends_on", confidence_band: "low", score: 4 } },
        ->(w, b) { "relationship_proposal|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.25
      ],
      "entity_merge (compaction: score + distance)" => [
        "entity_merge", ->(w, b) { { entity_a: { entity_id: b.id }, entity_b: { entity_id: w.id }, cosine_distance: 0.1, score: 12 } },
        ->(w, b) { "entity_merge|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.45
      ],
      "entity_merge (suggest_merges: distance only)" => [
        "entity_merge", ->(w, b) { { entity_a: { entity_id: w.id }, entity_b: { entity_id: b.id }, cosine_distance: 0.2 } },
        ->(w, b) { "entity_merge|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.8
      ],
      "orphan_parent (top score / AUTO_PARENT_SCORE)" => [
        "orphan_parent", ->(w, _b) { { entity_id: w.id, suggested_parents: [ { project_id: 1, score: 5 }, { project_id: 2, score: 3 } ] } },
        ->(w, _b) { "orphan_parent|#{w.id}" }, 0.5
      ],
      "stale_memory (valid_until_elapsed)" => [
        "stale_memory", ->(w, _b) { { entity_id: w.id, observation_ids: [ 1, 2 ], signal: "valid_until_elapsed" } },
        ->(w, _b) { "stale_memory|#{w.id}" }, 0.95
      ],
      "entity_error" => [ "entity_error", ->(w, _b) { { entity_id: w.id, phase: "merge" } }, ->(w, _b) { "entity_error|#{w.id}" }, 1.0 ],
      "embedding_backfill_failed" => [
        "embedding_backfill_failed", ->(w, _b) { { entity_id: w.id, entity_name: "SynthWidget" } }, ->(w, _b) { "embedding_backfill_failed|#{w.id}" }, 1.0
      ],
      "lifecycle_corruption" => [
        "lifecycle_corruption", ->(w, _b) { { observation_id: 9, entity_id: w.id } }, ->(w, _b) { "lifecycle_corruption|#{w.id}" }, 1.0
      ],
      "relation_integrity (same_direction, nested payload)" => [
        "relation_integrity", ->(w, b) { { issue_kind: "same_direction", payload: { from_entity_id: b.id, to_entity_id: w.id, keep_id: 1, delete_ids: [ 2 ] } } },
        ->(w, b) { "relation_integrity|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.9
      ],
      "relation_integrity (reverse_pair: the kept edge)" => [
        "relation_integrity", ->(w, b) { { issue_kind: "reverse_pair", payload: { keep_id: 1, delete_id: 2, keep: { from_entity_id: w.id, to_entity_id: b.id } } } },
        ->(w, b) { "relation_integrity|#{[ w.id, b.id ].min}-#{[ w.id, b.id ].max}" }, 0.9
      ],
      "relation_integrity (merge_collision: the child)" => [
        "relation_integrity", ->(w, b) { { issue_kind: "merge_collision", payload: { child_entity_id: w.id, parent_entity_ids: [ b.id, 99 ] } } },
        ->(w, _b) { "relation_integrity|#{w.id}" }, 0.9
      ],
      "delete_entity (scan)" => [ "delete_entity", ->(w, _b) { { entity_id: w.id, reason: "gone" } }, ->(w, _b) { "delete_entity|#{w.id}" }, 0.7 ],
      "reparent_entity (rescan)" => [
        "reparent_entity", ->(w, b) { { entity_id: w.id, parent_id: b.id } }, ->(w, _b) { "reparent_entity|#{w.id}" }, 0.7
      ]
    }.each do |label, (kind, payload, group_key, confidence)|
      it "classifies #{label}" do
        result = classify(kind, payload.call(widget, beta))

        expect(result[:group_key]).to eq(group_key.call(widget, beta))
        expect(result[:confidence]).to be_within(0.001).of(confidence)
        expect(result[:priority]).to be_between(0, 100)
      end
    end

    it "keys observation kinds by the observation's owner and relation deletes by the endpoints" do
      expect(classify("delete_observation", { observation_id: fact.id })).to include(group_key: "delete_observation|obs:#{widget.id}",
                                                                                     anchor_entity_id: widget.id)
      expect(classify("move_observation", { observation_id: fact.id, target_entity_id: beta.id })[:group_key])
        .to eq("move_observation|obs:#{widget.id}")
      expect(classify("delete_relation", { relation_id: relation.id })[:group_key])
        .to eq("delete_relation|#{[ widget.id, beta.id ].min}-#{[ widget.id, beta.id ].max}")
      expect(classify("delete_relation", { relation_id: -1 })).to include(group_key: "delete_relation|row:row-1", anchor_entity_id: nil)
      expect(classify("dismiss_compaction_review", { review_item_id: "abc" })[:group_key]).to eq("dismiss_compaction_review|abc")
      expect(classify("something_new", {})[:group_key]).to eq("something_new|row:row-1")
    end

    it "keys a contradiction over the owner entities, with the detector's confidence" do
      result = classify("contradiction", { observation_id_1: 1, observation_id_2: 2, entity_id_1: beta.id, entity_id_2: widget.id,
                                           confidence: 0.83 })

      expect(result).to include(group_key: "contradiction|#{[ widget.id, beta.id ].min}-#{[ widget.id, beta.id ].max}",
                                confidence: 0.83)
      expect(classify("contradiction", { entity_id_1: widget.id, entity_id_2: widget.id, confidence: 0.7 })[:group_key])
        .to eq("contradiction|#{widget.id}")
    end
  end

  it "gives both directions of a pair the same group key" do
    forward = classify("relationship_proposal", { from_entity_id: widget.id, to_entity_id: beta.id, relation_type: "relates_to" })
    backward = classify("relationship_proposal", { from_entity_id: beta.id, to_entity_id: widget.id, relation_type: "relates_to" })

    expect(forward[:group_key]).to eq(backward[:group_key])
  end

  it "takes the project from the anchor (NULL for a global anchor)" do
    expect(classify("orphan_parent", { entity_id: widget.id })[:project_id]).to eq(project.id)
    expect(classify("orphan_parent", { entity_id: beta.id })[:project_id]).to be_nil
  end

  it "computes priority = 100 × (0.6 impact + 0.4 confidence) × age boost, with the root and degree bumps" do
    payload = { entity_id: beta.id, reason: "gone" }
    expect(classify("delete_entity", payload)[:priority]).to eq((100 * ((0.6 * 0.6) + (0.4 * 0.7))).round)
    expect(classify("delete_entity", payload, created_at: 14.days.ago)[:priority]).to eq((100 * ((0.6 * 0.6) + (0.4 * 0.7)) * 1.5).round.clamp(0, 100))
    expect(classify("delete_entity", { entity_id: project.id })[:priority]).to eq((100 * ((0.6 * 0.7) + (0.4 * 0.7))).round)

    21.times { |i| MemoryRelation.create!(from_entity: MemoryEntity.create!(name: "SynthGadget #{i}", entity_type: "Component"), to_entity: beta, relation_type: "depends_on") }
    expect(classify("delete_entity", payload)[:priority]).to eq((100 * ((0.6 * 0.6) + (0.4 * 0.7))).round + described_class::DEGREE_BUMP)
  end

  it "keeps error rows at or above the attention floor" do
    low = classify("entity_error", { entity_id: nil })

    expect(low[:priority]).to be >= described_class::ATTENTION_FLOOR_ERRORS
  end

  it "keeps the kind lists disjoint where they must be" do
    expect(described_class::SAFE_BULK_KINDS & described_class::DESTRUCTIVE_KINDS).to be_empty
    expect(described_class::SAFE_BULK_KINDS & described_class::CHOICE_KINDS).to be_empty
    expect(described_class::RUN_CAPS).to eq("relationship_proposal" => 200, "entity_merge" => 100, "orphan_parent" => 100, "contradiction" => 100)
  end

  describe ".backfill!" do
    def row(kind:, payload:, signature:, status: "active", **attrs)
      MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: SecureRandom.uuid, kind: kind,
                                   signature: signature, payload: payload, status: status, **attrs)
    end

    it "classifies unclassified rows, is idempotent and resumable with a limit" do
      rows = Array.new(3) { |i| row(kind: "orphan_parent", payload: { "entity_id" => widget.id }, signature: "orphan_parent|#{i}") }

      expect(described_class.backfill!(batch_size: 2, limit: 2)[:classified]).to eq(2)
      expect(MaintenanceReportRow.where(group_key: nil).count).to eq(1)
      expect(described_class.backfill!(batch_size: 2)[:classified]).to eq(1)
      expect(described_class.backfill![:classified]).to eq(0)
      expect(rows.map { |r| r.reload.group_key }.uniq).to eq([ "orphan_parent|#{widget.id}" ])
    end

    it "rewrites symmetric signatures: the older row stays, the newer is dismissed as its duplicate" do
      payload = ->(from, to) { { "from_entity_id" => from, "to_entity_id" => to, "relation_type" => "relates_to" } }
      low, high = [ widget.id, beta.id ].sort
      older = row(kind: "relationship_proposal", payload: payload.call(high, low), signature: "relationship_proposal|#{high}|#{low}|relates_to")
      newer = row(kind: "relationship_proposal", payload: payload.call(low, high), signature: "relationship_proposal|#{low}|#{high}|relates_to")

      counts = described_class.backfill!

      expect(counts[:duplicates]).to eq(1)
      expect(older.reload).to have_attributes(status: "active", signature: "relationship_proposal|#{low}|#{high}|relates_to")
      expect(newer.reload).to have_attributes(status: "dismissed", resolved_by: "generator", resolution_reason: "duplicate of ##{older.id}")
      expect(described_class.backfill![:duplicates]).to eq(0)
    end

    it "leaves directed proposals alone, whatever their stored signature" do
      directed = row(kind: "relationship_proposal", signature: "relationship_proposal|legacy",
                     payload: { "from_entity_id" => widget.id, "to_entity_id" => beta.id, "relation_type" => "depends_on" })

      expect(described_class.backfill!).to include(rewritten: 0, duplicates: 0)
      expect(directed.reload).to have_attributes(signature: "relationship_proposal|legacy", status: "active")
    end

    it "twins an old unordered symmetric suppression so it still blocks the other direction" do
      low, high = [ widget.id, beta.id ].sort
      MaintenanceReportSuppression.create!(report_type: "compaction_review", signature: "relationship_proposal|#{high}|#{low}|relates_to",
                                           kind: "relationship_proposal", reason: "not related", source: "dismissed")

      expect(described_class.backfill![:twins]).to eq(1)
      twin = MaintenanceReportSuppression.find_by!(signature: "relationship_proposal|#{low}|#{high}|relates_to")
      expect(twin).to have_attributes(reason: "not related", source: "dismissed")
      expect(CompactionReviewService.suppressed?("relationship_proposal",
                                                 { from_entity_id: low, to_entity_id: high, relation_type: "relates_to" })).to be(true)
      expect(described_class.backfill![:twins]).to eq(0)
    end
  end
end
