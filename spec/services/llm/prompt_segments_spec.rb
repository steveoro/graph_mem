# frozen_string_literal: true

require "rails_helper"

# Which text of each prompt is `data` (PR2's anonymizer rewrites only data segments): everything
# that comes from the caller, the graph or the scanned files. The trusted segments hold none of the
# synthetic names, query or texts; the rendered strings themselves are pinned by P0's goldens.
RSpec.describe "LLM prompt segments" do
  let(:prompts) { [] }

  before do
    allow(Llm::Prompt).to receive(:new).and_wrap_original { |original, *args| original.call(*args).tap { |prompt| prompts << prompt } }
  end

  def texts(kind) = prompts.sole.segments.select { |segment| segment.kind == kind }.map(&:text).join

  def expect_data_only(*values)
    expect(texts(:data)).to include(*values)
    values.each { |value| expect(texts(:trusted)).not_to include(value) }
  end

  it "summary: the caller's query and style, entity names and observation text are data" do
    widget = MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget caches frames in Alpha Service.")
    allow(HybridSearchStrategy).to receive(:new).and_return(
      instance_double(HybridSearchStrategy, search: [ HybridSearchStrategy::SearchResult.new(entity: widget, score: 0.9, matched_fields: [ "name" ]) ])
    )

    with_llm_provider(FakeProvider.new(result: { ok: true, text: "Done.", error: nil, latency_ms: 1.0 })) do
      SummarizerService.call(query: "auth flow in Gadget Project", style: "detailed")
    end

    expect_data_only("auth flow in Gadget Project", "detailed", "SynthWidget", "caches frames in Alpha Service")
    expect(texts(:trusted)).to include("Scope: global", "observation_id=")
  end

  it "scan part: the project name, earlier names and file contents are data" do
    ProjectScanner::ExtractionPrompt.text("--- FILE: lib/synth_widget.rb\nclass SynthWidget; end\n---\n",
                                          part: 2, parts: 3, project_name: "Gadget Project", names: [ "Alpha Service" ])

    expect_data_only("Gadget Project", "Alpha Service", "synth_widget.rb", "class SynthWidget")
    expect(texts(:trusted)).to include("This is part 2 of 3", "Entities already found", "Files:")
  end

  it "judge: the project name, the fact and the statements are data" do
    gadget = fs_project!("Gadget Project")
    widget = fs_member!(gadget, "SynthWidget")
    fs_observe!(widget, "The MCP server runs on fast-mcp.")
    fact = fs_fact!(gadget, tags: [ "replaces:fast-mcp" ])
    candidates = FactSupersede::LegacyGuard.new(fact).apply(FactSupersede::Candidates.call(fact).candidates)

    with_llm_provider(FakeProvider.new) { FactSupersede::Judge.call(fact, candidates) }

    expect_data_only("Gadget Project", "official mcp gem", "docs:README.md", "SynthWidget", "runs on fast-mcp")
    expect(texts(:trusted)).to include("Age is not evidence", "STATEMENTS:")
  end
end
