# frozen_string_literal: true

require "rails_helper"

# 1.92.0 (docs/plans/contradiction-auto-resolve-plan.md): on by default for key-value value changes
# only. The AutoApply hard rule still refuses every other choice and destructive kind.
RSpec.describe ReviewPolicies::AutoApplyContradiction do
  let!(:service_entity) { MemoryEntity.create!(name: "SynthService", entity_type: "Service") }
  let!(:feature) { MemoryEntity.create!(name: "SynthFeature", entity_type: "Feature") }
  let(:settings) do
    %w[enable_auto_apply_contradiction auto_apply_contradiction_free_text auto_apply_contradiction_max_distance
       auto_apply_contradiction_max_tokens]
  end

  after { AppSettings.where(var: settings).delete_all }

  # The older fact first: created a day apart unless told otherwise.
  def facts(old_text, new_text, entity: service_entity, **newer)
    older = MemoryObservation.create!(memory_entity: entity, content: old_text, created_at: 2.days.ago)
    [ older, MemoryObservation.create!({ memory_entity: entity, content: new_text, created_at: 1.day.ago }.merge(newer)) ]
  end

  def seed(first, second)
    item = { id: SecureRandom.uuid, kind: "contradiction", observation_id_1: first.id, observation_id_2: second.id,
             entity_id_1: first.memory_entity_id, entity_id_2: second.memory_entity_id, distance: 0.05, confidence: 0.99 }
    CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan", items: [ item ]).sole
  end

  def run = described_class.new.call

  it "defaults to on for key-value changes, with free text off" do
    expect(AppSettings.review_policy_enabled?(:auto_apply_contradiction)).to be(true)
    expect(AppSettings.review_flag?(:auto_apply_contradiction_free_text)).to be(false)
    expect(ReviewPolicyRunner::POLICIES).to include(described_class)
  end

  it "supersedes \"Port: 3000\" by \"Port: 3001\": link, reason, one audit row, row approved, in a policy change set" do
    older, newer = facts("Port: 3000", "Port: 3001")
    row = seed(older, newer)
    stats = run

    expect(stats).to include("acted" => 1, "skipped" => 0, "refused" => 0)
    expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id,
                                            obsolescence_reason: "Superseded by observation ##{newer.id} (value change: 3000 → 3001)")
    expect(newer.reload).to have_attributes(status: "active", superseded_by_id: nil, obsoleted_at: nil)
    expect(row.reload.status).to eq("approved")
    expect(ChangeSet.find_by!(uuid: stats["change_sets"].sole).kind).to eq("policy.auto_apply_contradiction")
    audits = AuditLog.where(auditable_type: "MemoryObservation", auditable_id: older.id, action: "update")
    expect(audits.sole).to have_attributes(actor: "policy:auto_apply_contradiction")
    expect(audits.sole.changed_fields.keys).to include("status", "superseded_by_id", "obsolescence_reason")
    expect(AuditLog.where(auditable_type: "MemoryObservation", auditable_id: newer.id, action: "update")).to be_empty
  end

  it "resolves \"Enabled: false\" → \"Enabled: true\" the same way, whatever the row's id order" do
    older, newer = facts("Enabled: false", "Enabled: true", entity: feature)
    seed(newer, older)

    expect(run["acted"]).to eq(1)
    expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id)
  end

  it "takes the newer side from valid_from before created_at" do
    first = MemoryObservation.create!(memory_entity: service_entity, content: "Port: 3001", created_at: 3.days.ago, valid_from: 1.day.ago)
    second = MemoryObservation.create!(memory_entity: service_entity, content: "Port: 3000", created_at: 1.day.ago, valid_from: 5.days.ago)
    seed(first, second)

    expect(run["acted"]).to eq(1)
    expect(second.reload).to have_attributes(status: "superseded", superseded_by_id: first.id)
    expect(first.reload.status).to eq("active")
  end

  it "never applies a key mismatch, a unit mismatch, a list, another source or perspective, two entities or a polarity pair" do
    pairs = [
      facts("Port: 3000", "Timeout: 3001"),
      facts("Wait: 5s", "Wait: 5m"),
      facts("Ports: 3000, 3001", "Ports: 3000, 3002"),
      facts("Retries: 3", "Retries: 4", source: "synth-agent"),
      facts("Workers: 2", "Workers: 3", perspective: "experience"),
      [ facts("Depth: 1", "Depth: 9").first, MemoryObservation.create!(memory_entity: feature, content: "Depth: 2") ],
      facts("SynthService is supported", "SynthService is not supported")
    ]
    rows = pairs.map { |older, newer| seed(older, newer) }

    expect(run).to include("acted" => 0, "change_sets" => [])
    expect(pairs.flatten.map { |fact| fact.reload.status }.uniq).to eq([ "active" ])
    expect(rows.map { |row| row.reload.status }.uniq).to eq([ "active" ])
  end

  it "skips a tie on valid_from, created_at and updated_at, and a row with an inactive side" do
    stamp = 1.day.ago.change(usec: 0)
    tied = %w[3000 3001].map { |port| MemoryObservation.create!(memory_entity: service_entity, content: "Port: #{port}", created_at: stamp, updated_at: stamp) }
    seed(*tied)
    older, newer = facts("Workers: 2", "Workers: 3")
    seed(older, newer)
    newer.mark_obsolete!(reason: "synth")

    expect(run).to include("acted" => 0, "skipped" => 1)
    expect(tied.map { |fact| fact.reload.status }).to eq(%w[active active])
    expect(older.reload.status).to eq("active")
  end

  it "refuses every other kind, even when the candidate query returns it" do
    older, newer = facts("Port: 3000", "Port: 3001")
    other = seed(older, newer)
    other.update_columns(kind: "entity_merge")
    policy = described_class.new
    allow(policy).to receive(:eligible).and_return(MaintenanceReportRow.where(id: other.id))

    expect(policy.call).to include("acted" => 0, "refused" => 1)
    expect(older.reload.status).to eq("active")
  end

  it "does nothing with the toggle off" do
    AppSettings.enable_auto_apply_contradiction = false
    older, newer = facts("Port: 3000", "Port: 3001")
    row = seed(older, newer)

    expect(run).to include("disabled" => true)
    expect(older.reload.status).to eq("active")
    expect(row.reload.status).to eq("active")
  end

  describe "free text", :with_test_embeddings do
    let(:near) { Array.new(768, 0.1) }
    # Cosine distance about 0.20 from `near`.
    let(:apart) { Array.new(492, 0.1) + Array.new(276, 0.0) }
    let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }
    let(:vectors) { {} }

    before do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed) { |text| vectors.find { |content, _| text.include?(content) }&.last || near }
    end

    it "is off by default, and on applies a 1-2 value flip within the distance cap only" do
      older, newer = facts("It listens on port 3000 with 2 workers", "It listens on port 3001 with 4 workers")
      row = seed(older, newer)
      expect(run["acted"]).to eq(0)

      AppSettings.auto_apply_contradiction_free_text = true
      AppSettings.auto_apply_contradiction_max_tokens = 1
      expect(run["acted"]).to eq(0)

      AppSettings.auto_apply_contradiction_max_tokens = 2
      expect(run["acted"]).to eq(1)
      expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id,
                                              obsolescence_reason: "Superseded by observation ##{newer.id} (value change: 3000, 2 → 3001, 4)")
      expect(row.reload.status).to eq("approved")
    end

    it "doesn't apply past the distance cap, or three changed values" do
      AppSettings.auto_apply_contradiction_free_text = true
      vectors["port 4001"] = apart
      far = facts("It listens on port 4000", "It listens on port 4001")
      three = facts("Uses 1 worker with 2 threads on 3 queues", "Uses 4 worker with 5 threads on 6 queues")
      [ far, three ].each { |older, newer| seed(older, newer) }

      expect(run["acted"]).to eq(0)
      expect((far + three).map { |fact| fact.reload.status }.uniq).to eq([ "active" ])
    end
  end

  describe "from the scan to the policy run", :with_test_embeddings do
    let(:service) { EmbeddingService.new(config: { url: "http://test", model: "test", provider: "ollama", dims: 768 }) }

    before do
      allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
      allow(EmbeddingService).to receive(:instance).and_return(service)
      allow(service).to receive(:embed).and_return(Array.new(768, 0.1))
    end

    it "pairs \"Port: 3000\" then \"Port: 3001\" and, with the default settings, the next policy run supersedes the older" do
      older, newer = facts("Port: 3000", "Port: 3001")
      pair = ContradictionDetector.scan(service_entity.id, persist: false).pairs.sole
      row = CompactionReviewService.seed_report(report_type: "compaction_review", source: "stale_memory_scan",
                                                items: [ ContradictionDetector.review_item(pair).merge(id: SecureRandom.uuid) ]).sole

      report = ReviewPolicyRunner.call(trigger: "stale_scan")

      expect(report["policies"]["auto_apply_contradiction"]).to include("acted" => 1)
      expect(report["policies"]["no_shared_subject"]["acted"]).to eq(0)
      expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id)
      expect(row.reload.status).to eq("approved")
    end
  end

  describe "undo" do
    it "restores the older fact, clears the link and reopens the row; redo applies again" do
      older, newer = facts("Port: 3000", "Port: 3001")
      row = seed(older, newer)
      set = ChangeSet.find_by!(uuid: run["change_sets"].sole)

      undone = ChangeSetUndo.call(set.uuid, actor: "operator:synth@127.0.0.1")
      expect(undone).to be_ok
      expect(older.reload).to have_attributes(status: "active", superseded_by_id: nil, obsoleted_at: nil, obsolescence_reason: nil)
      expect(newer.reload.status).to eq("active")
      expect(row.reload.status).to eq("active")

      expect(ChangeSetUndo.call(undone.change_set.uuid, actor: "operator:synth@127.0.0.1")).to be_ok
      expect(older.reload).to have_attributes(status: "superseded", superseded_by_id: newer.id)
      expect(row.reload.status).to eq("approved")
    end

    # Graphy, #184: the reopened row was picked up again by the next run, so the revert didn't last.
    it "sticks: the next policy runs leave an undone pair for the operator" do
      older, newer = facts("Port: 3000", "Port: 3001")
      row = seed(older, newer)
      ChangeSetUndo.call(run["change_sets"].sole, actor: "operator:synth@127.0.0.1")

      expect(run).to include("acted" => 0, "change_sets" => [])
      expect(older.reload.status).to eq("active")
      expect(row.reload.status).to eq("active")

      # A later value on the same key is still resolved against the fact that was never reverted.
      latest = MemoryObservation.create!(memory_entity: service_entity, content: "Port: 3002")
      seed(newer, latest)
      expect(run["acted"]).to eq(1)
      expect(newer.reload).to have_attributes(status: "superseded", superseded_by_id: latest.id)
      expect(older.reload.status).to eq("active")
    end

    it "sticks when an operator re-activates the superseded fact by hand" do
      older, newer = facts("Port: 3000", "Port: 3001")
      first = seed(older, newer)
      run
      older.reload.update!(status: "active", obsoleted_at: nil, obsolescence_reason: nil, superseded_by_id: nil)
      first.update_columns(status: "active", applied_at: nil)

      expect(run["acted"]).to eq(0)
      expect(older.reload.status).to eq("active")
    end

    it "reads the facts of every row in one query, and the reverted ones in one" do
      3.times { |i| seed(*facts("Depth#{i}: 1", "Depth#{i}: 2")) }
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/FROM `(memory_observations|audit_logs)`/) && payload[:name] != "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.new.send(:eligible).to_a }

      expect(queries.grep(/memory_observations/).size).to eq(1)
      expect(queries.grep(/audit_logs/).size).to eq(1)
    end
  end
end
