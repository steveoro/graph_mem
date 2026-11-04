# frozen_string_literal: true

require "rails_helper"

# Agent-CLI PR5, step Q: one cloud-using job at a time. While a task's chain names a cloud provider,
# ProjectScanJob and FactSupersedeJob share one Solid Queue semaphore ("llm/llm_cloud", limit 1);
# otherwise each keeps its own key, so local jobs are unaffected.
RSpec.describe "One cloud job at a time" do
  before { AppSettings.clear_cache }
  after { AppSettings.clear_cache }

  def scan_job(id = SecureRandom.uuid) = ProjectScanJob.new(id, "/path/to/gadget", "Gadget Project", nil, "rescan", false, nil)

  it "tells whether a task's chain is cloud" do
    expect(Llm::Router::TASKS.map { |task| Llm::Router.cloud_chain?(task) }).to all(be(false))
    AppSettings.llm_chain_scan = "claude,ollama"
    expect(Llm::Router.cloud_chain?(:scan)).to be(true)
    AppSettings.llm_chain_judge = "ollama,agent_cli"
    expect(Llm::Router.cloud_chain?(:judge)).to be(true)
    expect(with_llm_provider(FakeProvider.new(cloud: true)) { Llm::Router.cloud_chain?(:summary) }).to be(true)
  end

  it "keeps each local job on its own key" do
    expect(scan_job("scan-1").concurrency_key).to eq("ProjectScanJob/scan:scan-1")
    expect(scan_job("scan-2").concurrency_key).not_to eq(scan_job("scan-1").concurrency_key)
    expect(FactSupersedeJob.new(7).concurrency_key).to eq("FactSupersedeJob/fact:7")
  end

  it "puts two cloud scan jobs, and a cloud fact job, on one semaphore with a limit of one" do
    AppSettings.llm_chain_scan = "claude"
    AppSettings.llm_chain_judge = "devin,ollama"

    keys = [ scan_job("scan-1"), scan_job("scan-2"), FactSupersedeJob.new(7) ].map(&:concurrency_key)
    expect(keys.uniq).to eq([ "llm/llm_cloud" ])
    expect([ ProjectScanJob.concurrency_limit, FactSupersedeJob.concurrency_limit ]).to eq([ 1, 1 ])
  end

  it "leaves a local fact job alone while only the scan chain is cloud" do
    AppSettings.llm_chain_scan = "claude"

    expect(FactSupersedeJob.new(7).concurrency_key).to eq("FactSupersedeJob/fact:7")
    expect(scan_job("scan-1").concurrency_key).to eq("llm/llm_cloud")
  end
end
