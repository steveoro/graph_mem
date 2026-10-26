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

  describe "limits at the source" do
    def entities(count)
      Array.new(count) { |i| MemoryEntity.create!(name: "SynthGadget #{i}", entity_type: "Component") }
    end

    it "caps a kind per run across several flushes with one source_ref, keeping the best by priority" do
      stub_const("ReviewRowClassifier::RUN_CAPS", ReviewRowClassifier::RUN_CAPS.merge("relationship_proposal" => 3))
      targets = entities(5)

      first = seed([ proposal(widget, targets[0], band: "low"), proposal(widget, targets[1], band: "high") ], source_ref: 42)
      second = seed(targets[2..].map { |target| proposal(widget, target, band: "medium") }, source_ref: 42)
      other_run = seed([ proposal(beta, targets[0]) ], source_ref: 43)

      expect(first.size).to eq(2)
      expect(second.size).to eq(1)
      expect(MaintenanceReport.find(second.first.maintenance_report_id).data["skipped_run_cap"]).to eq("relationship_proposal" => 2)
      expect(other_run.size).to eq(1)
    end

    it "keeps only items that beat the lowest active priority once the backlog is full" do
      allow(AppSettings).to receive(:review_number).and_call_original
      allow(AppSettings).to receive(:review_number).with(:review_backlog_ceiling).and_return(2)
      targets = entities(4)
      seed([ proposal(widget, targets[0], band: "medium"), proposal(widget, targets[1], band: "medium") ])

      rows = seed([ proposal(widget, targets[2], band: "low"), proposal(widget, targets[3], band: "high") ])

      expect(rows.map { |row| row.payload["to_entity_id"] }).to eq([ targets[3].id ])
      expect(MaintenanceReport.find(rows.first.maintenance_report_id).data["skipped_backlog_full"]).to eq("relationship_proposal" => 1)
    end

    it "clamps the backlog ceiling setting to its range (a value written past validation can't escape it)" do
      setting = AppSettings.find_or_initialize_by(var: "review_backlog_ceiling")
      setting.value = 10
      setting.save!(validate: false)
      expect(AppSettings.review_number(:review_backlog_ceiling)).to eq(50)
      setting.update_columns(value: 9_999.to_yaml)
      expect(AppSettings.review_number(:review_backlog_ceiling)).to eq(5_000)
    end
  end

  describe "expiring suppressions in the seed path" do
    let(:item) { proposal(widget, beta) }
    let(:signature) { described_class.signature_for("relationship_proposal", item) }

    it "lets a signature back in once its suppression expired, and keeps it out while a snooze runs" do
      MaintenanceReportSuppression.create!(report_type: "compaction_review", signature: signature, source: "snoozed",
                                           expires_at: 3.days.from_now)
      expect(seed([ item ])).to be_empty

      MaintenanceReportSuppression.update_all(expires_at: 1.minute.ago)
      expect(seed([ item ]).size).to eq(1)
    end

    it "doesn't count an expired row as already proposed" do
      row = seed([ item ]).sole
      row.update!(status: "expired")

      expect(described_class.suppressed?("relationship_proposal", item)).to be(false)
    end
  end

  describe ".items" do
    it "pages in SQL by priority (total_count works) and caps a text search" do
      targets = Array.new(3) { |i| MemoryEntity.create!(name: "SynthGadget #{i}", entity_type: "Component") }
      seed([ proposal(widget, targets[0], band: "low"), proposal(widget, targets[1], band: "high"),
             proposal(widget, targets[2], band: "medium") ])

      page = described_class.items
      expect(page).to be_a(ActiveRecord::Relation)
      expect(page.total_count).to eq(3)
      expect(page.map { |row| row.payload["confidence_band"] }).to eq(%w[high medium low])

      stub_const("CompactionReviewService::Queries::SEARCH_SCAN_CAP", 2)
      found = described_class.items(q: "relationship")
      expect(found.size).to eq(2)
      expect(found.search_capped?).to be(true)
    end
  end
end
