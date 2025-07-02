# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SearchEntitiesTool, type: :model do
  let(:tool) { described_class.new }

  # Setup test data with meaningful entity types
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
        properties: { query: { type: "string", description: "The search term to find within entity names, entity types, or aliases. Multiple words will be tokenized for better matching (case-insensitive)." } },
        required: [ "query" ]
      })
    end
  end

  describe '#call' do
    context 'with valid query' do
      it 'returns search results with relevance scoring' do
        results = tool.call(query: 'apple')

        expect(results).to be_an(Array)
        expect(results.length).to eq(2)

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

      it 'returns results ordered by entity_type first, then by relevance' do
        results = tool.call(query: 'apple')

        # Results should be ordered by entity_type alphabetically first
        entity_types = results.map { |r| r[:entity_type] }
        expect(entity_types).to eq([ 'Beverage', 'Dessert' ])

        # Within same entity_type, should be ordered by score
        expect(results.first[:name]).to eq('Apple Juice') # Beverage
        expect(results.second[:name]).to eq('Apple Pie') # Dessert
      end

      it 'handles entity_type queries' do
        results = tool.call(query: 'dessert')

        expect(results).to be_an(Array)
        expect(results.length).to eq(1)

        # Apple Pie should be the result
        expect(results.first[:name]).to eq('Apple Pie')
        expect(results.first[:entity_type]).to eq('Dessert')
        expect(results.first[:matched_fields]).to include('entity_type')
        expect(results.first[:relevance_score]).to be >= 15 # At least base entity_type weight
      end

      it 'handles multi-token queries across fields' do
        results = tool.call(query: 'apple dessert')

        expect(results).to be_an(Array)
        expect(results.length).to be >= 1

        # Apple Pie should be the top result (matches both: apple in name, dessert in entity_type)
        expect(results.first[:name]).to eq('Apple Pie')
        expect(results.first[:matched_fields]).to include('name', 'entity_type')
        expect(results.first[:relevance_score]).to be > 0
      end

      it 'is case insensitive' do
        lowercase_results = tool.call(query: 'dessert')
        uppercase_results = tool.call(query: 'DESSERT')

        expect(lowercase_results.length).to eq(uppercase_results.length)
        expect(lowercase_results.map { |r| r[:entity_id] }.sort).to eq(
          uppercase_results.map { |r| r[:entity_id] }.sort
        )
      end

      it 'searches in entity_type field' do
        results = tool.call(query: 'beverage')

        expect(results.length).to eq(1)
        expect(results.first[:name]).to eq('Apple Juice')
        expect(results.first[:entity_type]).to eq('Beverage')

        # Check that matched_fields includes entity_type
        expect(results.first[:matched_fields]).to include('entity_type')
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
        result = results.find { |r| r[:entity_id] == apple_entity.id }

        expect(result[:entity_id]).to eq(apple_entity.id)
        expect(result[:name]).to eq(apple_entity.name)
        expect(result[:entity_type]).to eq(apple_entity.entity_type)
        expect(result[:aliases]).to eq(apple_entity.aliases)
        expect(result[:created_at]).to eq(apple_entity.created_at.iso8601)
        expect(result[:updated_at]).to eq(apple_entity.updated_at.iso8601)
      end

      it 'prioritizes entity_type matches in scoring' do
        # Create test entities with different match types
        type_match = MemoryEntity.create!(
          name: 'Random Name',
          entity_type: 'Test Category',
          aliases: 'other'
        )
        name_match = MemoryEntity.create!(
          name: 'Test Product',
          entity_type: 'Product',
          aliases: 'other'
        )

        results = tool.call(query: 'test')

        # Should be ordered by entity_type, but type_match should have higher score
        type_result = results.find { |r| r[:entity_id] == type_match.id }
        name_result = results.find { |r| r[:entity_id] == name_match.id }

        expect(type_result[:relevance_score]).to be > name_result[:relevance_score]

      ensure
        type_match&.destroy
        name_match&.destroy
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
          entity_type: 'Test Type',
          aliases: 'test alias',
          created_at: Time.current.iso8601,
          updated_at: Time.current.iso8601,
          relevance_score: 15,
          matched_fields: [ 'entity_type' ]
        })

        strategy_instance = instance_double(EntitySearchStrategy)
        allow(EntitySearchStrategy).to receive(:new).and_return(strategy_instance)
        allow(strategy_instance).to receive(:search).and_return([ mock_result ])

        results = tool.call(query: 'test')

        expect(results.length).to eq(1)
        expect(results.first[:entity_type]).to eq('Test Type')
        expect(results.first[:matched_fields]).to include('entity_type')
        expect(mock_result).to have_received(:to_h)
      end
    end
  end

  describe 'tool configuration' do
    it 'has the correct description' do
      expect(tool.class.description).to eq('Search for graph memory entities by name, entity type, and aliases with relevance ranking.')
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

  describe 'field-specific search behavior' do
    it 'returns different results for different field matches' do
      # Test entity_type vs name vs aliases matches
      entity_type_results = tool.call(query: 'dessert')
      name_results = tool.call(query: 'apple')
      alias_results = tool.call(query: 'fruit')

      # Should get different sets of results
      expect(entity_type_results.first[:matched_fields]).to include('entity_type')
      expect(name_results.first[:matched_fields]).to include('name')
      expect(alias_results.first[:matched_fields]).to include('aliases')
    end

    it 'correctly handles compound entity types' do
      compound_entity = MemoryEntity.create!(
        name: 'Mixer Tool',
        entity_type: 'Kitchen Equipment',
        aliases: 'cooking tool'
      )

      # Should match partial entity_type
      results = tool.call(query: 'kitchen')
      expect(results.length).to eq(1)
      expect(results.first[:name]).to eq('Mixer Tool')
      expect(results.first[:matched_fields]).to include('entity_type')

    ensure
      compound_entity&.destroy
    end
  end
end
