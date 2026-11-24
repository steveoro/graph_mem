# frozen_string_literal: true

require "rails_helper"

# An import follows the part_of edges: only nodes a part_of chain links to the import's root Project
# are created, and matched, in its project; any other declared node is global, matched by name
# globally (ImportEntityResolver.contained_child?). The matcher's preview and the execute agree.
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
end
