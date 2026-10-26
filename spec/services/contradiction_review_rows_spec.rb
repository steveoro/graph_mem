# frozen_string_literal: true

require "rails_helper"

# UI-5a A5: contradiction pairs found by the scheduled stale scan become review rows.
RSpec.describe "Contradiction review rows" do
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:beta) { MemoryEntity.create!(name: "Beta Service", entity_type: "Component") }
  let!(:first) { MemoryObservation.create!(memory_entity: widget, content: "SynthWidget supports dark mode.") }
  let!(:second) { MemoryObservation.create!(memory_entity: beta, content: "SynthWidget does not support dark mode.") }
  let(:result) { ContradictionDetector::Result.new(observation_id_1: second.id, observation_id_2: first.id, distance: 0.08, confidence: 0.95) }

  def item_for(pair_result = result)
    ContradictionDetector.review_item(pair_result).merge(id: SecureRandom.uuid)
  end

  def seed(items)
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan", items: items)
  end

  describe "ContradictionDetector.review_item" do
    it "orders the pair low → high with both owners and truncated contents" do
      long = MemoryObservation.create!(memory_entity: beta, content: "x" * 400)
      item = ContradictionDetector.review_item(ContradictionDetector::Result.new(observation_id_1: long.id,
                                                                                   observation_id_2: first.id, distance: 0.1, confidence: 0.9))

      expect(item).to include(kind: "contradiction", observation_id_1: first.id, observation_id_2: long.id,
                              entity_id_1: widget.id, entity_id_2: beta.id, entity_name_1: "SynthWidget",
                              entity_name_2: "Beta Service", distance: 0.1, confidence: 0.9)
      expect(item[:content_2].length).to eq(ContradictionDetector::REVIEW_CONTENT_LIMIT)
    end

    it "is nil when either side is gone or inactive" do
      second.mark_obsolete!(reason: "synthetic")
      expect(ContradictionDetector.review_item(result)).to be_nil
    end
  end

  describe "signature and seeding" do
    it "has one signature for both orders, and none without two ids" do
      a = CompactionReviewService.signature_for("contradiction", { observation_id_1: 3, observation_id_2: 9 })
      b = CompactionReviewService.signature_for("contradiction", { "observation_id_1" => 9, "observation_id_2" => 3 })

      expect(a).to eq("contradiction|3-9")
      expect(b).to eq(a)
      expect(CompactionReviewService.signature_for("contradiction", { observation_id_1: 3 })).to be_nil
      expect(CompactionReviewService.signature_for("contradiction", { observation_id_1: 3, observation_id_2: 3 })).to be_nil
    end

    it "seeds a re-detected pair once (either order), classified over the owner entities" do
      row = seed([ item_for ]).sole
      reversed = ContradictionDetector::Result.new(observation_id_1: first.id, observation_id_2: second.id, distance: 0.08, confidence: 0.95)

      expect(seed([ item_for(reversed) ])).to be_empty
      expect(row.reload).to have_attributes(kind: "contradiction", confidence: 0.95,
                                            group_key: "contradiction|#{[ widget.id, beta.id ].min}-#{[ widget.id, beta.id ].max}")
    end

    it "keeps a dismissed pair suppressed for good" do
      row = seed([ item_for ]).sole
      CompactionReviewService.dismiss(row.row_uuid, reason: "both are right")

      expect(seed([ item_for ])).to be_empty
    end

    it "refuses edits and bulk apply" do
      row = seed([ item_for ]).sole

      expect(CompactionReviewService.edit_item(row.row_uuid, { observation_id_1: 1 }))
        .to eq(success: false, error: "Validation failed: Contradiction rows can't be edited; choose which observation to keep")
      expect(CompactionReviewService.bulk_apply([ row.row_uuid ])[:message]).to include("not bulk-applicable")
      expect(row.reload.status).to eq("active")
    end
  end

  describe "the scheduled stale scan" do
    before do
      allow(AppSettings).to receive_messages(stale_memory_scan_enabled?: true, contradiction_detection_enabled?: true)
      configure_test_embeddings!
    end

    it "seeds the pairs it finds with the scan's source_ref and counts them in the report" do
      allow(ContradictionDetector).to receive(:detect).and_return([ result ])

      expect { StaleMemoryScanJob.perform_now }.to change { MaintenanceReportRow.where(kind: "contradiction").count }.by(1)
      report = MaintenanceReport.where(report_type: "stale_memory_scan").last
      expect(report.data).to include("contradictions_seeded" => 1, "items_seeded" => 0, "by_signal" => {})
      seeded = MaintenanceReportRow.find_by!(kind: "contradiction")
      expect(seeded.maintenance_report.data).to include("source" => "stale_memory_scan", "source_ref" => be_a(Integer))
    end

    it "seeds nothing and keeps the watermark when the detector fails" do
      allow(ContradictionDetector).to receive(:detect).and_raise(StandardError, "synthetic")
      previous = 6.hours.ago
      allow(StaleMemoryScanner).to receive(:previous_watermark).and_return(previous)

      scan = StaleMemoryScanner.scan
      expect(scan).to include(contradiction_items: [], next_watermark: previous)
      expect { StaleMemoryScanJob.perform_now }.not_to change { MaintenanceReportRow.where(kind: "contradiction").count }
    end

    it "is the only seeding path: the MCP detect_contradictions tool writes no review row" do
      allow(ContradictionDetector).to receive(:detect).and_return([ result ])

      expect { DetectContradictionsTool.new.call(entity_id: widget.id) }.not_to change(MaintenanceReportRow, :count)
    end
  end
end
