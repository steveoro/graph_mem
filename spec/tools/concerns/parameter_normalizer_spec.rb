# frozen_string_literal: true

require "rails_helper"

RSpec.describe ParameterNormalizer do
  describe ".normalize" do
    describe "camelCase to snake_case conversion" do
      it "converts top-level camelCase keys" do
        result = described_class.normalize("create_entity", {
          entityType: "Project",
          name: "Test"
        })
        expect(result[:entity_type]).to eq("Project")
        expect(result[:name]).to eq("Test")
        expect(result).not_to have_key(:entityType)
      end

      it "converts nested camelCase keys inside arrays" do
        result = described_class.normalize("bulk_update", {
          entities: [ { entityType: "Task", name: "T1" } ]
        })
        expect(result[:entities].first[:entity_type]).to eq("Task")
      end

      it "converts deeply nested keys" do
        result = described_class.normalize("create_relation", {
          fromEntityId: 1,
          toEntityId: 2,
          relationType: "depends_on"
        })
        expect(result[:from_entity_id]).to eq(1)
        expect(result[:to_entity_id]).to eq(2)
        expect(result[:relation_type]).to eq("depends_on")
      end

      it "leaves already snake_case keys unchanged" do
        result = described_class.normalize("create_entity", {
          entity_type: "Project",
          name: "Test"
        })
        expect(result[:entity_type]).to eq("Project")
        expect(result[:name]).to eq("Test")
      end

      it "handles search_subgraph camelCase params" do
        result = described_class.normalize("search_subgraph", {
          query: "test",
          searchInName: true,
          searchInType: false,
          perPage: 10
        })
        expect(result[:search_in_name]).to eq(true)
        expect(result[:search_in_type]).to eq(false)
        expect(result[:per_page]).to eq(10)
      end
    end

    describe "field aliases" do
      it "converts content to text_content" do
        result = described_class.normalize("create_observation", {
          entity_id: 1,
          content: "some observation"
        })
        expect(result[:text_content]).to eq("some observation")
        expect(result).not_to have_key(:content)
      end

      it "does not overwrite text_content when both are present" do
        result = described_class.normalize("create_observation", {
          entity_id: 1,
          text_content: "canonical",
          content: "alias"
        })
        expect(result[:text_content]).to eq("canonical")
      end
    end

    describe "entity name resolution" do
      let!(:project) { MemoryEntity.create!(name: "MyProject", entity_type: "Project") }
      let!(:task) { MemoryEntity.create!(name: "MyTask", entity_type: "Task") }

      it "resolves entity_name to entity_id" do
        result = described_class.normalize("create_observation", {
          entity_name: "MyProject",
          text_content: "fact"
        })
        expect(result[:entity_id]).to eq(project.id)
        expect(result).not_to have_key(:entity_name)
      end

      it "resolves from_entity and to_entity names for relations" do
        result = described_class.normalize("create_relation", {
          from_entity: "MyProject",
          to_entity: "MyTask",
          relation_type: "depends_on"
        })
        expect(result[:from_entity_id]).to eq(project.id)
        expect(result[:to_entity_id]).to eq(task.id)
      end

      it "resolves from/to shorthand names for relations" do
        result = described_class.normalize("create_relation", {
          from: "MyProject",
          to: "MyTask",
          relation_type: "depends_on"
        })
        expect(result[:from_entity_id]).to eq(project.id)
        expect(result[:to_entity_id]).to eq(task.id)
      end

      it "resolves string values in entity_id fields" do
        result = described_class.normalize("set_context", {
          entity_id: "MyProject"
        })
        expect(result[:entity_id]).to eq(project.id)
      end

      it "resolves string values in from_entity_id/to_entity_id fields" do
        result = described_class.normalize("create_relation", {
          from_entity_id: "MyProject",
          to_entity_id: "MyTask",
          relation_type: "part_of"
        })
        expect(result[:from_entity_id]).to eq(project.id)
        expect(result[:to_entity_id]).to eq(task.id)
      end

      it "does not resolve entity_name when entity_id is already set" do
        result = described_class.normalize("create_observation", {
          entity_id: 999,
          entity_name: "MyProject",
          text_content: "fact"
        })
        expect(result[:entity_id]).to eq(999)
      end

      it "raises InvalidArgumentsError when entity name is not found" do
        expect {
          described_class.normalize("set_context", {
            entity_name: "NonExistent"
          })
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Entity not found by name/)
      end

      it "raises InvalidArgumentsError when string entity_id is not found" do
        expect {
          described_class.normalize("set_context", {
            entity_id: "NonExistent"
          })
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Entity not found by name/)
      end

      it "passes through integer entity_id unchanged" do
        result = described_class.normalize("get_entity", { entity_id: 42 })
        expect(result[:entity_id]).to eq(42)
      end
    end

    describe "bulk_update operations array" do
      let!(:project) { MemoryEntity.create!(name: "OpsProject", entity_type: "Project") }

      it "converts operations array into entities/observations/relations" do
        result = described_class.normalize("bulk_update", {
          operations: [
            { type: "create_entity", name: "New Entity", entity_type: "Task" },
            { type: "create_observation", entity_id: project.id, text_content: "a fact" },
            { type: "create_relation", from_entity_id: project.id, to_entity_id: project.id, relation_type: "relates_to" }
          ]
        })

        expect(result[:entities].length).to eq(1)
        expect(result[:entities].first[:name]).to eq("New Entity")
        expect(result[:observations].length).to eq(1)
        expect(result[:observations].first[:text_content]).to eq("a fact")
        expect(result[:relations].length).to eq(1)
        expect(result[:relations].first[:relation_type]).to eq("relates_to")
        expect(result).not_to have_key(:operations)
      end

      it "handles camelCase inside operations" do
        result = described_class.normalize("bulk_update", {
          operations: [
            { type: "create_entity", name: "Camel", entityType: "Task" }
          ]
        })

        expect(result[:entities].first[:entity_type]).to eq("Task")
      end

      it "handles entity names inside operations" do
        result = described_class.normalize("bulk_update", {
          operations: [
            { type: "create_observation", entity_name: "OpsProject", text_content: "via name" }
          ]
        })

        expect(result[:observations].first[:entity_id]).to eq(project.id)
      end

      it "expands contents array into multiple observation entries" do
        result = described_class.normalize("bulk_update", {
          operations: [
            { type: "create_observation", entity_id: project.id, contents: %w[fact1 fact2 fact3] }
          ]
        })

        expect(result[:observations].length).to eq(3)
        expect(result[:observations].map { |o| o[:text_content] }).to eq(%w[fact1 fact2 fact3])
      end

      it "handles entity type aliases: entity, observation, relation" do
        result = described_class.normalize("bulk_update", {
          operations: [
            { type: "entity", name: "E1", entity_type: "Task" },
            { type: "observation", entity_id: project.id, text_content: "obs" },
            { type: "relation", from_entity_id: project.id, to_entity_id: project.id, relation_type: "relates_to" }
          ]
        })

        expect(result[:entities].length).to eq(1)
        expect(result[:observations].length).to eq(1)
        expect(result[:relations].length).to eq(1)
      end

      it "merges operations with existing arrays" do
        result = described_class.normalize("bulk_update", {
          entities: [ { name: "Pre-existing", entity_type: "Project" } ],
          operations: [
            { type: "create_entity", name: "From Ops", entity_type: "Task" }
          ]
        })

        expect(result[:entities].length).to eq(2)
      end

      it "does not process operations for non-bulk_update tools" do
        result = described_class.normalize("create_entity", {
          operations: [ { type: "create_entity", name: "X", entity_type: "Y" } ],
          name: "Real",
          entity_type: "Project"
        })

        expect(result).to have_key(:operations)
        expect(result[:name]).to eq("Real")
      end

      it "ignores operations when it's not an array" do
        result = described_class.normalize("bulk_update", {
          operations: "not an array",
          entities: [ { name: "E1", entity_type: "Task" } ]
        })

        expect(result[:entities].length).to eq(1)
      end
    end

    describe "standard server format compatibility" do
      let!(:project) { MemoryEntity.create!(name: "CoachInABox", entity_type: "Project") }

      it "handles the exact format LLMs commonly generate" do
        result = described_class.normalize("bulk_update", {
          operations: [
            {
              type: "create_entity",
              name: "Docker Builder Containers",
              entity_type: "Configuration",
              aliases: "builder containers,docker builder"
            },
            {
              type: "create_observation",
              entity_name: "CoachInABox",
              contents: [
                "Two builder Dockerfiles based on ruby:2.7.4",
                "Builder containers use Docker socket mounting"
              ]
            },
            {
              type: "create_relation",
              from_entity: "Docker Builder Containers",
              to_entity: "CoachInABox",
              relation_type: "part_of"
            }
          ]
        })

        expect(result[:entities].length).to eq(1)
        expect(result[:entities].first[:name]).to eq("Docker Builder Containers")
        expect(result[:entities].first[:aliases]).to eq("builder containers,docker builder")

        expect(result[:observations].length).to eq(2)
        expect(result[:observations].first[:entity_id]).to eq(project.id)
        expect(result[:observations].first[:text_content]).to eq("Two builder Dockerfiles based on ruby:2.7.4")

        # from_entity "Docker Builder Containers" can't resolve yet (created in same call),
        # so from_entity_id is not set (lenient mode). to_entity "CoachInABox" should resolve.
        expect(result[:relations].first[:to_entity_id]).to eq(project.id)
        expect(result[:relations].first[:from_entity_id]).to be_nil
      end
    end

    describe "edge cases" do
      it "handles empty params" do
        result = described_class.normalize("get_context", {})
        expect(result).to eq({})
      end

      it "handles nil values gracefully" do
        result = described_class.normalize("create_entity", {
          name: "Test",
          entity_type: "Project",
          aliases: nil,
          description: nil
        })
        expect(result[:name]).to eq("Test")
        expect(result[:aliases]).to be_nil
      end

      it "handles empty string entity_name without error" do
        result = described_class.normalize("create_observation", {
          entity_id: 1,
          entity_name: "",
          text_content: "fact"
        })
        expect(result[:entity_id]).to eq(1)
      end
    end
  end
end
