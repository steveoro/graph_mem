# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

# UI-2b H1: what Home shows, section by section, and the health strip's rules. Synthetic data
# only; the embedding probe only ever sees the unroutable OLLAMA_URL or a stub.
RSpec.describe HomeSnapshot do
  let(:health) { described_class::Health.new }

  def pill(key) = health.pills.find { |entry| entry[:key] == key }

  describe ".section" do
    it "answers each section and refuses an unknown one" do
      expect(described_class::SECTIONS.map { |name| described_class.section(name.to_s) }).to all(be_present.or(eq([])))
      expect { described_class.section(:bogus) }.to raise_error(ArgumentError, /unknown Home section/)
    end
  end

  describe "the health strip" do
    it "has one pill per subsystem, each linking to the page that explains it" do
      expect(health.pills.map { |entry| entry[:key] }).to eq(%i[database embeddings summaries jobs backup scans mcp guest])
      expect(health.pills).to all(include(:label, :value, :href, status: be_in(described_class::Health::STATUSES)))
    end

    it "reports the database as connected" do
      expect(pill(:database)).to include(status: :ok, value: "connected")
    end

    context "with the embedding service" do
      before { allow(EmbeddingStatusSnapshot).to receive(:call).and_return(vector_search_ready: ready) }

      let(:ready) { true }

      it "is red when it doesn't answer (the unroutable OLLAMA_URL)" do
        expect(health.embedding_reachable?).to be(false)
        expect(pill(:embeddings)).to include(status: :danger, value: "unreachable")
      end

      it "is green when it answers and vector search is ready" do
        allow(health).to receive(:embedding_reachable?).and_return(true)

        expect(pill(:embeddings)).to include(status: :ok, value: "reachable · vector search ready")
      end

      context "when embeddings or indexes are missing" do
        let(:ready) { false }

        it "is amber" do
          allow(health).to receive(:embedding_reachable?).and_return(true)

          expect(pill(:embeddings)).to include(status: :warn, value: "reachable · embeddings or indexes missing")
        end
      end
    end

    it "treats summaries as a choice, not a problem" do
      allow(AppSettings).to receive(:llm_summarization_enabled?).and_return(false)
      expect(pill(:summaries)).to include(status: :neutral, value: "LLM off")

      allow(AppSettings).to receive(:llm_summarization_enabled?).and_return(true)
      expect(pill(:summaries)).to include(status: :ok, value: "LLM on")
    end

    it "rates the job queue by failures and latency, and says so when it can't be read" do
      {
        nil => [ :neutral, "queue not readable" ],
        { failed: 2, latency: 0 } => [ :danger, "2 failed" ],
        { failed: 0, latency: 10.minutes.to_i } => [ :warn, "latency 10 minutes" ],
        { failed: 0, latency: 3 } => [ :ok, "0 failed" ]
      }.each do |stats, (status, value)|
        allow(health).to receive(:queue_stats).and_return(stats)

        expect(pill(:jobs)).to include(status: status, value: include(value)), stats.inspect
      end
    end

    it "rates the last backup by its age" do
      Dir.mktmpdir("home_backups") do |dir|
        AppSettings.backup_folder_path = dir
        expect(pill(:backup)).to include(status: :warn, value: "no backup yet")

        file = File.join(dir, "202601011200_test.sql.bz2")
        File.write(file, "synthetic")
        { 2.hours.ago => :ok, 3.days.ago => :warn, 10.days.ago => :danger }.each do |mtime, status|
          File.utime(mtime.to_time, mtime.to_time, file)
          expect(pill(:backup)).to include(status: status, value: end_with("ago")), status.to_s
        end
      end
    end

    it "rates the scan mounts from ScanRootPolicy.status" do
      base = { scans_switch: true, enabled: true, warnings: [] }
      {
        base.merge(scans_switch: false) => [ :neutral, "switched off" ],
        base.merge(enabled: false) => [ :danger, "nothing mounted" ],
        base.merge(warnings: [ :mounted_read_write ]) => [ :warn, "mounted read-write" ],
        base => [ :ok, "mounted read-only" ]
      }.each do |status, (color, value)|
        allow(ScanRootPolicy).to receive(:status).and_return(status)

        expect(pill(:scans)).to include(status: color, value: value)
      end
    end

    it "shows the MCP access mode from the access policy, settings extras included" do
      policy = GraphMem::McpAccessPolicy.new(allowed_ips: "127.0.0.0/8", extra_ips: [ "10.8.0.0/24" ])
      allow(GraphMem::OfficialMcp).to receive(:access_policy).and_return(policy)

      expect(pill(:mcp)).to include(status: :neutral, value: "no token (unauthenticated), 2 allowed range(s) (+1 from settings)",
                                    href: "/operator/settings?tab=mcp_access")

      allow(GraphMem::OfficialMcp).to receive(:access_policy).and_return(GraphMem::McpAccessPolicy.new(token: "synthetic-token"))
      expect(pill(:mcp)).to include(status: :ok, value: start_with("bearer token required"))
    end

    it "shows the guest account's state" do
      { not_configured: :neutral, disabled: :neutral, available: :ok, conflict: :danger }.each do |state, color|
        allow(GraphMem::GuestCredentials).to receive(:current).and_return(instance_double(GraphMem::GuestCredentials, status: state))

        expect(pill(:guest)[:status]).to eq(color), state.to_s
      end
    end
  end

  describe "#counts" do
    it "counts the graph, the orphans and the embedding coverage" do
      widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
      MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
      MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")

      expect(described_class.new.counts).to include(entities: 2, observations: 1, relations: 0, orphans: 1, coverage_percent: be_between(0, 100))
    end
  end

  describe "#digest" do
    it "takes the top attention groups and the last policy run" do
      allow(AppSettings).to receive(:review_number).and_call_original
      allow(AppSettings).to receive(:review_number).with(:review_attention_threshold).and_return(1)
      entities = Array.new(7) { |i| MemoryEntity.create!(name: "SynthWidget #{i}", entity_type: "Component") }
      CompactionReviewService.seed_report(report_type: "compaction_review", source: "test", items: entities.each_cons(2).map do |from, to|
        { id: SecureRandom.uuid, kind: "relationship_proposal", from_entity_id: from.id, to_entity_id: to.id,
          relation_type: "depends_on", confidence_band: "high", score: 14 }
      end)
      MaintenanceReport.create!(report_type: "review_policy_run", data: { "policies" => { "dangling" => { "acted" => 12 }, "expire_low_confidence" => { "acted" => 3 } } })

      digest = described_class.new.digest

      expect(digest[:groups].size).to eq(described_class::DIGEST_SIZE)
      expect(digest[:attention_count]).to eq(6)
      expect(digest).to include(last_policy_run_resolved: 15, last_policy_run_at: be_present)
    end
  end

  describe "#jobs" do
    it "splits running from finished operations, newest first" do
      OperationProgress.create!(operation_type: "export", operation_id: SecureRandom.uuid, status: "completed", total_count: 1, current_count: 1, percentage: 100)
      running = OperationProgress.start!(operation_type: "import", total_count: 10)

      jobs = described_class.new.jobs

      expect(jobs[:running].map { |job| job[:operation_id] }).to eq([ running.operation_id ])
      expect(jobs[:recent].map { |job| job[:operation] }).to eq([ "export" ])
      expect(jobs[:compaction]).to include(:dream_state)
    end
  end

  describe "#activity" do
    it "lists the latest change sets, at most ACTIVITY_SIZE" do
      (described_class::ACTIVITY_SIZE + 2).times do |i|
        ChangeSet.create!(uuid: SecureRandom.uuid, kind: "graph.write", summary: "synthetic write #{i}", created_at: i.minutes.ago)
      end

      activity = described_class.new.activity

      expect(activity.size).to eq(described_class::ACTIVITY_SIZE)
      expect(activity.first.summary).to eq("synthetic write 0")
    end
  end

  describe "#clients" do
    it "keeps the summary and the most recent clients" do
      7.times { |i| AgentContext.create!(client_id: "synth-client-#{i}", last_seen_at: i.minutes.ago) }

      clients = described_class.new.clients

      expect(clients[:summary]).to include(total: 7)
      expect(clients[:clients].map { |client| client[:client_id] }).to eq((0...5).map { |i| "synth-client-#{i}" })
    end
  end
end
