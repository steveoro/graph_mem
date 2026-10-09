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
    expect(swimmer["observations"].map { |obs| obs["content"] }).to include("Defined at app/models/swimmer.rb:L3")
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

  describe "input validation" do
    it "rejects a non-object payload" do
      expect { described_class.new("[1,2,3]", project_name: "x") }
        .to raise_error(ArgumentError, /JSON object/)
    end

    it "rejects non-array nodes/links" do
      expect do
        described_class.new({ "nodes" => "x", "links" => [] }, project_name: "x")
      end.to raise_error(ArgumentError, /'nodes' must be an array/)
      expect do
        described_class.new({ "nodes" => [], "links" => "x" }, project_name: "x")
      end.to raise_error(ArgumentError, /'links' must be an array/)
    end

    it "rejects nodes without an id" do
      expect do
        described_class.new({ "nodes" => [ { "label" => "x" } ] }, project_name: "x")
      end.to raise_error(ArgumentError, /'id'/)
    end
  end

  describe "degenerate graphs" do
    let(:two_nodes) do
      {
        "nodes" => [
          { "id" => "a", "label" => "x.rb", "source_file" => "x.rb" },
          { "id" => "b", "label" => "y.rb", "source_file" => "y.rb" }
        ],
        "links" => []
      }
    end

    it "keeps the first of duplicate node ids and counts the rest" do
      dup = two_nodes.deep_dup
      dup["nodes"] << dup["nodes"].first.merge("label" => "z.rb")
      result = described_class.new(dup, project_name: "p").translate
      expect(result.stats[:nodes_skipped_duplicate_ids]).to eq(1)
      expect(result.stats[:nodes_imported]).to eq(2)
    end

    it "drops over-long labels before they can abort the import" do
      data = two_nodes.deep_dup
      data["nodes"] << { "id" => "big", "label" => "x" * 300, "source_file" => "big.rb" }
      result = described_class.new(data, project_name: "p").translate
      names = result.import_data["root_nodes"].first["children"].map { |c| c["name"] }
      expect(names).not_to include("x" * 300)
      expect(result.stats[:nodes_skipped_overlong]).to eq(1)
    end

    it "promotes containment-cycle nodes to the root instead of dropping them" do
      cycle = {
        "nodes" => [
          { "id" => "a", "label" => "A" },
          { "id" => "b", "label" => "B" },
          { "id" => "c", "label" => "C" }
        ],
        "links" => [
          { "source" => "a", "target" => "b", "relation" => "contains" },
          { "source" => "b", "target" => "c", "relation" => "contains" },
          { "source" => "c", "target" => "a", "relation" => "contains" }
        ]
      }
      result = described_class.new(cycle, project_name: "p").translate
      names = flatten(result.import_data["root_nodes"].first).map { |node| node["name"] }
      expect(names).to include("A", "B", "C") # all emitted, nested under one promoted head
      expect(result.stats[:nodes_promoted_to_root]).to eq(3)
    end

    it "treats a self-containment loop as a root" do
      self_loop = {
        "nodes" => [ { "id" => "a", "label" => "A" } ],
        "links" => [ { "source" => "a", "target" => "a", "relation" => "contains" } ]
      }
      result = described_class.new(self_loop, project_name: "p").translate
      names = result.import_data["root_nodes"].first["children"].map { |child| child["name"] }
      expect(names).to eq([ "A" ])
    end

    it "caps pathological depth by re-attaching deep nodes under the root" do
      depth = GraphifyImporter::MAX_TREE_DEPTH + 10
      nodes = (0..depth).map { |i| { "id" => i.to_s, "label" => "N#{i}" } }
      links = (1..depth).map { |i| { "source" => (i - 1).to_s, "target" => i.to_s, "relation" => "contains" } }
      result = described_class.new({ "nodes" => nodes, "links" => links }, project_name: "p").translate
      emitted_names = flatten(result.import_data["root_nodes"].first).map { |node| node["name"] }
      expect(emitted_names).to include("N0", "N74") # nothing lost
      expect(emitted_names.size).to eq(nodes.size + 1) # + project root
      expect(result.stats[:nodes_promoted_to_root]).to eq(11)
      # 2 root children: the original chain head and the promoted tail head
      expect(result.import_data["root_nodes"].first["children"].size).to eq(2)
    end
  end

  describe ".seed_ambiguous_relations" do
    let!(:caller_e) { MemoryEntity.create!(name: "Caller", entity_type: "Class", aliases: "") }
    let!(:callee_e) { MemoryEntity.create!(name: "Callee", entity_type: "Class", aliases: "") }

    let(:edge) do
      {
        "from_name" => "Caller", "from_type" => "Class",
        "to_name" => "Callee", "to_type" => "Class",
        "relation_type" => "calls", "confidence" => 0.4,
        "properties" => { "source_file" => "app/caller.rb", "source_location" => "9", "context" => "x" }
      }
    end

    it "seeds a relationship_proposal row with the full payload" do
      rows = described_class.seed_ambiguous_relations([ edge ], "proj")
      expect(rows.size).to eq(1)
      payload = rows.first.payload
      expect(payload["kind"]).to eq("relationship_proposal")
      expect(payload["relation_type"]).to eq("calls")
      expect(payload["score"]).to eq(4)
      expect(payload["from_entity_id"]).to eq(caller_e.id)
      expect(payload["to_entity_id"]).to eq(callee_e.id)
      expect(payload["confidence_band"]).to eq("low")
    end

    it "is idempotent and skips edges that already exist as relations" do
      MemoryRelation.create!(from_entity_id: caller_e.id, to_entity_id: callee_e.id,
                             relation_type: "calls")
      expect(described_class.seed_ambiguous_relations([ edge ], "proj")).to eq([])
    end

    it "skips edges with unresolvable endpoints" do
      ghost = edge.merge("to_name" => "Ghost")
      expect(described_class.seed_ambiguous_relations([ ghost ], "proj")).to eq([])
    end
  end

  describe ".headless_decisions" do
    let!(:existing_file) { MemoryEntity.create!(name: "old.rb", entity_type: "File", aliases: "") }
    let!(:moved_class) { MemoryEntity.create!(name: "User", entity_type: "Class", aliases: "") }
    let!(:orphan_class) { MemoryEntity.create!(name: "Visitor", entity_type: "Class", aliases: "") }
    let!(:existing_project) do
      MemoryEntity.create!(name: "graph_mem", entity_type: "Project", aliases: "")
    end

    before do
      MemoryRelation.create!(from_entity_id: moved_class.id, to_entity_id: existing_file.id,
                             relation_type: "part_of")
    end

    def root_match(node_path: "0", name: "new_repo", fuzzy_id: nil)
      ImportMatchingStrategy::MatchResult.new(
        is_child: false, node_path: node_path,
        import_node: { name: name, entity_type: "Project" },
        selected_match_id: fuzzy_id
      )
    end

    it "excludes an already-parented child whose import parent is absent (no match)" do
      # With no root match in the set, the child's import parent resolves to
      # nothing — the entity's real parent belongs to another tree.
      match = ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0",
                              child_action: "add_relation", exact_match: moved_class)
      expect(described_class.headless_decisions([ match ]))
        .to eq([ { node_path: "0.children.0", child_action: "exclude" } ])
    end

    it "keeps child add_relation when the matched entity has no part_of parent" do
      match = ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0",
                              child_action: "add_relation", exact_match: orphan_class)
      expect(described_class.headless_decisions([ match ]))
        .to eq([ { node_path: "0.children.0", child_action: "add_relation" } ])
    end

    it "excludes the whole subtree when the matched child is parented under a different entity" do
      # moved_class lives under existing_file; the import's root "0" creates a
      # brand-new parent, so moved_class and its descendants are foreign to
      # this import — `exclude` is a counted no-op, not `skip` (whose
      # create-on-missing fallback would orphan new descendants).
      matches = [
        root_match(name: "new_repo"),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0",
                                                child_action: "add_relation", exact_match: moved_class),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0.children.0",
                                                child_action: "create", exact_match: nil)
      ]
      expect(described_class.headless_decisions(matches)).to eq([
        { node_path: "0", action: "create" },
        { node_path: "0.children.0", child_action: "exclude" },
        { node_path: "0.children.0.children.0", child_action: "exclude" }
      ])
    end

    it "does not flag a child parented under the Project the root merges into" do
      # moved_class's real parent chain resolves to the root's exact-match
      # Project — a rescan, not a foreign tree: descendants keep their actions.
      # Parent moved_class under existing_project for this scenario:
      MemoryRelation.where(from_entity_id: moved_class.id, relation_type: "part_of").destroy_all
      MemoryRelation.create!(from_entity_id: moved_class.id, to_entity_id: existing_project.id,
                             relation_type: "part_of")

      matches = [
        root_match(name: "graph_mem", fuzzy_id: existing_file.id),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0",
                                                child_action: "add_relation", exact_match: moved_class),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0.children.0",
                                                child_action: "create", exact_match: nil)
      ]
      expect(described_class.headless_decisions(matches)).to eq([
        { node_path: "0", action: "merge", target_id: existing_project.id },
        { node_path: "0.children.0", child_action: "skip" },
        { node_path: "0.children.0.children.0", child_action: "create" }
      ])
    end

    it "merges a root only on an exact name+type match, never the fuzzy selection" do
      decoy = MemoryEntity.create!(name: "Victim Project", entity_type: "Project", aliases: "")

      # Fuzzy match picks a decoy; the name matches no entity exactly.
      decisions = described_class.headless_decisions(
        [ root_match(name: "new_repo", fuzzy_id: decoy.id) ]
      )
      expect(decisions).to eq([ { node_path: "0", action: "create" } ])

      # Exact name+type match merges (name is unique + case-insensitive).
      decisions = described_class.headless_decisions(
        [ root_match(name: "graph_mem", fuzzy_id: decoy.id) ]
      )
      expect(decisions).to eq([ { node_path: "0", action: "merge", target_id: existing_project.id } ])

      # Same name but wrong type does not merge into a Project.
      decisions = described_class.headless_decisions(
        [ root_match(name: "old.rb", fuzzy_id: existing_file.id) ]
      )
      expect(decisions).to eq([ { node_path: "0", action: "create" } ])
    end

    it "passes through other child actions and creates unmatched roots" do
      matches = [
        root_match(name: "new_repo", fuzzy_id: existing_project.id),
        root_match(node_path: "1", name: "other_repo"),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.0", child_action: "create"),
        ImportMatchingStrategy::MatchResult.new(is_child: true, node_path: "0.children.1", child_action: "skip")
      ]
      expect(described_class.headless_decisions(matches)).to eq([
        { node_path: "0", action: "create" },
        { node_path: "1", action: "create" },
        { node_path: "0.children.0", child_action: "create" },
        { node_path: "0.children.1", child_action: "skip" }
      ])
    end
  end
end
