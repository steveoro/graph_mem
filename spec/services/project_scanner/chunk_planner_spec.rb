# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanner::ChunkPlanner do
  # 1100 tokens: 3300 bytes per part.
  let(:budget) { 1100 }

  around do |example|
    Dir.mktmpdir("chunk_planner") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def plan(files, **options)
    described_class.new(files: files, root: @root, input_budget: budget, **options).call
  end

  it "sends README and manifests first, then root files, then each top-level directory by path" do
    files = [
      write("lib/synth_widget.rb", "class SynthWidget; end"), write("app/models/b.rb", "B"), write("app/a.rb", "A"),
      write("notes.md", "Notes"), write("package.json", "{}"), write("README.md", "# Gadget Project")
    ]

    result = plan(files.shuffle(random: Random.new(1)))

    expect(result.chunks.size).to eq(1)
    expect(result.chunks.first.files).to eq(%w[README.md package.json notes.md app/a.rb app/models/b.rb lib/synth_widget.rb])
    expect(result.chunks.first.text).to start_with("--- FILE: README.md\n# Gadget Project\n---\n")
    expect(result.context_text).to eq(result.chunks.first.text)
    expect(result.files_read).to eq(6)
  end

  it "packs whole files greedily and lets a directory group spill into the next part" do
    files = (1..5).map { |i| write("app/synth_#{i}.rb", "x" * 1000) }

    result = plan(files)

    expect(result.chunks.map(&:files)).to eq([ %w[app/synth_1.rb app/synth_2.rb app/synth_3.rb], %w[app/synth_4.rb app/synth_5.rb] ])
    expect(result.chunks.map(&:index)).to eq([ 1, 2 ])
    expect(result.chunks).to all(have_attributes(estimated_tokens: be <= budget))
    expect(result.context_text).to eq(result.chunks.map(&:text).join("\n"))
  end

  it "splits a file larger than one part at line boundaries, labelled part k of m" do
    lines = (1..200).map { |i| "line #{i.to_s.rjust(3, '0')} of the Alpha Service config\n" }
    file = write("config/alpha.yml", lines.join)

    result = plan([ file ])

    expect(result.chunks.size).to be > 1
    labels = result.chunks.map { |chunk| chunk.text[/\A--- FILE: [^\n]+/] }
    expect(labels).to eq((1..result.chunks.size).map { |k| "--- FILE: config/alpha.yml (part #{k} of #{result.chunks.size})" })
    bodies = result.chunks.map { |chunk| chunk.text.lines[1..-2].join }
    expect(bodies.join).to eq(lines.join)
    expect(result.chunks).to all(have_attributes(estimated_tokens: be <= budget))
  end

  it "splits a single huge line at the byte limit, on a UTF-8 boundary" do
    file = write("docs/wide.md", "é" * 4000)

    result = plan([ file ])

    expect(result.chunks.size).to be > 1
    expect(result.chunks.map(&:text)).to all(satisfy(&:valid_encoding?))
    expect(result.chunks.sum { |chunk| chunk.text.lines[1].count("é") }).to eq(4000)
  end

  it "stops at max_chunks: the rest isn't sent, is counted and listed" do
    files = (1..6).map { |i| write("app/synth_#{i}.rb", "x" * 2000) }

    result = plan(files, max_chunks: 2)

    expect(result.chunks.size).to eq(2)
    expect(result.files_over_budget).to eq(4)
    expect(result.left_out).to eq((3..6).map { |i| "app/synth_#{i}.rb" })
    expect(result.files_read).to eq(2)
  end

  it "counts a file over max_file_bytes and the files past the total cap" do
    files = [ write("0_big.md", "x" * 600), write("a.md", "a" * 100), write("b.md", "b" * 100), write("c.md", "c" * 100) ]

    result = plan(files, max_file_bytes: 500, max_total_bytes: 200)

    expect(result.files_too_large).to eq(1)
    expect(result.files_over_budget).to eq(2)
    expect(result.left_out).to eq(%w[0_big.md b.md c.md])
    expect(result.chunks.flat_map(&:files)).to eq(%w[a.md])
  end

  it "reports window_too_small below 1024 tokens and reads nothing" do
    file = write("README.md", "# Gadget Project")
    allow(File).to receive(:binread).and_call_original

    result = described_class.new(files: [ file ], root: @root, input_budget: 1023).call

    expect(result.error).to eq(:window_too_small)
    expect(result.chunks).to be_empty
    expect(File).not_to have_received(:binread)
  end

  describe ProjectScanner::TokenEstimate do
    it "counts 3 bytes per token, rounding up, and bytes not characters" do
      expect(described_class.tokens("abcd")).to eq(2)
      expect(described_class.tokens("é" * 3)).to eq(2)
      expect(described_class.tokens(nil)).to eq(0)
    end

    it "gives 90% of the window left after the answer and the prompt" do
      expect(described_class.input_budget(num_ctx: 8192, num_predict: 2048, prompt_tokens: 700)).to eq(4899)
      expect(described_class.input_budget(num_ctx: 2048, num_predict: 2048, prompt_tokens: 700)).to eq(0)
    end
  end
end
