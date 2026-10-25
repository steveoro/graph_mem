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
        result = described_class.normalize("graph_write", {
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

    describe "search paging aliases" do
      it "maps limit to per_page for the canonical search tool" do
        result = described_class.normalize("search", { query: "test", limit: 12 })

        expect(result).to include(query: "test", per_page: 12)
        expect(result).not_to have_key(:limit)
      end

      it "prefers per_page when both paging names are present" do
        result = described_class.normalize("search", { query: "test", limit: 12, perPage: 7 })

        expect(result[:per_page]).to eq(7)
        expect(result).not_to have_key(:limit)
      end

      it "does not rewrite limit on the legacy search_entities tool" do
        result = described_class.normalize("search_entities", { query: "test", limit: 12 })

        expect(result[:limit]).to eq(12)
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

      it "prefers the context project's entity over a global namesake" do
        scoped = MemoryEntity.create!(name: "MyTask", entity_type: "Task", project_id: project.id)
        result = described_class.normalize("create_observation", {
          entity_name: "MyTask",
          text_content: "fact"
        }, project_id: project.id)
        expect(result[:entity_id]).to eq(scoped.id)
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

      it "resolves string values in start_entity_id fields" do
        result = described_class.normalize("traverse_graph", {
          start_entity_id: "MyProject"
        })
        expect(result[:start_entity_id]).to eq(project.id)
      end

      it "wraps the get_entities entity_id alias and resolves names in arrays" do
        single = described_class.normalize("get_entities", { entity_id: "MyProject" })
        multiple = described_class.normalize(
          "get_entities",
          { entity_ids: [ "MyTask", project.id ] }
        )

        expect(single).to eq(entity_ids: [ project.id ])
        expect(multiple[:entity_ids]).to eq([ task.id, project.id ])
      end

      it "raises a canonical not-found error for unresolved get_entities names" do
        expect {
          described_class.normalize("get_entities", { entity_ids: [ "Missing" ] })
        }.to raise_error(McpGraphMemErrors::ResourceNotFound) do |error|
          expect(error.next_move).to include("search")
          expect(error.next_move).to include("get_entities")
        end
      end

      it "does not resolve entity_name when entity_id is already set" do
        result = described_class.normalize("create_observation", {
          entity_id: 999,
          entity_name: "MyProject",
          text_content: "fact"
        })
        expect(result[:entity_id]).to eq(999)
      end

      it "raises ResourceNotFound when entity name is not found" do
        expect {
          described_class.normalize("set_context", {
            entity_name: "NonExistent"
          })
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /Entity not found by name/) do |error|
          expect(error.next_move).to match(/search/)
          expect(error.next_move).to match(/known id/)
        end
      end

      it "raises ResourceNotFound when string entity_id is not found" do
        expect {
          described_class.normalize("set_context", {
            entity_id: "NonExistent"
          })
        }.to raise_error(McpGraphMemErrors::ResourceNotFound, /Entity not found by name/) do |error|
          expect(error.next_move).to match(/search/)
          expect(error.next_move).to match(/known id/)
        end
      end

      it "passes through integer entity_id unchanged" do
        result = described_class.normalize("get_entity", { entity_id: 42 })
        expect(result[:entity_id]).to eq(42)
      end
    end

    describe "canonical graph mutation operations" do
      it "normalizes graph_write type and field aliases" do
        result = described_class.normalize(
          "graph_write",
          {
            operations: [
              { type: "observation", entityId: 7, content: "Fact" },
              { type: "relation", from: "A", to: "B", relationType: "part_of" }
            ]
          }
        )

        expect(result[:operations]).to eq(
          [
            { type: "create_observation", entity_id: 7, text_content: "Fact" },
            { type: "create_relation", from_entity_id: "A", to_entity_id: "B", relation_type: "part_of" }
          ]
        )
      end

      it "expands graph_write observation contents" do
        result = described_class.normalize(
          "graph_write",
          { operations: [ { type: "create_observation", entity_id: 7, contents: %w[One Two] } ] }
        )

        expect(result[:operations]).to eq(
          [
            { type: "create_observation", entity_id: 7, text_content: "One" },
            { type: "create_observation", entity_id: 7, text_content: "Two" }
          ]
        )
      end

      it "normalizes graph_edit and graph_delete camelCase fields" do
        edit = described_class.normalize(
          "graph_edit",
          { operations: [ { type: "update_observation", observationId: 4, content: "Changed" } ] }
        )
        delete = described_class.normalize(
          "graph_delete",
          { operations: [ { type: "merge_entities", sourceEntityId: 2, targetEntityId: 3 } ] }
        )

        expect(edit[:operations].first).to include(observation_id: 4, text_content: "Changed")
        expect(delete[:operations].first).to include(source_entity_id: 2, target_entity_id: 3)
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
