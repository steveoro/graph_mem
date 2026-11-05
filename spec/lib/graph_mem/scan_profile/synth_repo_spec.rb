# frozen_string_literal: true

require "rails_helper"

# F-3b step F: the generated synth repo and the stub backend's answers.
RSpec.describe GraphMem::ScanProfile::SynthRepo do
  around { |example| Dir.mktmpdir("synth-repo-spec") { |dir| @dir = dir and example.run } }

  it "writes the Gadget Project files, with a long file and one over the scanner's file cap" do
    described_class.write(@dir)

    files = Dir.glob("**/*", base: @dir).select { |rel| File.file?(File.join(@dir, rel)) }
    expect(files).to include("README.md", "docs/architecture.md", "lib/gadget/synth_widget.rb", "lib/gadget/alpha_service.rb",
                             "lib/gadget/frame_buffer.rb", described_class::LONG_FILE, described_class::HUGE_FILE, "vendor/gadget_generated.rb")
    expect(File.size(File.join(@dir, described_class::HUGE_FILE))).to be > ProjectScanner::MAX_FILE_BYTES
    expect(File.size(File.join(@dir, described_class::LONG_FILE))).to be_between(20_000, ProjectScanner::MAX_FILE_BYTES)
    expect(File.read(File.join(@dir, "README.md"))).to include("# Gadget Project", "SynthWidget", "AlphaService")
  end

  it "is the same on every run" do
    Dir.mktmpdir("synth-repo-spec") do |other|
      described_class.write(@dir)
      described_class.write(other)

      expect(Dir.glob("**/*", base: other).sort.map { |rel| [ rel, File.file?(File.join(other, rel)) && File.read(File.join(other, rel)) ] })
        .to eq(Dir.glob("**/*", base: @dir).sort.map { |rel| [ rel, File.file?(File.join(@dir, rel)) && File.read(File.join(@dir, rel)) ] })
    end
  end

  it "expects the synthetic classes, and only names the stub answers use" do
    answered = described_class::ANSWERS.values.flatten.map { |item| item.dig("entity", "name") }

    expect(described_class.expected("code")[:entities]).to eq(%w[SynthWidget AlphaService FrameBuffer ReportBuilder])
    expect(described_class.expected("docs")[:entities]).to all(be_in(answered))
    expect(described_class.expected("code")[:relations]).to include(%w[AlphaService depends_on SynthWidget])
  end

  it "answers a part with the items of its file blocks" do
    prompt = "Files:\n--- FILE: lib/gadget/alpha_service.rb\nclass AlphaService\n---\n"

    answer = JSON.parse(described_class.stub_answer(prompt)[:text])

    expect(answer["architecture"].map { |item| item.dig("entity", "name") }).to eq([ "AlphaService" ])
    expect(answer.dig("project", "name")).to eq("Gadget Project")
    expect(described_class.stub_answer(prompt)[:done_reason]).to eq("stop")
  end

  it "answers a part with SPLIT_AT file blocks or more as cut, so the scan splits it" do
    prompt = Array.new(described_class::SPLIT_AT) { |i| "--- FILE: lib/gadget/part_#{i}.rb\nx\n---\n" }.join

    expect(described_class.stub_answer(prompt)).to include(done_reason: "length")
  end

  it "keeps the long file's pieces apart by their labels" do
    prompt = "--- FILE: #{described_class::LONG_FILE} (part 2 of 3)\ndef section_9\n---\n"

    expect(JSON.parse(described_class.stub_answer(prompt)[:text])["architecture"].sole.dig("entity", "name")).to eq("ReportBuilder")
  end
end
