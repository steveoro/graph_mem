# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphifyImporter do
  let(:graph_json) { file_fixture("graphify_sample.json").read }
  let(:importer) { described_class.new(graph_json, project_name: "sample_app") }
  let(:result) { importer.translate }
  let(:root) { result.import_data["root_nodes"].first }

  def flatten(node)
    [ node ] + (node["children"] || []).flat_map { |child| flatten(child) }
  end

  let(:all_nodes) { flatten(root) }

  it "builds a single Project root named after the repo" do
    expect(result.import_data["root_nodes"].size).to eq(1)
    expect(root["name"]).to eq("sample_app")
    expect(root["entity_type"]).to eq("Project")
    expect(root["observations"].first["source"]).to eq("graphify")
  end

  it "places File entities under the project" do
    files = root["children"].select { |child| child["entity_type"] == "File" }
    expect(files.map { |f| f["name"] }).to include(
      "app/models/swimmer.rb",
      "app/models/application_record.rb",
      "app/models/concerns/auditable.rb"
    )
  end

  it "nests classes under their defining file with a provenance observation" do
    swimmer_file = root["children"].find { |child| child["name"] == "app/models/swimmer.rb" }
    swimmer = swimmer_file["children"].find { |child| child["entity_type"] == "Class" }
    expect(swimmer["name"]).to eq("Swimmer")
    expect(swimmer["relation_type"]).to eq("part_of")
    expect(swimmer["observations"].map { |obs| obs["content"] }).to include("Defined at app/models/swimmer.rbL3")
  end

  it "qualifies method names with their owning class" do
    methods = all_nodes.select { |node| node["entity_type"] == "Method" }
    expect(methods.map { |m| m["name"] }).to contain_exactly("Swimmer#name", "Swimmer#find")
  end

  it "imports constants under their file" do
    constant = all_nodes.find { |node| node["entity_type"] == "Constant" }
    expect(constant["name"]).to eq("DEFAULT_SCOPE")
    parent_file = root["children"].find { |child| child["name"] == "app/models/swimmer.rb" }
    expect(parent_file["children"]).to include(constant)
  end

  it "attaches fileless external-referenced nodes under the project root" do
    stderror = all_nodes.find { |node| node["name"] == "StandardError" }
    expect(stderror["entity_type"]).to eq("Class")
    expect(root["children"]).to include(stderror)
  end

  it "skips external concept placeholder nodes" do
    expect(all_nodes.map { |node| node["name"] }).not_to include("ref_external_gem")
    expect(result.stats[:nodes_skipped_external]).to eq(1)
  end

  it "emits non-tree edges as name+type relations" do
    inherits = result.import_data["relations"].find { |rel| rel["relation_type"] == "inherits" }
    expect(inherits["from_name"]).to eq("Swimmer")
    expect(inherits["to_name"]).to eq("ApplicationRecord")
    expect(inherits["properties"]["source"]).to eq("graphify")
    expect(inherits["properties"]["provenance"]).to eq("EXTRACTED")
  end

  it "maps mixes_in and calls edges and keeps indirect context" do
    mixes = result.import_data["relations"].find { |rel| rel["relation_type"] == "mixes_in" }
    expect(mixes["to_name"]).to eq("Auditable")

    call = result.import_data["relations"].find do |rel|
      rel["relation_type"] == "calls" && rel["from_name"] == "Swimmer#name"
    end
    expect(call["to_name"]).to eq("Swimmer#find")
    expect(call["confidence"]).to eq(1.0)
  end

  it "maps imports_from edges to depends_on" do
    import_rel = result.import_data["relations"].find { |rel| rel["relation_type"] == "depends_on" }
    expect(import_rel["from_name"]).to eq("app/models/swimmer.rb")
    expect(import_rel["to_name"]).to eq("app/models/concerns/auditable.rb")
    expect(import_rel["properties"]["graphify_relation"]).to eq("imports_from")
  end

  it "withholds AMBIGUOUS edges from the relations array" do
    expect(result.ambiguous_relations.size).to eq(1)
    ambiguous = result.ambiguous_relations.first
    expect(ambiguous["to_name"]).to eq("StandardError")
    expect(result.import_data["relations"]).not_to include(ambiguous)
  end

  it "drops edges whose endpoint is external and reports counts" do
    expect(result.stats[:relations_dropped_unresolved]).to eq(1) # imports_from → ref_external_gem
    expect(result.stats[:nodes_imported]).to eq(10)
    expect(result.stats[:relations_emitted]).to eq(5)
  end

  it "dedupes repeated edges keeping the highest confidence" do
    duplicate = result.ambiguous_relations
    expect(duplicate).to eq(result.ambiguous_relations.uniq)
  end

  it "accepts a pre-parsed hash" do
    parsed = JSON.parse(graph_json)
    expect(described_class.new(parsed, project_name: "x").translate.stats[:nodes_imported]).to eq(10)
  end
end
