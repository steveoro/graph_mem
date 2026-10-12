# frozen_string_literal: true

require "rails_helper"

# C4: discovery-anchored stale revalidation. The spec suite deliberately pins
# the NEGATIVE space too — an old-but-undisputed fact must never be flagged:
# staleness comes from traversal signals, not dates (Steve's rule).
RSpec.describe StaleMemoryScanner do
  let(:entity) { MemoryEntity.create!(name: "ScanE", entity_type: "Entity") }

  def obs(content = "c", **attrs)
    MemoryObservation.create!({ memory_entity: entity, content: content }.merge(attrs))
  end

  describe "expired_items (valid_until elapsed)" do
    it "flags only elapsed explicit expiries" do
      expired = obs("old fact", valid_until: 2.days.ago)
      obs("fresh fact", valid_until: 2.days.from_now)
      obs("undated fact")
      items = described_class.expired_items
      expect(items.size).to eq(1)
      expect(items.first[:observation_ids]).to eq([ expired.id ])
      expect(items.first[:signal]).to eq("valid_until_elapsed")
      expect(items.first[:entity_name]).to eq("ScanE")
    end
  end

  describe "addressed_items (obs claims open + newer addressing edge)" do
    let(:issue) { MemoryEntity.create!(name: "ScanIssue", entity_type: "Issue") }
    let(:fixer) { MemoryEntity.create!(name: "Fixer", entity_type: "Entity") }

    it "flags an Issue whose open-claim obs predates a solves edge" do
      open_obs = MemoryObservation.create!(memory_entity: issue, content: "Bug #7 is still open",
                                           created_at: 5.days.ago)
      MemoryRelation.create!(from_entity_id: fixer.id, to_entity_id: issue.id,
                             relation_type: "solves", created_at: 1.day.ago)
      items = described_class.addressed_items
      expect(items.size).to eq(1)
      expect(items.first[:observation_ids]).to eq([ open_obs.id ])
      expect(items.first[:signal]).to eq("addressed_by_newer_edge")
    end

    it "does NOT flag when the addressing edge is OLDER than the obs" do
      MemoryRelation.create!(from_entity_id: fixer.id, to_entity_id: issue.id,
                             relation_type: "solves", created_at: 5.days.ago)
      MemoryObservation.create!(memory_entity: issue, content: "Bug #7 is still open",
                                created_at: 1.day.ago)
      expect(described_class.addressed_items).to be_empty
    end

    it "does NOT flag an obs that merely mentions the issue without claiming open" do
      MemoryObservation.create!(memory_entity: issue, content: "Bug #7 root-caused to the parser",
                                created_at: 5.days.ago)
      MemoryRelation.create!(from_entity_id: fixer.id, to_entity_id: issue.id,
                             relation_type: "solves", created_at: 1.day.ago)
      expect(described_class.addressed_items).to be_empty
    end

    it "does NOT flag non-Issue/Task entities" do
      MemoryObservation.create!(memory_entity: entity, content: "still open", created_at: 5.days.ago)
      MemoryRelation.create!(from_entity_id: fixer.id, to_entity_id: entity.id,
                             relation_type: "solves", created_at: 1.day.ago)
      expect(described_class.addressed_items).to be_empty
    end
  end

  describe "unrooted_items (declared importer entities, no project tree)" do
    it "flags a producer-DECLARED entity not reachable from any Project" do
      orphan = MemoryEntity.create!(name: "LostFile", entity_type: "File")
      MemoryObservation.create!(memory_entity: orphan, content: "class LostFile",
                                source: "graphify")
      # Declared-by-import evidence: a 'Defined at' provenance obs (any status).
      MemoryObservation.create!(memory_entity: orphan, content: "Defined at lib/lost_file.rb:1",
                                source: "graphify")
      items = described_class.unrooted_items
      expect(items.map { |i| i[:entity_id] }).to include(orphan.id)
      expect(items.find { |i| i[:entity_id] == orphan.id }[:signal]).to eq("unrooted_after_rescan")
    end

    it "does NOT flag a reference stub (producer-stamped but never declared)" do
      stub = MemoryEntity.create!(name: "ForeignStub", entity_type: "Class")
      # Passthrough producer-stamped obs but no 'Defined at' provenance obs —
      # reference stubs live unrooted in the global namespace BY DESIGN.
      MemoryObservation.create!(memory_entity: stub, content: "referenced helper",
                                source: "graphify")
      expect(described_class.unrooted_items.map { |i| i[:entity_id] }).not_to include(stub.id)
    end

    it "does NOT flag a rooted entity" do
      project = MemoryEntity.create!(name: "ScanProj", entity_type: "Project")
      member = MemoryEntity.create!(name: "RootedFile", entity_type: "File", project_id: project.id)
      MemoryRelation.create!(from_entity_id: member.id, to_entity_id: project.id,
                             relation_type: "part_of")
      MemoryObservation.create!(memory_entity: member, content: "class RootedFile",
                                source: "graphify")
      expect(described_class.unrooted_items.map { |i| i[:entity_id] }).not_to include(member.id)
    end

    it "does NOT flag unrooted entities whose obs are not importer-stamped" do
      MemoryObservation.create!(memory_entity: entity, content: "manual note", source: "user")
      expect(described_class.unrooted_items.map { |i| i[:entity_id] }).not_to include(entity.id)
    end
  end

  describe "scan + job + apply" do
    it "NEVER flags by age alone — old undisputed facts stay active" do
      ancient = MemoryObservation.create!(memory_entity: entity,
                                          content: "the bug lives in module X",
                                          created_at: 3.years.ago)
      items = described_class.scan[:items].flat_map { |i| i[:observation_ids] }
      expect(items).not_to include(ancient.id)
    end

    it "job seeds deduplicated review rows and a scan report with watermark" do
      allow(AppSettings).to receive(:stale_memory_scan_enabled?).and_return(true)
      obs("expired", valid_until: 1.day.ago)
      expect { StaleMemoryScanJob.perform_now }
        .to change { MaintenanceReportRow.where(kind: "stale_memory").count }.by(1)
        .and change { MaintenanceReport.where(report_type: "stale_memory_scan").count }.by(1)
      expect(MaintenanceReport.where(report_type: "stale_memory_scan").last.data["watermark"]).to be_present
      # Idempotent re-run: the signature dedupes the same detection.
      expect { StaleMemoryScanJob.perform_now }
        .not_to change { MaintenanceReportRow.where(kind: "stale_memory", status: "active").count }
    end

    it "contradiction watermark does NOT advance when the pass fails mid-scan" do
      allow(AppSettings).to receive(:contradiction_detection_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(ContradictionDetector).to receive(:detect).and_raise(StandardError, "boom")
      prev = 12.hours.ago
      allow(described_class).to receive(:previous_watermark).and_return(prev)
      obs("recent fact")
      # A failed pass keeps the previous watermark so the window is retried.
      expect(described_class.scan[:next_watermark]).to eq(prev)
    end

    it "contradiction watermark advances after a clean pass" do
      allow(AppSettings).to receive(:contradiction_detection_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(ContradictionDetector).to receive(:detect)
      obs("recent fact")
      expect(described_class.scan[:next_watermark]).to be > 1.minute.ago
    end

    it "job is a no-op when the setting is off" do
      allow(AppSettings).to receive(:stale_memory_scan_enabled?).and_return(false)
      obs("expired", valid_until: 1.day.ago)
      expect { StaleMemoryScanJob.perform_now }
        .not_to change { MaintenanceReportRow.count }
    end

    it "apply marks flagged observations obsolete with the scan reason" do
      target = obs("gone stale", valid_until: 1.day.ago)
      other = obs("still active")
      CompactionReviewService.seed_report(
        report_type: "compaction_review",
        source: "stale_memory_scan",
        items: [ { id: SecureRandom.uuid, kind: "stale_memory", entity_id: entity.id,
                   entity_name: entity.name, observation_ids: [ target.id ],
                   signal: "valid_until_elapsed", reason: "valid_until has passed" } ]
      )
      row = MaintenanceReportRow.find_by(kind: "stale_memory")
      expect(row).not_to be_nil
      result = CompactionReviewService.apply(row.row_uuid, {})
      expect(result[:success]).to be(true)
      expect(target.reload.status).to eq("obsolete")
      expect(target.obsolescence_reason).to include("valid_until_elapsed")
      expect(other.reload.status).to eq("active")
    end

    it "signature dedupes entity + obs set + signal (distinct diagnoses stay distinct)" do
      payload = { entity_id: 1, observation_ids: [ 3, 1, 2 ], signal: "x" }
      sig = CompactionReviewService.signature_for("stale_memory", payload)
      expect(sig).to eq("stale_memory|1|1-2-3|x")
      expect(CompactionReviewService.signature_for("stale_memory",
                                                   entity_id: 1, observation_ids: [ 2, 1, 3 ], signal: "x")).to eq(sig)
      # Same obs set, different signal = a different review item.
      expect(CompactionReviewService.signature_for("stale_memory",
                                                   entity_id: 1, observation_ids: [ 1, 2, 3 ], signal: "y")).not_to eq(sig)
      expect(CompactionReviewService.signature_for("stale_memory", entity_id: 1)).to be_nil
    end
  end
end
