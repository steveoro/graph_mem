# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanner, type: :service do
  around do |example|
    Dir.mktmpdir("project_scanner_test") do |dir|
      @project_root = dir
      example.run
    end
  end

  before do
    File.write(File.join(@project_root, "README.md"), "# TestProject\n\nA test project for the scanner.")
    File.write(File.join(@project_root, "package.json"), '{"name": "test-project", "version": "1.0.0"}')

    allow(SummarizationConfig).to receive(:llm_usable?).and_return(true)
    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true,
      text: {
        project: {
          name: "TestProject",
          aliases: [ "tp" ],
          description: "A test project"
        },
        architecture: [
          {
            entity: {
              name: "AuthService",
              type: "Service",
              aliases: [],
              description: "Handles authentication"
            },
            observations: [
              "AuthService validates user credentials.",
              "AuthService issues session tokens."
            ],
            relations: [
              { to: "TestProject", type: "part_of", confidence: 0.95 }
            ]
          }
        ]
      }.to_json
    )
  end

  it "creates a Project root and its architecture entities" do
    scanner = ProjectScanner.new(
      project_root: @project_root,
      project_name: "TestProject"
    )

    result = scanner.call

    expect(result.success).to be true
    expect(result.project_entity).to be_present
    expect(result.project_entity.name).to eq("TestProject")
    expect(result.project_entity.entity_type).to eq("Project")

    auth_service = MemoryEntity.find_by(name: "AuthService", entity_type: "Service")
    expect(auth_service).to be_present
    expect(auth_service.active_memory_observations.count).to eq(2)

    relation = MemoryRelation.find_by(
      from_entity_id: auth_service.id,
      to_entity_id: result.project_entity.id,
      relation_type: "part_of"
    )
    expect(relation).to be_present
  end

  it "updates an existing project entity on rescan" do
    project = MemoryEntity.create!(
      name: "TestProject",
      entity_type: "Project",
      description: ""
    )

    scanner = ProjectScanner.new(project_root: @project_root, mode: "rescan")
    result = scanner.call

    expect(result.success).to be true
    expect(result.project_entity.id).to eq(project.id)
    expect(result.project_entity.description).to eq("A test project")
  end

  it "does not write when dry_run is true" do
    scanner = ProjectScanner.new(project_root: @project_root, dry_run: true)
    result = scanner.call

    expect(result.success).to be true
    expect(MemoryEntity.find_by(name: "TestProject", entity_type: "Project")).to be_nil
    expect(result.entities_created).to eq(0)
  end

  it "uses deterministic fallback when summarization is disabled" do
    allow(SummarizationConfig).to receive(:llm_usable?).and_return(false)

    scanner = ProjectScanner.new(project_root: @project_root)
    result = scanner.call

    expect(result.success).to be true
    expect(result.fallback).to be true
    expect(result.project_entity).to be_present
    expect(result.project_entity.name).to eq("TestProject")
    expect(MemoryEntity.find_by(name: "package.json", entity_type: "Configuration")).to be_present
  end

  it "moves mis-assigned observations to the correct target entity during validation" do
    project = MemoryEntity.create!(name: "TestProject", entity_type: "Project")
    jquery = MemoryEntity.create!(name: "jQuery", entity_type: "Framework")
    compactor = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component")
    MemoryRelation.create!(from_entity: jquery, to_entity: project, relation_type: "part_of")
    MemoryRelation.create!(from_entity: compactor, to_entity: project, relation_type: "part_of")
    observation = MemoryObservation.create!(
      memory_entity: jquery,
      content: "The dream state compactor schedules UI refreshes.",
      source: "project_scan:old:reconcile"
    )

    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true,
      text: {
        project: { name: "TestProject", aliases: [], description: "A test project" },
        architecture: [
          {
            entity: { name: "AuthService", type: "Service", aliases: [], description: "" },
            observations: [ "AuthService validates user credentials." ],
            relations: [ { to: "TestProject", type: "part_of", confidence: 0.95 } ]
          },
          {
            entity: { name: "jQuery", type: "Framework", aliases: [], description: "" },
            observations: [],
            relations: [ { to: "TestProject", type: "part_of", confidence: 0.95 } ]
          },
          {
            entity: { name: "Dream State Compactor", type: "Component", aliases: [], description: "" },
            observations: [],
            relations: [ { to: "TestProject", type: "part_of", confidence: 0.95 } ]
          }
        ]
      }.to_json
    )

    scanner = ProjectScanner.new(project_root: @project_root)
    result = scanner.call

    expect(result.success).to be true
    expect(result.observations_moved).to eq(1)
    expect(observation.reload).to be_obsolete
    expect(compactor.active_memory_observations.first&.content).to eq(observation.content)
  end

  it "auto-deletes part_of relations that point to the wrong project root" do
    project = MemoryEntity.create!(name: "TestProject", entity_type: "Project")
    other_project = MemoryEntity.create!(name: "OtherProject", entity_type: "Project")
    stray = MemoryEntity.create!(name: "StrayComponent", entity_type: "Component")
    MemoryRelation.create!(from_entity: stray, to_entity: project, relation_type: "part_of")
    wrong_relation = MemoryRelation.new(from_entity: stray, to_entity: other_project, relation_type: "part_of")
    wrong_relation.save(validate: false)

    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true,
      text: {
        project: { name: "TestProject", aliases: [], description: "A test project" },
        architecture: [
          {
            entity: { name: "StrayComponent", type: "Component", aliases: [], description: "" },
            observations: [ "StrayComponent exists." ],
            relations: [ { to: "TestProject", type: "part_of", confidence: 0.95 } ]
          }
        ]
      }.to_json
    )

    scanner = ProjectScanner.new(project_root: @project_root)
    result = scanner.call

    expect(result.success).to be true
    expect(result.relations_deleted).to eq(1)
    expect(MemoryRelation.exists?(wrong_relation.id)).to be false
  end

  it "marks observations with no clear target as obsolete during validation" do
    project = MemoryEntity.create!(name: "TestProject", entity_type: "Project")
    entity = MemoryEntity.create!(name: "OrphanedFact", entity_type: "Component")
    MemoryRelation.create!(from_entity: entity, to_entity: project, relation_type: "part_of")
    observation = MemoryObservation.create!(
      memory_entity: entity,
      content: "Some totally unrelated fact with no matching target.",
      source: "project_scan:old:reconcile"
    )

    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true,
      text: {
        project: { name: "TestProject", aliases: [], description: "A test project" },
        architecture: [
          {
            entity: { name: "OrphanedFact", type: "Component", aliases: [], description: "" },
            observations: [ "OrphanedFact is present." ],
            relations: [ { to: "TestProject", type: "part_of", confidence: 0.95 } ]
          }
        ]
      }.to_json
    )

    scanner = ProjectScanner.new(project_root: @project_root)
    result = scanner.call

    expect(result.success).to be true
    expect(observation.reload).to be_obsolete
    expect(observation.confidence).to eq(1.0)
  end

  it "returns an error when the project root does not exist" do
    scanner = ProjectScanner.new(project_root: "/nonexistent/path")
    result = scanner.call

    expect(result.success).to be false
    expect(result.errors).to include(/Project root does not exist/)
  end
end
