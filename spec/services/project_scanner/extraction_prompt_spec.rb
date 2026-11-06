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

  it "adds the code-map section (1.75.0) within its reserve, before the files, and counts the reserve only with a map" do
    guide = { own: [ "Gadget::Badge (Model)" ], related: (1..300).map { |i| "Gadget::Widget#{i} (Model)" }, gems: true }

    prompt = described_class.text("--- FILE: a.rb\n---\n", part: 1, parts: 1, project_name: "Gadget Project", guide: guide)
    section = prompt[/Code entities defined.*?(?=\nFiles:)/m]

    expect(section).to start_with("#{described_class::CODE_MAP_OWN}Gadget::Badge (Model)\n#{described_class::CODE_MAP_RELATED}Gadget::Widget1 (Model); ")
    expect(section.bytesize).to be <= described_class::CODE_MAP_RESERVE_BYTES
    expect(prompt.index("Code entities defined")).to be < prompt.index("Files:")
    empty = described_class.text("", part: 999, parts: 999, project_name: "Gadget Project").bytesize
    reserves = described_class::NAMES_RESERVE_BYTES + described_class::CODE_MAP_RESERVE_BYTES
    expect(described_class.overhead_tokens("Gadget Project", code_map: true)).to eq(((empty + reserves) / 3.0).ceil)
  end

  it "lists only the gem rule when the guide holds no entity, and nothing without a guide" do
    with_gems = described_class.text("", part: 1, parts: 1, project_name: "Gadget Project", guide: { own: [], related: [], gems: true })

    expect(with_gems).to include(described_class::CODE_MAP_GEMS)
    expect(with_gems).not_to include("Code entities defined")
    expect(described_class.text("", part: 1, parts: 1, project_name: "Gadget Project")).not_to include(described_class::CODE_MAP_GEMS)
  end
end
