# frozen_string_literal: true

require "rails_helper"

RSpec.describe GetGraphStatsTool, type: :model do
  let(:tool) { described_class.new }

  describe "class methods" do
    describe ".tool_name" do
      it "returns the correct tool name" do
        expect(described_class.tool_name).to eq("get_graph_stats")
      end
    end

    describe ".description" do
      it "returns a non-empty description" do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe "#input_schema_to_json" do
    it "returns an empty-properties schema (no arguments)" do
      schema = tool.input_schema_to_json
      expect(schema[:type]).to eq("object")
      expect(schema[:properties]).to eq({})
      expect(schema[:required]).to eq([])
    end
  end

  describe "#call" do
    let!(:project) { MemoryEntity.create!(name: "StatsProject", entity_type: "Project") }
    let!(:task) { MemoryEntity.create!(name: "StatsTask", entity_type: "Task") }
    let!(:obs1) { MemoryObservation.create!(memory_entity: project, content: "obs 1") }
    let!(:obs2) { MemoryObservation.create!(memory_entity: project, content: "obs 2") }
    let!(:relation) { MemoryRelation.create!(from_entity: project, to_entity: task, relation_type: "part_of") }

    it "returns the expected top-level keys" do
      result = tool.call
      expect(result).to have_key(:totals)
      expect(result).to have_key(:entity_type_distribution)
      expect(result).to have_key(:orphan_count)
      expect(result).to have_key(:stale_count)
      expect(result).to have_key(:most_connected)
      expect(result).to have_key(:recently_updated)
      expect(result).to have_key(:latest_maintenance)
    end

    describe "totals" do
      it "includes correct entity count" do
        result = tool.call
        expect(result[:totals][:entities]).to eq(MemoryEntity.count)
      end

      it "includes correct observation count" do
        result = tool.call
        expect(result[:totals][:observations]).to eq(MemoryObservation.count)
      end

      it "includes correct relation count" do
        result = tool.call
        expect(result[:totals][:relations]).to eq(MemoryRelation.count)
      end

      it "includes audit_logs count" do
        result = tool.call
        expect(result[:totals][:audit_logs]).to be_a(Integer)
      end
    end

    describe "entity_type_distribution" do
      it "returns a hash of type => count" do
        result = tool.call
        dist = result[:entity_type_distribution]
        expect(dist).to be_a(Hash)
        expect(dist["Project"]).to be >= 1
        expect(dist["Task"]).to be >= 1
      end
    end

    describe "orphan_count" do
      it "counts entities with no observations and no relations" do
        orphan = MemoryEntity.create!(name: "OrphanForStats", entity_type: "Task")
        result = tool.call
        expect(result[:orphan_count]).to be >= 1
      end

      it "does not count entities with observations" do
        result_before = tool.call[:orphan_count]
        entity_with_obs = MemoryEntity.create!(name: "HasObs", entity_type: "Task")
        MemoryObservation.create!(memory_entity: entity_with_obs, content: "not orphan")
        result_after = tool.call[:orphan_count]
        expect(result_after).to eq(result_before)
      end
    end

    describe "stale_count" do
      it "counts entities not updated in over 6 months" do
        stale = MemoryEntity.create!(name: "StaleEntity", entity_type: "Task")
        stale.update_columns(updated_at: 7.months.ago)
        result = tool.call
        expect(result[:stale_count]).to be >= 1
      end

      it "does not count recently updated entities" do
        result = tool.call
        fresh_entities = MemoryEntity.where("updated_at >= ?", 6.months.ago).count
        expect(result[:stale_count]).to be < MemoryEntity.count if fresh_entities > 0
      end
    end

    describe "most_connected" do
      it "returns an array of entity hashes" do
        result = tool.call
        expect(result[:most_connected]).to be_an(Array)
        first = result[:most_connected].first
        next skip("no connected entities") unless first
        expect(first).to have_key(:id)
        expect(first).to have_key(:name)
        expect(first).to have_key(:entity_type)
        expect(first).to have_key(:relation_count)
      end

      it "includes entities involved in relations" do
        result = tool.call
        ids = result[:most_connected].map { |e| e[:id] }
        expect(ids).to include(project.id)
      end

      it "returns at most 10 entries" do
        result = tool.call
        expect(result[:most_connected].size).to be <= 10
      end
    end

    describe "recently_updated" do
      it "returns an array of entity hashes with ISO timestamps" do
        result = tool.call
        expect(result[:recently_updated]).to be_an(Array)
        first = result[:recently_updated].first
        expect(first).to have_key(:id)
        expect(first).to have_key(:name)
        expect(first).to have_key(:entity_type)
        expect(first).to have_key(:updated_at)
        expect { Time.iso8601(first[:updated_at]) }.not_to raise_error
      end

      it "returns at most 10 entries" do
        result = tool.call
        expect(result[:recently_updated].size).to be <= 10
      end

      it "orders by most recently updated first" do
        result = tool.call
        timestamps = result[:recently_updated].map { |e| Time.iso8601(e[:updated_at]) }
        expect(timestamps).to eq(timestamps.sort.reverse)
      end
    end

    describe "latest_maintenance" do
      it "returns empty hash when no reports exist" do
        MaintenanceReport.delete_all
        result = tool.call
        expect(result[:latest_maintenance]).to eq({})
      end

      it "returns report summaries when reports exist" do
        MaintenanceReport.create!(report_type: "orphans", data: { count: 3, entities: [] })
        result = tool.call
        expect(result[:latest_maintenance]).to have_key("orphans")
        expect(result[:latest_maintenance]["orphans"][:count]).to eq(3)
        expect(result[:latest_maintenance]["orphans"]).to have_key(:created_at)
      end
    end

    describe "error handling" do
      it "raises InternalServerError on unexpected errors" do
        allow(MemoryEntity).to receive(:count).and_raise(StandardError.new("DB error"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError, /Failed to compute graph stats/)
      end
    end
  end
end
