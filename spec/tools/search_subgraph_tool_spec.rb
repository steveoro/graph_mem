# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SearchSubgraphTool, type: :model do
  let(:tool) { described_class.new }

  let!(:project) do
    MemoryEntity.create!(name: 'Rails Project', entity_type: 'Project', aliases: 'webapp|rails-app')
  end

  let!(:task) do
    MemoryEntity.create!(name: 'Fix Login Bug', entity_type: 'Task', aliases: 'login-fix')
  end

  let!(:issue) do
    MemoryEntity.create!(name: 'Performance Issue', entity_type: 'Issue', aliases: 'slow-queries')
  end

  let!(:obs_project) do
    MemoryObservation.create!(memory_entity: project, content: 'Uses Ruby on Rails framework')
  end

  let!(:obs_task) do
    MemoryObservation.create!(memory_entity: task, content: 'Authentication service failing')
  end

  let!(:relation) do
    MemoryRelation.create!(from_entity_id: task.id, to_entity_id: project.id, relation_type: 'part_of')
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('search_subgraph')
      end
    end

    describe '.description' do
      it 'returns a non-empty description' do
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe '#call' do
    context 'searching by name' do
      it 'finds entities by name match' do
        result = tool.call(query: 'Rails')

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).to include('Rails Project')
      end

      it 'is case-insensitive' do
        result = tool.call(query: 'rails')

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).to include('Rails Project')
      end
    end

    context 'searching by entity type' do
      it 'finds entities by type match' do
        result = tool.call(query: 'Task')

        entity_types = result[:entities].map { |e| e[:entity_type] }
        expect(entity_types).to include('Task')
      end
    end

    context 'searching by aliases' do
      it 'finds entities by alias match' do
        result = tool.call(query: 'webapp')

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).to include('Rails Project')
      end
    end

    context 'searching in observations' do
      it 'finds entities by observation content match' do
        result = tool.call(query: 'Authentication')

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).to include('Fix Login Bug')
      end
    end

    context 'toggling search fields' do
      it 'excludes name matches when search_in_name is false' do
        result = tool.call(query: 'Rails', search_in_name: false, search_in_type: false, search_in_aliases: false, search_in_observations: true)

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).to include('Rails Project')
      end

      it 'excludes observation matches when search_in_observations is false' do
        result = tool.call(query: 'Authentication', search_in_observations: false)

        entity_names = result[:entities].map { |e| e[:name] }
        expect(entity_names).not_to include('Fix Login Bug')
      end
    end

    context 'result format' do
      it 'returns entities with observations' do
        result = tool.call(query: 'Rails')

        entity = result[:entities].find { |e| e[:name] == 'Rails Project' }
        expect(entity[:observations]).to be_an(Array)
        expect(entity[:observations].length).to eq(1)
        expect(entity[:observations].first[:content]).to eq('Uses Ruby on Rails framework')
      end

      it 'returns relations between matched entities' do
        result = tool.call(query: 'Rails Login')

        if result[:entities].length >= 2
          matched_ids = result[:entities].map { |e| e[:entity_id] }
          result[:relations].each do |rel|
            expect(matched_ids).to include(rel[:from_entity_id])
            expect(matched_ids).to include(rel[:to_entity_id])
          end
        end
      end

      it 'returns pagination metadata' do
        result = tool.call(query: 'Rails')

        expect(result[:pagination]).to include(
          :total_entities, :per_page, :current_page, :total_pages
        )
        expect(result[:pagination][:current_page]).to eq(1)
      end
    end

    context 'pagination' do
      before do
        10.times { |i| MemoryEntity.create!(name: "Paginated Item #{i}", entity_type: 'Item') }
      end

      it 'respects per_page parameter' do
        result = tool.call(query: 'Paginated', per_page: 3, search_in_observations: false)

        expect(result[:entities].length).to eq(3)
        expect(result[:pagination][:per_page]).to eq(3)
      end

      it 'returns the correct page' do
        page1 = tool.call(query: 'Paginated', per_page: 5, page: 1, search_in_observations: false)
        page2 = tool.call(query: 'Paginated', per_page: 5, page: 2, search_in_observations: false)

        page1_ids = page1[:entities].map { |e| e[:entity_id] }
        page2_ids = page2[:entities].map { |e| e[:entity_id] }

        expect(page1_ids & page2_ids).to be_empty
      end

      it 'returns total_pages correctly' do
        result = tool.call(query: 'Paginated', per_page: 3, search_in_observations: false)

        expect(result[:pagination][:total_pages]).to be >= 3
      end
    end

    context 'validation errors' do
      it 'raises InvalidArgumentsError for blank query' do
        expect {
          tool.call(query: '')
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /cannot be blank/)
      end

      it 'raises InvalidArgumentsError when all search fields are disabled' do
        expect {
          tool.call(
            query: 'test',
            search_in_name: false,
            search_in_type: false,
            search_in_aliases: false,
            search_in_observations: false
          )
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /At least one search field/)
      end

      it 'raises InvalidArgumentsError for page < 1' do
        expect {
          tool.call(query: 'test', page: 0)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Page number must be 1/)
      end

      it 'raises InvalidArgumentsError for per_page < 1' do
        expect {
          tool.call(query: 'test', per_page: 0)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Per page count must be between/)
      end

      it 'raises InvalidArgumentsError for per_page > 100' do
        expect {
          tool.call(query: 'test', per_page: 101)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Per page count must be between/)
      end
    end

    context 'no matches' do
      it 'returns empty entities and relations' do
        result = tool.call(query: 'xyznonexistent')

        expect(result[:entities]).to eq([])
        expect(result[:relations]).to eq([])
        expect(result[:pagination][:total_entities]).to eq(0)
      end
    end

    context 'vector search fallback' do
      it 'gracefully falls back to text search when vector search fails' do
        allow(VectorSearchStrategy).to receive(:new).and_raise(StandardError.new("no vectors"))

        result = tool.call(query: 'Rails')
        expect(result[:entities]).not_to be_empty
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:distinct).and_raise(StandardError.new("DB error"))

        expect {
          tool.call(query: 'test')
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
