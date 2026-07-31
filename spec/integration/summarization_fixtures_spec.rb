# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Summarization fixtures", type: :integration do
  %w[
    graph_mem_service_summarization.json
    graph_mem_tool_summarization.json
  ].each do |fixture_name|
    it "keeps the baseline contract for #{fixture_name}" do
      path = Rails.root.join("spec/fixtures/files", fixture_name)
      data = JSON.parse(File.read(path))

      expect(data).to include(
        "query",
        "summary",
        "generation_mode",
        "entity_count",
        "observation_count",
        "observations",
        "sources"
      )
      expect(data["observations"]).to all(include("id", "content", "entity_name"))
      expect(data["sources"]).to all(include("entity_id", "observation_id"))
    end
  end

  it "documents the cross-project noise the service fixture captured" do
    data = JSON.parse(File.read(Rails.root.join("spec/fixtures/files/graph_mem_service_summarization.json")))

    entity_names = data.fetch("observations").map { |obs| obs.fetch("entity_name") }.uniq
    # The original call was sidetracked to include unrelated projects as evidence, which were then redacted from the fixture file:
    expect(entity_names).to include("[READACTED]")
  end

  it "documents the scoped manual fixture as graph_mem-rooted evidence" do
    data = JSON.parse(File.read(Rails.root.join("spec/fixtures/files/graph_mem_tool_summarization.json")))

    entity_names = data.fetch("observations").map { |obs| obs.fetch("entity_name") }.uniq
    expect(entity_names).to all(satisfy { |name| name.include?("graph_mem") || name.include?("MCP") })
    # The original call was sidetracked to include unrelated projects as evidence, which were then redacted from the fixture file:
    expect(entity_names).not_to include("[READACTED]")
  end
end
