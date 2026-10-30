# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanner::ExtractionPrompt do
  it "keeps the instructions first and the files last, with the part header between" do
    prompt = described_class.text("--- FILE: README.md\n# Gadget Project\n---\n", part: 1, parts: 2, project_name: "Gadget Project")

    expect(prompt).to start_with("You are a codebase knowledge extractor.")
    expect(prompt).to include("This is part 1 of 2 of one project (project name: Gadget Project).")
    expect(prompt).to end_with("Files:\n--- FILE: README.md\n# Gadget Project\n---\n\n")
  end

  it "cuts the earlier-parts names to the reserve, and the overhead counts the whole reserve" do
    names = (1..400).map { |i| "SynthWidget#{i}" }

    line = described_class.text("", part: 2, parts: 2, project_name: "Gadget Project", names: names)[/Entities already found[^\n]*/]

    expect(line.bytesize).to be <= described_class::NAMES_RESERVE_BYTES
    expect(line).to match(/; SynthWidget\d+\z/)
    empty = described_class.text("", part: 999, parts: 999, project_name: "Gadget Project")
    expect(described_class.overhead_tokens("Gadget Project")).to eq(((empty.bytesize + described_class::NAMES_RESERVE_BYTES) / 3.0).ceil)
  end

  it "parses JSON with or without a fence, and nil for anything else" do
    expect(described_class.parse_json("```json\n{\"architecture\": []}\n```")).to eq("architecture" => [])
    expect(described_class.parse_json('{"architecture": []}')).to eq("architecture" => [])
    expect(described_class.parse_json("{\"architecture\": [")).to be_nil
    expect(described_class.parse_json("")).to be_nil
  end
end
