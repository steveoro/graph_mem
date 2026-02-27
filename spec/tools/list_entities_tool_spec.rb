# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ListEntitiesTool, type: :model do
  let(:tool) { described_class.new }

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('list_entities')
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
    context 'with no entities' do
      it 'returns empty entities array with pagination' do
        result = tool.call

        expect(result[:entities]).to eq([])
        expect(result[:pagination][:total_entities]).to eq(0)
        expect(result[:pagination][:current_page]).to eq(1)
        expect(result[:pagination][:total_pages]).to eq(1)
      end
    end

    context 'with entities' do
      before do
        5.times { |i| MemoryEntity.create!(name: "Entity #{i}", entity_type: 'Task') }
      end

      it 'returns all entities with default pagination' do
        result = tool.call

        expect(result[:entities].length).to eq(5)
        expect(result[:pagination][:total_entities]).to eq(5)
        expect(result[:pagination][:per_page]).to eq(20)
        expect(result[:pagination][:current_page]).to eq(1)
        expect(result[:pagination][:total_pages]).to eq(1)
      end

      it 'returns entities ordered by id' do
        result = tool.call
        ids = result[:entities].map { |e| e[:entity_id] }
        expect(ids).to eq(ids.sort)
      end

      it 'returns correct entity format' do
        result = tool.call
        entity = result[:entities].first

        expect(entity).to have_key(:entity_id)
        expect(entity).to have_key(:name)
        expect(entity).to have_key(:entity_type)
      end
    end

    context 'pagination' do
      before do
        25.times { |i| MemoryEntity.create!(name: "Paginated #{i}", entity_type: 'Item') }
      end

      it 'respects per_page parameter' do
        result = tool.call(per_page: 10)

        expect(result[:entities].length).to eq(10)
        expect(result[:pagination][:per_page]).to eq(10)
        expect(result[:pagination][:total_pages]).to eq(3)
      end

      it 'returns the correct page' do
        page1 = tool.call(per_page: 10, page: 1)
        page2 = tool.call(per_page: 10, page: 2)

        page1_ids = page1[:entities].map { |e| e[:entity_id] }
        page2_ids = page2[:entities].map { |e| e[:entity_id] }

        expect(page1_ids & page2_ids).to be_empty
        expect(page1_ids.max).to be < page2_ids.min
      end

      it 'returns partial last page' do
        result = tool.call(per_page: 10, page: 3)

        expect(result[:entities].length).to eq(5)
        expect(result[:pagination][:current_page]).to eq(3)
      end

      it 'returns empty entities for page beyond range' do
        result = tool.call(per_page: 10, page: 100)

        expect(result[:entities]).to eq([])
        expect(result[:pagination][:current_page]).to eq(100)
      end
    end

    context 'pagination validation' do
      it 'raises InvalidArgumentsError for page < 1' do
        expect {
          tool.call(page: 0)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Page number must be 1 or greater/)
      end

      it 'raises InvalidArgumentsError for per_page < 1' do
        expect {
          tool.call(per_page: 0)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Per page count must be between/)
      end

      it 'raises InvalidArgumentsError for per_page > 100' do
        expect {
          tool.call(per_page: 101)
        }.to raise_error(FastMcp::Tool::InvalidArgumentsError, /Per page count must be between/)
      end

      it 'accepts per_page = 1' do
        MemoryEntity.create!(name: 'Single', entity_type: 'Task')
        result = tool.call(per_page: 1)
        expect(result[:entities].length).to eq(1)
      end

      it 'accepts per_page = 100' do
        expect { tool.call(per_page: 100) }.not_to raise_error
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on unexpected errors' do
        allow(MemoryEntity).to receive(:count).and_raise(StandardError.new("DB error"))

        expect {
          tool.call
        }.to raise_error(McpGraphMemErrors::InternalServerError)
      end
    end
  end
end
