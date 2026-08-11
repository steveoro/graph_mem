# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectScanValidator, type: :service do
  before do
    @project = MemoryEntity.create!(name: "TestProject", entity_type: "Project")
    @entity = MemoryEntity.create!(name: "SampleComponent", entity_type: "Component")
    MemoryRelation.create!(from_entity: @entity, to_entity: @project, relation_type: "part_of")
  end

  def validator(options = {})
    ProjectScanValidator.new(
      project_entity: options[:project_entity] || @project,
      scan_id: options[:scan_id] || SecureRandom.uuid,
      created_entity_ids: options[:created_entity_ids] || Set.new,
      context_text: options[:context_text] || "",
      extracted_data: options[:extracted_data] || {},
      project_root: options[:project_root] || "/tmp",
      dry_run: options[:dry_run] || false,
      logger: Logger.new(File::NULL),
      operation_progress: nil
    )
  end

  describe "#call" do
    it "auto-moves a scan-sourced observation with a single clear target" do
      target = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component")
      MemoryRelation.create!(from_entity: target, to_entity: @project, relation_type: "part_of")

      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "The dream state compactor schedules UI refreshes.",
        source: "project_scan:old:reconcile"
      )

      result = validator.call

      expect(result.observations_moved).to eq(1)
      expect(observation.reload).to be_obsolete
      expect(target.active_memory_observations.first&.content).to eq(observation.content)
      expect(result.scan_review_items).to be_empty
    end

    it "queues a move_observation review for a manual/sourceless observation with a single clear target" do
      target = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component")
      MemoryRelation.create!(from_entity: target, to_entity: @project, relation_type: "part_of")

      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "The dream state compactor schedules UI refreshes.",
        source: nil
      )

      result = validator.call

      expect(result.observations_moved).to eq(0)
      expect(observation.reload).not_to be_obsolete
      expect(result.scan_review_items.size).to eq(1)
      expect(result.scan_review_items.first[:kind]).to eq("move_observation")
      expect(result.scan_review_items.first[:observation_id]).to eq(observation.id)
      expect(result.scan_review_items.first[:target_entity_id]).to eq(target.id)
    end

    it "queues a delete_observation review for a manual/sourceless observation with no target" do
      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "Some totally unrelated fact with no matching target.",
        source: nil
      )

      result = validator.call

      expect(result.observations_moved).to eq(0)
      expect(result.observations_obsoleted).to eq(0)
      expect(observation.reload).not_to be_obsolete
      expect(result.scan_review_items.size).to eq(1)
      expect(result.scan_review_items.first[:kind]).to eq("delete_observation")
      expect(result.scan_review_items.first[:observation_id]).to eq(observation.id)
    end

    it "obsoletes a scan-sourced observation with no clear target" do
      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "Some totally unrelated fact with no matching target.",
        source: "project_scan:old:reconcile"
      )

      result = validator.call

      expect(result.observations_obsoleted).to eq(1)
      expect(observation.reload).to be_obsolete
      expect(observation.confidence).to eq(1.0)
    end

    it "queues a move_observation review with candidate_ids when multiple targets match" do
      candidate = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component")
      other = MemoryEntity.create!(name: "UI Refreshes", entity_type: "Feature")
      MemoryRelation.create!(from_entity: candidate, to_entity: @project, relation_type: "part_of")
      MemoryRelation.create!(from_entity: other, to_entity: @project, relation_type: "part_of")

      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "The dream state compactor schedules UI refreshes.",
        source: "project_scan:old:reconcile"
      )

      result = validator.call

      expect(result.observations_moved).to eq(0)
      expect(result.scan_review_items.size).to eq(1)
      item = result.scan_review_items.first
      expect(item[:kind]).to eq("move_observation")
      expect(item[:candidate_ids]).to include(candidate.id, other.id)
    end

    it "does not mutate the graph when dry_run is true" do
      target = MemoryEntity.create!(name: "Dream State Compactor", entity_type: "Component")
      MemoryRelation.create!(from_entity: target, to_entity: @project, relation_type: "part_of")

      observation = MemoryObservation.create!(
        memory_entity: @entity,
        content: "The dream state compactor schedules UI refreshes.",
        source: "project_scan:old:reconcile"
      )

      result = validator(dry_run: true).call

      expect(result.observations_moved).to eq(0)
      expect(result.observations_obsoleted).to eq(0)
      expect(result.relations_deleted).to eq(0)
      expect(result.scan_review_items).to be_empty
      expect(observation.reload).not_to be_obsolete
    end
  end

  describe "batched validation" do
    it "pauses after the configured batch size and resumes from the saved state" do
      allow(AppSettings).to receive(:project_scan_validation_batch_size).and_return(3)

      5.times do |i|
        entity = MemoryEntity.create!(name: "BatchEntity#{i}", entity_type: "Component")
        MemoryRelation.create!(from_entity: entity, to_entity: @project, relation_type: "part_of")
        MemoryObservation.create!(memory_entity: entity, content: "Entity #{i} observation", source: "manual")
      end

      operation = OperationProgress.start!(
        operation_type: "project_scan",
        total_count: 10,
        details: { "project_root" => "/tmp", "project_name" => "TestProject" }
      )

      first = ProjectScanValidator.new(
        project_entity: @project,
        scan_id: SecureRandom.uuid,
        created_entity_ids: Set.new,
        context_text: "",
        extracted_data: {},
        project_root: "/tmp",
        dry_run: false,
        logger: Logger.new(File::NULL),
        operation_progress: operation
      ).call

      expect(first.paused).to be true
      expect(first.remaining_entity_ids.size).to eq(3)
      expect(first.processed_entity_ids.size).to eq(3)
      expect(operation.reload.details["validation_state"]["paused"]).to be true

      second = ProjectScanValidator.new(
        project_entity: @project,
        scan_id: SecureRandom.uuid,
        created_entity_ids: Set.new,
        context_text: "",
        extracted_data: {},
        project_root: "/tmp",
        dry_run: false,
        logger: Logger.new(File::NULL),
        operation_progress: operation
      ).call

      expect(second.paused).to be false
      expect(second.remaining_entity_ids).to be_empty
      expect(second.processed_entity_ids.size).to eq(6)
    end

    it "does not batch when operation_progress is not provided" do
      allow(AppSettings).to receive(:project_scan_validation_batch_size).and_return(3)

      5.times do |i|
        entity = MemoryEntity.create!(name: "NoBatchEntity#{i}", entity_type: "Component")
        MemoryRelation.create!(from_entity: entity, to_entity: @project, relation_type: "part_of")
        MemoryObservation.create!(memory_entity: entity, content: "Entity #{i} observation", source: "manual")
      end

      result = validator.call

      expect(result.paused).to be false
      expect(result.processed_entity_ids.size).to eq(6)
    end
  end

  describe "relation validation" do
    it "auto-deletes a part_of relation to the wrong project root" do
      other_project = MemoryEntity.create!(name: "OtherProject", entity_type: "Project")
      stray = MemoryEntity.create!(name: "StrayComponent", entity_type: "Component")
      MemoryRelation.create!(from_entity: stray, to_entity: @project, relation_type: "part_of")
      wrong_relation = MemoryRelation.new(from_entity: stray, to_entity: other_project, relation_type: "part_of")
      wrong_relation.save(validate: false)

      result = validator.call

      expect(result.relations_deleted).to eq(1)
      expect(MemoryRelation.exists?(wrong_relation.id)).to be false
    end

    it "queues a delete_relation review for usage relations not supported by scan context" do
      library = MemoryEntity.create!(name: "jQuery", entity_type: "Framework")
      MemoryRelation.create!(from_entity: @entity, to_entity: library, relation_type: "depends_on")

      context_text = "AuthService validates user credentials."
      extracted_data = { "architecture" => [ { "entity" => { "name" => "AuthService" } } ] }

      result = validator(context_text: context_text, extracted_data: extracted_data).call

      expect(result.relations_deleted).to eq(0)
      expect(result.scan_review_items.size).to eq(1)
      item = result.scan_review_items.first
      expect(item[:kind]).to eq("delete_relation")
      expect(item[:relation_id]).to eq(MemoryRelation.last.id)
    end

    it "keeps usage relations whose target appears in the scan context" do
      library = MemoryEntity.create!(name: "jQuery", entity_type: "Framework")
      MemoryRelation.create!(from_entity: @entity, to_entity: library, relation_type: "depends_on")

      result = validator(context_text: "SampleComponent depends on jQuery.").call

      expect(result.relations_deleted).to eq(0)
      expect(result.scan_review_items).to be_empty
    end
  end
end
