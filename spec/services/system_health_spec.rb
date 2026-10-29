# frozen_string_literal: true

require "rails_helper"

# UI-7 S5: SystemHealth reuses Home's checks and adds latency, vector readiness, the queue
# backlog, the backup folder, the scan roots, the version and pending migrations.
RSpec.describe SystemHealth do
  subject(:health) { described_class.new }

  def check(key) = health.checks.find { |entry| entry[:key] == key }

  it "lists every check with a status from Home's statuses and a value in words" do
    expect(health.checks.map { |entry| entry[:key] })
      .to eq(%i[database embeddings vector_search summaries queue backup backup_folder scans mcp guest version migrations])
    expect(health.checks.map { |entry| entry[:status] }).to all(be_in(HomeSnapshot::Health::STATUSES))
    expect(check(:version)[:value]).to eq(GraphMem::VERSION)
    expect(check(:migrations)).to include(status: :ok, value: "up to date")
  end

  it "times the one embedding probe" do
    allow(HomeSnapshot::Health).to receive(:embedding_reachable?).and_return(true)

    expect(check(:embeddings)).to include(status: :ok, value: match(/\Areachable \(\d+ ms\)\z/))
    expect(HomeSnapshot::Health).to have_received(:embedding_reachable?).once
  end

  it "says whether the backup folder exists and is writable, without its path" do
    Dir.mktmpdir("synth_backups") do |dir|
      AppSettings.backup_folder_path = dir
      expect(check(:backup_folder)).to include(status: :ok, value: "exists and is writable", detail: nil)

      AppSettings.backup_folder_path = File.join(dir, "missing")
      expect(described_class.new.checks.find { |entry| entry[:key] == :backup_folder }).to include(status: :danger)
    ensure
      AppSettings.where(var: "backup_folder_path").delete_all
      AppSettings.clear_cache
    end
  end

  it "lists each scan root's mount mode in the page-only detail" do
    with_scan_home do |home|
      expect(check(:scans)[:value]).to include("1 scan root")
      expect(check(:scans)[:detail]).to contain_exactly(include(path: home))
    end
  end

  it "is as bad as its worst check, ignoring neutral ones" do
    expect(health.status).to eq(:danger) # the embedding service is unreachable (stubbed)

    allow(HomeSnapshot::Health).to receive(:embedding_reachable?).and_return(true)
    allow(EmbeddingStatusSnapshot).to receive(:call).and_wrap_original { |original| original.call.merge(vector_search_ready: false) }
    healthy = described_class.new
    allow(healthy).to receive(:checks).and_return([ { status: :ok }, { status: :neutral }, { status: :warn } ])
    expect(healthy.status).to eq(:warn)
    allow(healthy).to receive(:checks).and_return([ { status: :neutral } ])
    expect(healthy.status).to eq(:ok)
  end

  it "drops any user info from the embedding URL in the raw snapshots" do
    allow(EmbeddingService).to receive(:config_snapshot).and_return(url: "http://synth:secret@127.0.0.1:9", model: "m", provider: "ollama", dims: 768)

    expect(health.raw_snapshots["EmbeddingStatusSnapshot"][:config][:url]).to eq("http://127.0.0.1:9")
  end
end
