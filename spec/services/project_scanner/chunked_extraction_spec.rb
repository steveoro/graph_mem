# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanner::ChunkedExtraction do
  let(:prompts) { [] }
  let(:calls) { [] }

  def chunk(index, *pieces)
    ProjectScanner::ChunkPlanner::Chunk.new(index: index, files: [], pieces: pieces, estimated_tokens: 1)
  end

  def block(name, lines = 1)
    "--- FILE: #{name}\n#{(1..lines).map { |i| "#{name} line #{i}" }.join("\n")}\n---\n"
  end

  def answer(*names, relations: [])
    { ok: true, done_reason: "stop", prompt_tokens: 100,
      text: { architecture: names.map { |name| { entity: { name: name, type: "Component" }, observations: [ "#{name} exists." ], relations: relations } } }.to_json }
  end

  # Answers by the files in the prompt: a Proc per file name, or the default answer naming the first file.
  def stub_generate(overrides = {})
    allow(SummaryGenerationClient).to receive(:generate) do |prompt, **options|
      prompts << prompt
      calls << options[:options]
      file = prompt[/--- FILE: (\S+)/, 1]
      override = overrides[file]
      override ? override.call(prompt) : answer(file.to_s.tr(".", "_"))
    end
  end

  def run(chunks)
    described_class.new(chunks: chunks, project_name: "Gadget Project", num_ctx: 8192, num_predict: 2048, timeout: 120).call
  end

  it "makes one request per part with the window, the answer budget, JSON, no truncation and no client cut" do
    stub_generate

    outcome = run([ chunk(1, block("a.rb")), chunk(2, block("b.rb")), chunk(3, block("c.rb")) ])

    expect(calls).to all(eq(num_ctx: 8192, num_predict: 2048, format: "json", truncate: false, timeout: 120, max_output_length: nil))
    expect(prompts.map { |prompt| prompt[/This is part \d+ of \d+ of one project \(project name: Gadget Project\)/] })
      .to eq((1..3).map { |i| "This is part #{i} of 3 of one project (project name: Gadget Project)" })
    expect(prompts.first).not_to include("Entities already found")
    expect(prompts.last).to include("Entities already found (reuse these exact names when you mean the same thing): a_rb; b_rb")
    expect(outcome.data["architecture"].map { |item| item["entity"]["name"] }).to eq(%w[a_rb b_rb c_rb])
    expect(outcome).to have_attributes(parts_total: 3, parts_done: 3, parts_failed: 0, first_error: nil)
  end

  it "splits a part whose answer was cut once, between its files, and sends both halves" do
    stub_generate("a.rb" => ->(prompt) { prompt.include?("b.rb") ? answer("x").merge(done_reason: "length") : answer("a_rb") })

    outcome = run([ chunk(1, block("a.rb"), block("b.rb")) ])

    expect(prompts.size).to eq(3)
    expect(prompts.last).to include("This is part 2 of 2")
    expect(outcome).to have_attributes(parts_total: 2, parts_done: 2, parts_failed: 0)
  end

  it "splits a single file's block by lines, and a half that fails again is final" do
    stub_generate("big.rb" => ->(_prompt) { answer("x").merge(done_reason: "length") })

    outcome = run([ chunk(1, block("big.rb", 6)) ])

    expect(prompts.size).to eq(3)
    expect(prompts[1]).to include("--- FILE: big.rb (half 1 of 2)\nbig.rb line 1\nbig.rb line 2\nbig.rb line 3\n---")
    expect(prompts[2]).to include("--- FILE: big.rb (half 2 of 2)\nbig.rb line 4")
    expect(outcome).to have_attributes(data: nil, parts_total: 2, parts_failed: 2, first_error: "answer cut at num_predict 2048 (done_reason: length)")
  end

  it "fails a part whose prompt was cut (prompt_eval_count at the window)" do
    stub_generate("a.rb" => ->(_prompt) { answer("a_rb").merge(prompt_tokens: 8192 - 2048) })

    outcome = run([ chunk(1, block("a.rb")), chunk(2, block("b.rb")) ])

    expect(outcome).to have_attributes(parts_done: 1, parts_failed: 1, first_error: "prompt cut: 6144 prompt tokens for a 6144-token window")
  end

  it "fails a part that isn't a JSON object with an architecture array" do
    stub_generate("a.rb" => ->(_prompt) { { ok: true, text: '{"project": {}}' } })

    expect(run([ chunk(1, block("a.rb")) ])).to have_attributes(data: nil, parts_failed: 1, first_error: "LLM response was not valid JSON")
  end

  it "stops after two provider errors in a row and skips the rest without a request" do
    down = ->(_prompt) { { ok: false, text: nil, error: "provider_unavailable" } }
    stub_generate("b.rb" => down, "c.rb" => down)

    outcome = run(%w[a.rb b.rb c.rb d.rb e.rb].each_with_index.map { |name, i| chunk(i + 1, block(name)) })

    expect(prompts.size).to eq(3)
    expect(outcome).to have_attributes(parts_total: 5, parts_done: 1, parts_failed: 4, first_error: "provider_unavailable")
    expect(outcome.data["architecture"].size).to eq(1)
  end
end
