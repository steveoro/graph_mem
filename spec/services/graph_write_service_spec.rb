# frozen_string_literal: true

require "rails_helper"

RSpec.describe GraphWriteService do
  let(:vector_strategy) { instance_double(VectorSearchStrategy, search: []) }

  before { allow(VectorSearchStrategy).to receive(:new).and_return(vector_strategy) }

  describe ".call" do
    it "executes dependency-ordered mixed operations atomically" do
      result = described_class.call(
        operations: [
          { type: "create_relation", from_entity_id: "New parent", to_entity_id: "New child", relation_type: "part_of" },
          { type: "create_entity", name: "New child", entity_type: "Task" },
          { type: "create_entity", name: "New parent", entity_type: "Project" },
          { type: "create_observation", entity_name: "New child", text_content: "Created in batch" }
        ]
      )

      expect(result).to include(mode: "batch", status: "ok")
      expect(result[:results].pluck(:index)).to eq([ 0, 1, 2, 3 ])
      expect(result[:summary]).to include(
        operations: 4,
        entities_created: 2,
        observations_created: 1,
        relations_created: 1
      )
      child = MemoryEntity.find_by!(name: "New child")
      expect(child.memory_observations.pluck(:content)).to include("Created in batch")
    end

    it "rolls back the whole batch when a later operation fails" do
      expect {
        described_class.call(
          operations: [
            { type: "create_entity", name: "Rolled back", entity_type: "Task" },
            { type: "create_observation", entity_id: 999_999, text_content: "Invalid" }
          ]
        )
      }.to raise_error(McpGraphMemErrors::ResourceNotFound, /create_observation\[1\]/)

      expect(MemoryEntity.find_by(name: "Rolled back")).to be_nil
    end

    it "returns a possible-duplicate response without writing any operation" do
      existing = MemoryEntity.create!(name: "Existing candidate", entity_type: "Task")
      candidate = Struct.new(:entity, :distance).new(existing, 0.1)
      allow(vector_strategy).to receive(:search).and_return([ candidate ])

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Near candidate", entity_type: "Task" },
          { type: "create_entity", name: "Must not persist", entity_type: "Task" }
        ]
      )

      expect(result).to include(
        status: "possible_duplicate",
        kind: "entity",
        operation_index: 0
      )
      expect(result.dig(:candidates, 0, :entity_id)).to eq(existing.id)
      expect(MemoryEntity.find_by(name: "Must not persist")).to be_nil
    end

    it "preflights canonicalized duplicate relations before writing" do
      from = MemoryEntity.create!(name: "Relation source", entity_type: "Task")
      to = MemoryEntity.create!(name: "Relation target", entity_type: "Task")
      existing = MemoryRelation.create!(from_entity: from, to_entity: to, relation_type: "depends_on")
      RelationTypeMapping.create!(canonical_type: "depends_on", variant: "requires")

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Must also not persist", entity_type: "Task" },
          {
            type: "create_relation",
            from_entity_id: from.id,
            to_entity_id: to.id,
            relation_type: "REQUIRES"
          }
        ]
      )

      expect(result).to include(
        status: "possible_duplicate",
        kind: "relation",
        operation_index: 1
      )
      expect(result.dig(:candidates, 0, :relation_id)).to eq(existing.id)
      expect(MemoryEntity.find_by(name: "Must also not persist")).to be_nil
    end

    it "canonicalizes entity types before duplicate probing" do
      existing = MemoryEntity.create!(name: "Mapped project", entity_type: "Project")
      EntityTypeMapping.create!(canonical_type: "Project", variant: "workspace")
      candidate = Struct.new(:entity, :distance).new(existing, 0.1)

      expect(vector_strategy).to receive(:search)
        .with("Project: Mapped workspace", limit: 1, entity_type: "Project")
        .and_return([ candidate ])

      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Mapped workspace", entity_type: "workspace" }
        ]
      )

      expect(result[:status]).to eq("possible_duplicate")
    end

    it "returns non-blocking close-match type hints" do
      result = described_class.call(
        operations: [
          { type: "create_entity", name: "Misspelled type", entity_type: "Projct" }
        ]
      )

      expect(result.dig(:results, 0, :result, :type_hint)).to eq(
        submitted: "Projct",
        suggested: "Project"
      )
      expect(MemoryEntity.find_by!(name: "Misspelled type").entity_type).to eq("Projct")
    end

    it "validates operation type and batch size" do
      expect {
        described_class.call(operations: [ { type: "unknown" } ])
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /unknown type/)

      operations = 51.times.map { |index| { type: "create_entity", name: "E#{index}", entity_type: "Task" } }
      expect {
        described_class.call(operations: operations)
      }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /at most 50/)
    end
  end

  describe "project-scoped names" do
    it "create_entity inserts inside the context scope even when a global namesake exists" do
      project = MemoryEntity.create!(name: "CtxProj", entity_type: "Project")
      global = MemoryEntity.create!(name: "Shared", entity_type: "Task")

      result = described_class.call(
        operations: [ { type: "create_entity", name: "Shared", entity_type: "Task" } ],
        project_id: project.id
      )

      expect(result[:status]).to eq("ok")
      scoped = MemoryEntity.find_by!(name: "Shared", project_id: project.id)
      expect(scoped.id).not_to eq(global.id)
      expect(MemoryRelation.exists?(from_entity: scoped, to_entity: project,
                                    relation_type: "part_of")).to be true
    end

    it "create_relation part_of stamps an unrooted entity into the parent's scope" do
      project = MemoryEntity.create!(name: "CtxProj2", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "Lonely", entity_type: "Task")

      described_class.call(
        operations: [ { type: "create_relation", from_entity_id: orphan.id,
                        to_entity_id: project.id, relation_type: "part_of" } ]
      )

      expect(orphan.reload.project_id).to eq(project.id)
    end

    it "maps a membership LockTimeout to a retryable OperationFailed" do
      project = MemoryEntity.create!(name: "CtxProj3", entity_type: "Project")
      orphan = MemoryEntity.create!(name: "Lonely2", entity_type: "Task")
      allow(ProjectMembership).to receive(:sync!).and_raise(ProjectMembership::LockTimeout, "busy")

      begin
        described_class.call(
          operations: [ { type: "create_relation", from_entity_id: orphan.id,
                          to_entity_id: project.id, relation_type: "part_of" } ]
        )
        flunk "expected OperationFailed"
      rescue McpGraphMemErrors::OperationFailed => e
        expect(e.next_move).to match(/retry shortly/)
        expect(e.next_move).not_to match(/[Rr]ename/)
      end
    end
  end

  describe "on_duplicate: skip (PR-2 §2.8)" do
    it "lists stored and in-batch duplicates under skipped and creates the rest" do
      stored = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
      stored.memory_observations.create!(content: "Alpha Service runs nightly")

      result = described_class.call(
        on_duplicate: "skip",
        operations: [
          { type: "create_entity", name: "Alpha Service", entity_type: "Service" },
          { type: "create_entity", name: "SynthWidget", entity_type: "Component" },
          { type: "create_entity", name: "SynthWidget", entity_type: "Component" },
          { type: "create_observation", entity_id: stored.id, text_content: "Alpha Service runs nightly" },
          { type: "create_observation", entity_id: stored.id, text_content: "Alpha Service has a cache" }
        ]
      )

      expect(result[:status]).to eq("ok")
      expect(result[:skipped]).to contain_exactly(
        include(index: 0, reason: "exists", existing_id: stored.id),
        include(index: 2, reason: "duplicate_in_batch"),
        include(index: 3, reason: "exists")
      )
      expect(result[:summary]).to include(entities_created: 1, observations_created: 1, skipped: 3)
      expect(MemoryEntity.where(name: "SynthWidget").count).to eq(1)
      expect(result[:next_move]).to include("Skipped 3 duplicate(s)")
    end

    it "also skips the operations that name a skipped similar entity, and writes the rest" do
      stored = MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")
      similar_hit = Struct.new(:entity, :distance).new(stored, 0.01)
      allow(vector_strategy).to receive(:search) do |query, **|
        query.include?("Alpha Svc") ? [ similar_hit ] : []
      end

      result = described_class.call(
        on_duplicate: "skip",
        operations: [
          { type: "create_entity", name: "Alpha Svc", entity_type: "Service" },
          { type: "create_observation", entity_name: "Alpha Svc", text_content: "Alpha Svc runs nightly" },
          { type: "create_relation", from_entity_id: "alpha svc", to_entity_id: "SynthWidget", relation_type: "depends_on" },
          { type: "create_entity", name: "SynthWidget", entity_type: "Component" },
          { type: "create_observation", entity_name: "SynthWidget", text_content: "SynthWidget renders charts" }
        ]
      )

      expect(result[:status]).to eq("ok")
      expect(result[:skipped]).to contain_exactly(
        include(index: 0, reason: "similar", existing_id: stored.id),
        include(index: 1, reason: "depends_on_skipped"),
        include(index: 2, reason: "depends_on_skipped")
      )
      expect(result[:summary]).to include(entities_created: 1, observations_created: 1, relations_created: 0, skipped: 3)
      expect(MemoryEntity.find_by!(name: "SynthWidget").memory_observations.pluck(:content)).to eq([ "SynthWidget renders charts" ])
      expect(MemoryEntity.where(name: "Alpha Svc")).to be_empty
      expect(result[:next_move]).to include("duplicate(s) or dependent operation(s)")
    end

    it "keeps rejecting by default, with no skipped list" do
      MemoryEntity.create!(name: "Alpha Service", entity_type: "Service")

      result = described_class.call(operations: [ { type: "create_entity", name: "Alpha Service", entity_type: "Service" } ])

      expect(result).to include(status: "possible_duplicate", reason: "same_name")
      expect(result).not_to have_key(:skipped)
    end

    it "refuses an unknown on_duplicate mode" do
      expect { described_class.call(operations: [], on_duplicate: "merge") }
        .to raise_error(FastMcp::Tool::InvalidArgumentsError, /on_duplicate must be one of/)
    end
  end
end
