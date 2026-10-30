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

  it "creates a relation to an entity listed later in the answer (two-pass reconcile)" do
    allow(SummaryGenerationClient).to receive(:generate).and_return(
      ok: true, done_reason: "stop", prompt_tokens: 100,
      text: { project: { name: "TestProject" }, architecture: [
        { entity: { name: "SynthWidget", type: "Component" }, relations: [ { to: "Alpha Service", type: "depends_on", confidence: 0.8 } ] },
        { entity: { name: "Alpha Service", type: "Service" }, observations: [ "Alpha Service serves widgets." ] }
      ] }.to_json
    )

    ProjectScanner.new(project_root: @project_root, project_name: "TestProject").call

    widget = MemoryEntity.find_by!(name: "SynthWidget")
    alpha = MemoryEntity.find_by!(name: "Alpha Service")
    expect(MemoryRelation.where(from_entity_id: widget.id, to_entity_id: alpha.id, relation_type: "depends_on")).to exist
    expect(SummaryGenerationClient).to have_received(:generate).once
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
    jquery = MemoryEntity.create!(name: "jQuery", entity_type: "Framework", project_id: project.id)
    compactor = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component", project_id: project.id)
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
    entity = MemoryEntity.create!(name: "OrphanedFact", entity_type: "Component", project_id: project.id)
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

  describe "top-level directories in the deterministic fallback" do
    before { allow(SummarizationConfig).to receive(:llm_usable?).and_return(false) }

    it "doesn't list a top-level symlink to an outside folder as a Component" do
      Dir.mktmpdir("outside") do |outside|
        FileUtils.mkdir_p(File.join(@project_root, "app"))
        File.symlink(outside, File.join(@project_root, "linked_alpha"))

        ProjectScanner.new(project_root: @project_root, project_name: "Gadget Project").call

        expect(MemoryEntity.where(name: "app", entity_type: "Component")).to exist
        expect(MemoryEntity.where(name: "linked_alpha")).to be_empty
      end
    end

    it "leaves out one entry that vanishes before lstat and keeps the others" do
      %w[app docs gone_widget].each { |dir| FileUtils.mkdir_p(File.join(@project_root, dir)) }
      gone = File.join(@project_root, "gone_widget")
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(gone).and_raise(Errno::ENOENT)

      dirs = ProjectScanner.new(project_root: @project_root).send(:top_level_directories)
      # The temp folder's cleanup lstats every entry again.
      allow(File).to receive(:lstat).and_call_original

      expect(dirs).to contain_exactly("app", "docs")
    end
  end

  describe "staying inside the project root (PR-0 §0.5)" do
    %w[../outside/* /etc/*].each do |glob|
      it "fails without reading anything for file_globs #{glob.inspect}" do
        result = ProjectScanner.new(project_root: @project_root, file_globs: [ glob ]).call

        expect(result.success).to be false
        expect(result.errors.first).to include("must be relative to the project root")
        expect(SummaryGenerationClient).not_to have_received(:generate)
      end
    end

    it "skips a symlinked file that resolves outside the root and an explicitly globbed .env" do
      Dir.mktmpdir("outside") do |outside|
        File.write(File.join(outside, "secret.md"), "OUTSIDE_TEXT")
        File.symlink(File.join(outside, "secret.md"), File.join(@project_root, "linked.md"))
        File.write(File.join(@project_root, ".env"), "ENV_TEXT=1")

        scanner = ProjectScanner.new(project_root: @project_root, file_globs: %w[README.md linked.md .env])
        result = scanner.call

        expect(scanner.send(:discover_files)).to eq([ File.join(@project_root, "README.md") ])
        expect(result.to_h).to include(skipped_outside_root: 1, skipped_denylisted: 1)
      end
    end

    it "never reads docs/plans, which describes work that hasn't happened yet" do
      FileUtils.mkdir_p(File.join(@project_root, "docs/plans/nested"))
      File.write(File.join(@project_root, "docs/guide.md"), "# SynthWidget guide")
      File.write(File.join(@project_root, "docs/plans/x.md"), "# Planned: SynthWidget moves to Gadget")
      File.write(File.join(@project_root, "docs/plans/nested/y.md"), "# Planned too")

      files = ProjectScanner.new(project_root: @project_root).send(:discover_files)

      expect(files).to include(File.join(@project_root, "docs/guide.md"))
      expect(files.grep(%r{/docs/plans/})).to be_empty
    end

    it "sorts before applying max_files, so the kept set is deterministic" do
      %w[c.md a.md b.md].each { |name| File.write(File.join(@project_root, name), "# #{name}") }
      scanner = ProjectScanner.new(project_root: @project_root, file_globs: %w[*.md], max_files: 2)

      expect(scanner.send(:discover_files)).to eq(%w[README.md a.md].map { |name| File.join(@project_root, name) })
    end
  end
end
