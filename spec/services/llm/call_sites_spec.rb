# frozen_string_literal: true

require "rails_helper"

# Agent-CLI train PR1, step A4: every call site reaches the model through Llm::Router, with its
# task and inline flag. A FakeProvider stands in for Ollama: no SummaryGenerationClient stub, no
# Net::HTTP. Each example also reads the call's [llm] usage line.
RSpec.describe "LLM call sites (through Llm::Router)" do
  before { allow(SummaryGenerationClient).to receive(:generate).and_raise("SummaryGenerationClient must not be reached") }

  it "G1: a summary is task :summary, not inline, with no options" do
    widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders gadget frames.")
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
    )
    fake = FakeProvider.new(result: { ok: true, text: "SynthWidget renders gadget frames.", error: nil, latency_ms: 4.0 })

    response = nil
    lines = llm_usage_lines { with_llm_provider(fake) { response = SummarizerService.call(query: "SynthWidget") } }

    expect(response).to include(generation_mode: "llm", summary: "SynthWidget renders gadget frames.", fallback_reason: nil)
    expect(fake.calls.sole).to have_attributes(style: "concise", options: nil, prompt: start_with("Query: SynthWidget\n"))
    expect(lines.sole).to include("task" => "summary", "provider" => "fake", "model" => "fake-model", "inline" => false, "outcome" => "ok")
  end

  describe "G3: a project scan in two parts" do
    # The scan's own part calls; its LLM words call (1.83.0) is specced in
    # spec/services/fact_keywords/llm_words_spec.rb and project_scanner_fact_dedupe_spec.rb.
    around do |example|
      AppSettings.llm_keywords_enabled = false
      example.run
    ensure
      AppSettings.where(var: "llm_keywords_enabled").delete_all
    end

    around do |example|
      Dir.mktmpdir("llm_call_sites") do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    after { %w[summary_num_ctx project_scan_chunk_output_tokens].each { |var| AppSettings.where(var: var).delete_all } }

    it "is task :scan, one call per part, with the scan's options" do
      FileUtils.mkdir_p(File.join(@root, "docs"))
      %w[alpha beta].each do |name|
        File.write(File.join(@root, "docs", "#{name}.md"), "# #{name}\n" + ("#{("The #{name} part of Gadget Project. " * 14).strip}\n" * 8))
      end
      AppSettings.summary_num_ctx = 4096
      AppSettings.project_scan_chunk_output_tokens = 512
      AppSettings.clear_cache
      fake = FakeProvider.new do |prompt, **|
        name = prompt[%r{--- FILE: docs/(\w+)\.md}, 1]
        item = { entity: { name: "#{name.capitalize} Store", type: "Component" }, observations: [ "#{name.capitalize} Store is documented." ],
                 relations: [ { to: "Gadget Project", type: "part_of", confidence: 0.9 } ] }
        { ok: true, text: { project: { name: "Gadget Project" }, architecture: [ item ] }.to_json, error: nil, latency_ms: 9.0,
          prompt_tokens: 1500, done_reason: "stop" }
      end

      result = nil
      lines = llm_usage_lines do
        with_llm_provider(fake) { result = ProjectScanner.new(project_root: @root, project_name: "Gadget Project", mode: "rescan").call }
      end

      expect(result).to have_attributes(success: true, partial: false, parts_total: 2, parts_failed: 0)
      expect(fake.calls.map(&:options)).to all(eq(num_ctx: 4096, num_predict: 512, format: "json", truncate: false, timeout: 120, max_output_length: nil))
      expect(lines.size).to eq(2)
      expect(lines).to all(include("task" => "scan", "provider" => "fake", "inline" => false, "outcome" => "ok", "prompt_tokens" => 1500))
      expect(MemoryEntity.where(name: [ "Alpha Store", "Beta Store" ]).count).to eq(2)
    end
  end

  describe "G4/G5: the fact-supersede judge" do
    let!(:gadget) { fs_project!("Gadget Project") }
    let!(:widget) { fs_member!(gadget, "SynthWidget") }
    let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
    let!(:fact) { fs_fact!(gadget, tags: [ "replaces:fast-mcp" ]) }
    let(:fake) do
      FakeProvider.new do |prompt, **|
        id = prompt[/"id":(\d+),"text"/, 1].to_i
        { ok: true, text: [ { id: id, verdict: "superseded", confidence: 0.9, reason: "The fact names the mcp gem." } ].to_json, error: nil, latency_ms: 6.0 }
      end
    end

    it "G4: FactSupersedeJob is task :judge, not inline, in JSON mode" do
      lines = llm_usage_lines { with_llm_provider(fake) { FactSupersedeJob.perform_now(fact.id) } }

      row = MaintenanceReportRow.find_by!(kind: "fact_supersede")
      expect(row.payload).to include("observation_id" => old.id, "verdict" => "superseded")
      expect(fake.calls.sole.options).to eq(num_ctx: 8192, num_predict: FactSupersede::Judge::NUM_PREDICT, format: "json")
      expect(lines.sole).to include("task" => "judge", "provider" => "fake", "inline" => false, "outcome" => "ok")
    end

    it "G5: detect_contradictions is task :judge, inline" do
      response = nil
      lines = llm_usage_lines do
        with_llm_provider(fake) do
          response = DetectContradictionsTool.new.call(entity_id: gadget.id, mode: "outdated_by_fact", fact_observation_id: fact.id)
        end
      end

      expect(response).to include(judged: true, proposal_count: 1)
      expect(response[:proposals].sole).to include("observation_id" => old.id, "verdict" => "superseded")
      expect(fake.calls.sole.options).to eq(num_ctx: 8192, num_predict: FactSupersede::Judge::NUM_PREDICT, format: "json")
      expect(lines.sole).to include("task" => "judge", "provider" => "fake", "inline" => true, "outcome" => "ok")
    end
  end
end
