# frozen_string_literal: true

require "rails_helper"

# An import follows the part_of edges: only nodes a part_of chain links to the import's root Project
# are created in its project; any other declared node is created global
# (ImportEntityResolver.contained_child?). Every declared node is looked up in the import's project
# first, then globally. The matcher's preview and the execute agree.
RSpec.describe "Import scope" do
  let(:detector) { instance_double(ImportObservationDuplicateDetector) }
  let!(:shared) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Service") }
  let(:import_data) do
    child = ->(name, type, relation, children = []) { { "name" => name, "entity_type" => type, "relation_type" => relation, "children" => children } }
    { "root_nodes" => [ { "name" => "Gadget Project", "entity_type" => "Project", "children" => [
      child.call("SynthWidget", "Component", "part_of"),
      child.call("Alpha Service", "Service", "depends_on", [ child.call("SynthGadget", "Component", "part_of") ])
    ] } ] }
  end
  let(:paths) { { "SynthWidget" => "0.children.0", "Alpha Service" => "0.children.1", "SynthGadget" => "0.children.1.children.0" } }

  before { allow(detector).to receive(:find_duplicate).and_return(ImportObservationDuplicateDetector::Result.new(duplicate: false)) }

  def execute!
    decisions = [ { node_path: "0", action: "create" } ] + paths.values.map { |path| { node_path: path, action: "create" } }
    ImportExecutionStrategy.new(observation_duplicate_detector: detector).execute(import_data, decisions)
  end

  it "puts a part_of child in the project and a depends_on child, with what hangs below it, in the global scope" do
    expect(execute!.success).to be(true)

    project = MemoryEntity.find_by!(name: "Gadget Project")
    expect(MemoryEntity.find_by!(name: "SynthWidget").project_id).to eq(project.id)
    expect(MemoryEntity.where(name: "Alpha Service").pluck(:id)).to eq([ shared.id ]) # merged into the global one
    expect(shared.reload.project_id).to be_nil
    expect(MemoryEntity.find_by!(name: "SynthGadget").project_id).to be_nil
    expect(MemoryRelation.exists?(from_entity_id: project.id, to_entity_id: shared.id, relation_type: "depends_on") ||
           MemoryRelation.exists?(from_entity_id: shared.id, to_entity_id: project.id, relation_type: "depends_on")).to be(true)
  end

  it "previews the same entities the execute writes into" do
    project = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
    member = fs_member!(project, "SynthWidget")
    MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") # a global namesake the member must win over

    matches = ImportMatchingStrategy.new.match(import_data)[:match_results].to_h { |result| [ result.node_path, result.exact_match&.id ] }
    expect(matches.values_at(*paths.values_at("SynthWidget", "Alpha Service"))).to eq([ member.id, shared.id ])

    execute!

    expect(MemoryEntity.where(name: "SynthWidget", project_id: project.id).pluck(:id)).to eq([ member.id ])
    expect(MemoryEntity.where(name: "Alpha Service").pluck(:id)).to eq([ shared.id ])
  end

  # The review's finding: an import before 1.93.1 stamped a depends_on child into the project, and the
  # membership repair attached it to the project root. Re-importing the same file must find it there.
  describe "a declared node outside the project's part_of tree" do
    let(:import_data) do
      { "root_nodes" => [ { "name" => "Gadget Project", "entity_type" => "Project", "children" => [
        { "name" => "Beta Service", "entity_type" => "Service", "relation_type" => "depends_on", "children" => [] }
      ] } ] }
    end
    let!(:project) { MemoryEntity.create!(name: "Gadget Project", entity_type: "Project") }

    def preview = ImportMatchingStrategy.new.match(import_data)[:match_results]

    def preview_match = preview.find { |result| result.node_path == "0.children.0" }

    # The decisions the import review submits for this preview.
    def execute_reviewed!
      decisions = ImportDecisions.merge(nil, preview.map(&:to_h))
      ImportExecutionStrategy.new(observation_duplicate_detector: detector).execute(import_data, decisions)
    end

    def execute_created!
      decisions = [ { node_path: "0", action: "create" }, { node_path: "0.children.0", action: "create" } ]
      ImportExecutionStrategy.new(observation_duplicate_detector: detector).execute(import_data, decisions)
    end

    def services = MemoryEntity.where(name: "Beta Service").order(:id).pluck(:id, :project_id)

    def stamped_depends_on_member!
      member = MemoryEntity.create!(name: "Beta Service", entity_type: "Service")
      MemoryRelation.create!(from_entity: member, to_entity: project, relation_type: "depends_on")
      member.update_column(:project_id, project.id)
      ProjectIdBackfill.new(out: ->(_line) { }).run
      member
    end

    it "finds the member an earlier import stamped into the project once the repair attached it, in the preview and the execute" do
      member = stamped_depends_on_member!
      expect(MemoryRelation.exists?(from_entity_id: member.id, to_entity_id: project.id, relation_type: "part_of")).to be(true)

      expect([ preview_match.exact_match&.id, preview_match.child_action ]).to eq([ member.id, "skip" ])
      expect(execute_reviewed!.success).to be(true)
      expect(services).to eq([ [ member.id, project.id ] ])
    end

    it "merges a create decision into that member instead of copying it to the global scope" do
      member = stamped_depends_on_member!

      expect { expect(execute_created!.success).to be(true) }.not_to change(MemoryEntity, :count)
      expect(services).to eq([ [ member.id, project.id ] ])
    end

    it "prefers the project's member over a global namesake" do
      member = fs_member!(project, "Beta Service", "Service")
      MemoryEntity.create!(name: "Beta Service", entity_type: "Service")

      expect(preview_match.exact_match&.id).to eq(member.id)
      expect { execute_created! }.not_to change(MemoryEntity, :count)
      expect(MemoryRelation.exists?(from_entity_id: member.id, to_entity_id: project.id, relation_type: "depends_on")).to be(true)
    end

    context "with a code-type namesake in the project" do
      let(:import_data) do
        { "root_nodes" => [ { "name" => "Gadget Project", "entity_type" => "Project", "children" => [
          { "name" => "SynthWidget", "entity_type" => "Model", "relation_type" => "depends_on", "children" => [] }
        ] } ] }
      end
      let!(:member) { fs_member!(project, "SynthWidget", "Class") }

      it "claims it through the review's decision, retyping it (specific beats generic)" do
        expect(preview_match.exact_match&.id).to eq(member.id)
        expect(execute_reviewed!.success).to be(true)
        expect(MemoryEntity.where(name: "SynthWidget").pluck(:id, :entity_type)).to eq([ [ member.id, "Model" ] ])
      end

      it "claims it through a create decision, retyping it" do
        expect { execute_created! }.not_to change(MemoryEntity, :count)
        expect(member.reload.entity_type).to eq("Model")
      end
    end

    it "uses the global entity when only the global scope holds the name" do
      global = MemoryEntity.create!(name: "Beta Service", entity_type: "Service")

      expect(preview_match.exact_match&.id).to eq(global.id)
      expect(execute_reviewed!.success).to be(true)
      expect(services).to eq([ [ global.id, nil ] ])
    end

    it "creates the node global when neither scope holds the name" do
      expect([ preview_match.exact_match, preview_match.child_action ]).to eq([ nil, "create" ])
      expect(execute_reviewed!.success).to be(true)
      expect(services.map(&:last)).to eq([ nil ])
    end
  end
end
