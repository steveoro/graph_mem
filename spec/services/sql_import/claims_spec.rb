# frozen_string_literal: true

require "rails_helper"

# Point 4 of the SQL exchange PR 1 review, Steve's decision "claim the global namesake": a staged
# project member with no match in its project takes over a global entity of the same name and type
# that has no owned part_of parent, with its subtree, as the JSON import does; otherwise a copy.
RSpec.describe "graph_mem-sql: claiming a global namesake" do
  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component", description: "from the source machine") }
  let!(:fact) { fs_observe!(widget, "SynthWidget renders the dashboard.") }
  let(:script) { sql_export(project) }

  before { script } # exported before the target is set up below

  def drop_widget!
    widget.memory_observations.delete_all
    MemoryRelation.where(from_entity_id: widget.id).delete_all
    widget.delete
  end

  def global!(name = "SynthWidget", type = "Component", **attributes)
    MemoryEntity.create!(name: name, entity_type: type, **attributes)
  end

  def claim_rows(result) = result.affected.select { |row| row["action"] == "claimed" }

  it "claims a reference stub: one row, in the project, its park edge moved to the incoming parent" do
    drop_widget!
    other = fs_project!("OtherPrj")
    stub = global!
    park = MemoryRelation.create!(from_entity: stub, to_entity: other, relation_type: "part_of", properties: { "reference_stub" => true })
    stub.update_columns(updated_at: 1.day.ago) # parked before the export: newer wins applies to a claim too

    result = sql_import(script)

    expect(MemoryEntity.where(name: "SynthWidget").pluck(:id, :project_id)).to eq([ [ stub.id, project.id ] ])
    expect(MemoryRelation.where(from_entity_id: stub.id).pluck(:id, :relation_type, :to_entity_id, :properties))
      .to eq([ [ park.id, "part_of", project.id, {} ] ])
    expect(stub.reload).to have_attributes(description: "from the source machine")
    expect(stub.memory_observations.pluck(:content)).to eq([ fact.content ])
    expect(claim_rows(result)).to contain_exactly(include("id" => stub.id, "detail" => "Component, claimed from global",
                                                          "changed" => include("project_id" => { "from" => nil, "to" => project.id })))
    expect(sql_counts(result)).to include("entities/claimed" => 1, "relations/updated" => 1)
    audit = AuditLog.find_by!(reason: "sql_import:#{result.operation_id}", auditable_type: "MemoryEntity", auditable_id: stub.id)
    expect(audit).to have_attributes(action: "update", changed_fields: include("project_id" => { "from" => nil, "to" => project.id }))
  end

  it "claims a global entity an older import left, with its part_of subtree; a second run is all unchanged" do
    drop_widget!
    leftover = global!(description: "older")
    gear = global!("SynthGear", "Component")
    MemoryRelation.create!(from_entity: gear, to_entity: leftover, relation_type: "part_of")
    leftover.update_columns(updated_at: 1.day.ago)

    result = sql_import(script)

    expect([ leftover, gear ].map { |entity| entity.reload.project_id }).to eq([ project.id, project.id ])
    expect(leftover.description).to eq("from the source machine")
    expect(MemoryRelation.where(from_entity_id: leftover.id, relation_type: "part_of").pluck(:to_entity_id)).to eq([ project.id ])
    expect(claim_rows(result).map { |row| [ row["id"], row["detail"] ] })
      .to contain_exactly([ leftover.id, "Component, claimed from global" ], [ gear.id, "Component, claimed from global with SynthWidget" ])
    expect(sql_counts(result)).to include("entities/claimed" => 2)

    again = sql_import(script)
    expect(sql_counts(again).keys.map { |key| key.split("/").last }.uniq).to eq([ "unchanged" ])
  end

  it "copies instead when a name of the namesake's subtree is taken in the project, and says why" do
    drop_widget!
    leftover = global!
    MemoryRelation.create!(from_entity: global!("SynthGear", "Component"), to_entity: leftover, relation_type: "part_of")
    fs_member!(project, "SynthGear", "Component")

    result = sql_import(script)

    expect(leftover.reload.project_id).to be_nil
    copy = MemoryEntity.find_by!(name: "SynthWidget", project_id: project.id)
    expect(result.affected).to include(include("id" => copy.id, "action" => "new",
                                               "detail" => /not claimed: a name of its part_of subtree is taken in the project/))
  end

  it "copies instead of claiming a namesake with an owned part_of parent, of another type, or a Project" do
    drop_widget!
    held = global!
    MemoryRelation.create!(from_entity: held, to_entity: global!("SynthHolder", "Module"), relation_type: "part_of")
    first = sql_import(script)
    expect(first.affected).to include(include("action" => "new", "entity" => "SynthWidget", "detail" => /not claimed: it has a part_of parent/))
    expect(held.reload.project_id).to be_nil

    sql_delete_tree!(project)
    held.update_columns(name: "SynthHeld")
    global!("SynthWidget", "Service")
    second = sql_import(script)
    expect(second.affected).to include(include("action" => "new", "entity" => "SynthWidget", "detail" => /not claimed: its type is Service/))
    expect(MemoryEntity.where(name: "SynthWidget").pluck(:entity_type, :project_id)).to contain_exactly([ "Service", nil ], [ "Component", be_present ])

    sql_delete_tree!(MemoryEntity.find_by!(name: "SynthPrj"))
    MemoryEntity.find_by!(name: "SynthWidget").update_columns(name: "SynthService")
    fs_project!("SynthWidget")
    third = sql_import(script)
    expect(third.affected).to include(include("action" => "new", "entity" => "SynthWidget", "detail" => /not claimed: it is a Project/))
  end

  it "leaves a reference stub shared when another project declares the name too (the JSON import's guard)" do
    drop_widget!
    other = fs_project!("OtherPrj")
    stub = global!
    MemoryRelation.create!(from_entity: stub, to_entity: other, relation_type: "part_of", properties: { "reference_stub" => true })
    fs_member!(fs_project!("ThirdPrj"), "SynthWidget", "Component")

    result = sql_import(script)

    expect(stub.reload.project_id).to be_nil
    expect(result.affected).to include(include("action" => "new", "detail" => /not claimed: it is a reference stub another project also declares/))
  end
end
