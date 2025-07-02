# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SearchEntitiesTool, type: :model do
  let(:tool) { described_class.new }

  # Setup test data
  let!(:apple_entity) do
    MemoryEntity.create!(
      name: 'Apple Pie',
      entity_type: 'Dessert',
      aliases: 'apple dessert, fruit pie'
    )
  end

  let!(:banana_entity) do
    MemoryEntity.create!(
      name: 'Banana Bread',
      entity_type: 'Baked Good',
      aliases: 'banana cake, quick bread'
    )
  end

  let!(:apple_juice_entity) do
    MemoryEntity.create!(
      name: 'Apple Juice',
      entity_type: 'Beverage',
      aliases: 'fruit juice, apple drink'
    )
  end

  describe 'class methods' do
    describe '.tool_name' do
      it 'returns the correct tool name' do
        expect(described_class.tool_name).to eq('search_entities')
      end
    end
  end

  describe '#input_schema_to_json' do
    it 'returns the correct schema' do
      schema = tool.input_schema_to_json
      
      expect(schema).to eq({
        type: "object",
        properties: { query: { type: "string", description: "The search term to find within entity names or aliases. Multiple words will be tokenized for better matching (case-insensitive)." } },
        required: [ "query" ]
      })
    end
  end

  describe '#call' do
    context 'with valid query' do
      it 'returns search results with relevance scoring' do
        results = tool.call(query: 'apple')
        
        expect(results).to be_an(Array)
        expect(results.length).to eq(3)
        
        # Check result format
        result = results.first
        expect(result).to include(
          :entity_id,
          :name,
          :entity_type,
          :aliases,
          :created_at,
          :updated_at,
          :relevance_score,
          :matched_fields
        )
        
        expect(result[:entity_id]).to be_a(Integer)
        expect(result[:relevance_score]).to be_a(Integer)
        expect(result[:matched_fields]).to be_an(Array)
      end

      it 'returns results ordered by relevance' do
        results = tool.call(query: 'apple')
        
        # Results should be ordered by score
        scores = results.map { |r| r[:relevance_score] }
        expect(scores).to eq(scores.sort.reverse)
      end

      it 'handles multi-token queries' do
        results = tool.call(query: 'apple pie')
        
        expect(results).to be_an(Array)
        expect(results.length).to be >= 1
        
        # Apple Pie should be the top result (matches both tokens)
        expect(results.first[:name]).to eq('Apple Pie')
        expect(results.first[:relevance_score]).to be > 0
      end

      it 'is case insensitive' do
        lowercase_results = tool.call(query: 'apple')
        uppercase_results = tool.call(query: 'APPLE')
        
        expect(lowercase_results.length).to eq(uppercase_results.length)
        expect(lowercase_results.map { |r| r[:entity_id] }.sort).to eq(
          uppercase_results.map { |r| r[:entity_id] }.sort
        )
      end

      it 'searches in aliases' do
        results = tool.call(query: 'fruit')
        
        expect(results.length).to eq(2)
        entity_names = results.map { |r| r[:name] }
        expect(entity_names).to contain_exactly('Apple Pie', 'Apple Juice')
        
        # Check that matched_fields includes aliases
        results.each do |result|
          expect(result[:matched_fields]).to include('aliases')
        end
      end

      it 'includes all required fields in output' do
        results = tool.call(query: 'apple')
        result = results.first
        
        expect(result[:entity_id]).to eq(apple_entity.id)
        expect(result[:name]).to eq(apple_entity.name)
        expect(result[:entity_type]).to eq(apple_entity.entity_type)
        expect(result[:aliases]).to eq(apple_entity.aliases)
        expect(result[:created_at]).to eq(apple_entity.created_at.iso8601)
        expect(result[:updated_at]).to eq(apple_entity.updated_at.iso8601)
      end
    end

    context 'with no matches' do
      it 'returns empty array when no entities match' do
        results = tool.call(query: 'chocolate')
        expect(results).to eq([])
      end
    end

    context 'with empty query' do
      it 'returns empty array for empty string' do
        results = tool.call(query: '')
        expect(results).to eq([])
      end

      it 'returns empty array for whitespace-only string' do
        results = tool.call(query: '   ')
        expect(results).to eq([])
      end
    end

    context 'error handling' do
      it 'raises InternalServerError on database errors' do
        allow(EntitySearchStrategy).to receive(:new).and_raise(StandardError.new('Database error'))
        
        expect {
          tool.call(query: 'apple')
        }.to raise_error(McpGraphMemErrors::InternalServerError, /An internal server error occurred in SearchEntitiesTool/)
      end

      it 'logs errors appropriately' do
        allow(EntitySearchStrategy).to receive(:new).and_raise(StandardError.new('Test error'))
        allow(Rails.logger).to receive(:error)
        
        expect {
          tool.call(query: 'apple')
        }.to raise_error(McpGraphMemErrors::InternalServerError)
        
        expect(Rails.logger).to have_received(:error).with(/InternalServerError in SearchEntitiesTool: Test error/)
      end
    end

    context 'integration with EntitySearchStrategy' do
      it 'uses EntitySearchStrategy for search' do
        strategy_instance = instance_double(EntitySearchStrategy)
        allow(EntitySearchStrategy).to receive(:new).and_return(strategy_instance)
        allow(strategy_instance).to receive(:search).with('apple').and_return([])
        
        tool.call(query: 'apple')
        
        expect(EntitySearchStrategy).to have_received(:new)
        expect(strategy_instance).to have_received(:search).with('apple')
      end

      it 'converts SearchResult objects to hash format' do
        # Mock a SearchResult
        mock_result = instance_double(EntitySearchStrategy::SearchResult)
        allow(mock_result).to receive(:to_h).and_return({
          entity_id: 1,
          name: 'Test Entity',
          entity_type: 'Test',
          aliases: 'test alias',
          created_at: Time.current.iso8601,
          updated_at: Time.current.iso8601,
          relevance_score: 10,
          matched_fields: ['name']
        })
        
        strategy_instance = instance_double(EntitySearchStrategy)
        allow(EntitySearchStrategy).to receive(:new).and_return(strategy_instance)
        allow(strategy_instance).to receive(:search).and_return([mock_result])
        
        results = tool.call(query: 'test')
        
        expect(results.length).to eq(1)
        expect(mock_result).to have_received(:to_h)
      end
    end
  end

  describe 'tool configuration' do
    it 'has the correct description' do
      expect(tool.class.description).to eq('Search for graph memory entities by name and aliases with relevance ranking.')
    end

    it 'has the correct arguments configuration' do
      # This is tested indirectly through the schema, but we can verify the tool
      # accepts the query parameter correctly
      expect { tool.call(query: 'test') }.not_to raise_error
    end
  end

  describe 'performance considerations' do
    it 'handles multiple entities efficiently' do
      # Create many entities to test performance
      50.times do |i|
        MemoryEntity.create!(
          name: "Test Entity #{i}",
          entity_type: 'Performance Test',
          aliases: "alias#{i}, test#{i}"
        )
      end
      
      start_time = Time.current
      results = tool.call(query: 'test')
      end_time = Time.current
      
      expect(results.length).to be > 0
      expect(end_time - start_time).to be < 2.0 # Should complete within 2 seconds
    end
  end
end