# frozen_string_literal: true

require "rails_helper"

# Agent-CLI train PR1, step T: at each call site, the Hash the Router hands back is the client's
# Hash plus `provider: "ollama"` and nothing else, for a success and for a failure. The client is
# stubbed at its class-level boundary (as the existing specs do), so no model is reached.
RSpec.describe "LLM result parity (Router vs SummaryGenerationClient)" do
  let(:client_results) { [] }
  let(:router_results) { [] }

  before do
    allow(SummarizationConfig).to receive(:llm_usable?).and_return(true)
    allow(Llm::Router).to receive(:generate).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |result| router_results << result }
    end
  end

  def stub_client(*answers)
    allow(SummaryGenerationClient).to receive(:generate) { answers.shift.dup.tap { |result| client_results << result } }
  end

  def expect_parity(count)
    expect(router_results.size).to eq(count)
    router_results.zip(client_results).each { |routed, raw| expect(routed).to eq(raw.merge(provider: "ollama")) }
  end

  let(:ok) { { ok: true, text: "Alpha Service answer.", error: nil, latency_ms: 2.5, prompt_tokens: 42, done_reason: "stop" } }
  let(:failed) { { ok: false, text: nil, error: "provider_unavailable", latency_ms: 1.5, http_status: 503 } }

  it "summary (G1/G2): success and the fallback reason of a failure" do
    widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders gadget frames.")
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
    )
    stub_client(ok, failed)

    expect(SummarizerService.call(query: "SynthWidget")).to include(generation_mode: "llm", summary: "Alpha Service answer.")
    expect(SummarizerService.call(query: "SynthWidget")).to include(generation_mode: "deterministic", fallback_reason: "provider_unavailable")
    expect_parity(2)
  end

  it "scan parts (G3): the keys ChunkedExtraction reads survive, so a rejected part still splits" do
    answer = ok.merge(text: { architecture: [ { entity: { name: "SynthWidget", type: "Component" }, observations: [ "x" ], relations: [] } ] }.to_json)
    stub_client(failed.merge(http_status: 413), answer, answer)
    chunk = ProjectScanner::ChunkPlanner::Chunk.new(index: 1, files: [], pieces: [ "--- FILE: a.rb\na\n---\n", "--- FILE: b.rb\nb\n---\n" ],
                                                    estimated_tokens: 1)

    outcome = ProjectScanner::ChunkedExtraction.new(chunks: [ chunk ], project_name: "Gadget Project", num_ctx: 8192, num_predict: 2048,
                                                    timeout: 120).call

    expect(outcome).to have_attributes(parts_total: 2, parts_done: 2, parts_failed: 0)
    expect_parity(3)
  end

  it "judge (G4): one batch" do
    gadget = fs_project!("Gadget Project")
    widget = fs_member!(gadget, "SynthWidget")
    fs_observe!(widget, "The MCP server runs on fast-mcp.")
    fact = fs_fact!(gadget, tags: [ "replaces:fast-mcp" ])
    stub_client(ok.merge(text: "[]"))

    FactSupersedeJob.perform_now(fact.id)

    expect_parity(1)
  end
end
