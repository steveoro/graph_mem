# frozen_string_literal: true

require "rails_helper"

# F-3b step P: the optional on_part_done hook (graph_mem:scan_profile's timing) reports each
# request's end, and changes nothing about the extraction.
RSpec.describe ProjectScanner::ChunkedExtraction, "#on_part_done" do
  let(:prompts) { [] }

  def chunk(index, *pieces)
    ProjectScanner::ChunkPlanner::Chunk.new(index: index, files: [], pieces: pieces, estimated_tokens: 1)
  end

  def block(name) = "--- FILE: #{name}\n#{name} body\n---\n"

  def answer(name, done_reason: "stop")
    { ok: true, done_reason: done_reason, prompt_tokens: 100,
      text: { architecture: [ { entity: { name: name, type: "Component" }, observations: [ "#{name} renders frames." ], relations: [] } ] }.to_json }
  end

  # synth_widget.rb with gadget.rb in the same part is cut (split); a part naming broken.rb fails.
  before do
    allow(SummaryGenerationClient).to receive(:generate) do |prompt, **|
      prompts << prompt
      files = prompt.scan(/^--- FILE: (\S+)/).flatten
      next { ok: false, error: "provider_unavailable", http_status: nil } if files.include?("broken.rb")

      files.size > 1 ? answer("x", done_reason: "length") : answer(files.first)
    end
  end

  def run(chunks, on_part_done: nil)
    described_class.new(chunks: chunks, project_name: "Gadget Project", num_ctx: 8192, num_predict: 2048, timeout: 120,
                        on_part_done: on_part_done).call
  end

  it "reports every request: its part, the parts known then, its error, its time and whether it was split" do
    done = []

    outcome = run([ chunk(1, block("synth_widget.rb"), block("gadget.rb")), chunk(2, block("broken.rb")) ], on_part_done: ->(part) { done << part })

    expect(done.map { |part| part.to_h.except(:seconds) }).to eq([
      { part: 1, parts: 3, error: "answer cut at num_predict 2048 (done_reason: length)", split: true },
      { part: 1, parts: 3, error: nil, split: false },
      { part: 2, parts: 3, error: nil, split: false },
      { part: 3, parts: 3, error: "provider_unavailable", split: false }
    ])
    expect(done.map(&:seconds)).to all(be_a(Float).and(be >= 0))
    expect(outcome).to have_attributes(parts_total: 3, parts_done: 2, parts_failed: 1)
  end

  it "gives the same outcome with and without the hook" do
    chunks = [ chunk(1, block("synth_widget.rb"), block("gadget.rb")), chunk(2, block("broken.rb")) ]

    expect(run(chunks, on_part_done: ->(_part) { })).to eq(run(chunks))
  end
end
