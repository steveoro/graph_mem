# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EntitySearchStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup test data with meaningful entity types for testing
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

  let!(:carrot_cake_entity) do
    MemoryEntity.create!(
      name: 'Carrot Cake',
      entity_type: 'Dessert',
      aliases: 'vegetable cake, spiced cake'
    )
  end

  let!(:green_apple_entity) do
    MemoryEntity.create!(
      name: 'Green Apple',
      entity_type: 'Fruit',
      aliases: 'granny smith, tart apple'
    )
  end

  let!(:beverage_mixer_entity) do
    MemoryEntity.create!(
      name: 'Cocktail Mixer',
      entity_type: 'Beverage Equipment',
      aliases: 'drink mixer, bar tool'
    )
  end

  describe '#search' do
    context 'with empty or blank query' do
      it 'returns empty array for nil query' do
        results = strategy.search(nil)
        expect(results).to eq([])
      end

      it 'returns empty array for empty string' do
        results = strategy.search('')
        expect(results).to eq([])
      end

      it 'returns empty array for whitespace-only string' do
        results = strategy.search('   ')
        expect(results).to eq([])
      end
    end

    context 'with single token queries' do
      it 'finds entities by name match' do
        results = strategy.search('apple')
        
        expect(results.length).to eq(3)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Apple Juice', 'Green Apple')
      end

      it 'finds entities by entity_type match' do
        results = strategy.search('dessert')
        
        expect(results.length).to eq(2)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Carrot Cake')
        
        # Both should have entity_type in matched_fields
        results.each do |result|
          expect(result.matched_fields).to include('entity_type')
        end
      end

      it 'finds entities by alias match' do
        results = strategy.search('fruit')
        
        expect(results.length).to eq(2)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Apple Juice')
      end

      it 'is case insensitive' do
        results = strategy.search('DESSERT')
        
        expect(results.length).to eq(2)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Carrot Cake')
      end

      it 'returns results ordered by entity_type first, then by relevance score' do
        results = strategy.search('apple')
        
        # Results should be grouped by entity_type alphabetically
        entity_types = results.map { |r| r.entity.entity_type }
        expect(entity_types).to eq(['Beverage', 'Dessert', 'Fruit'])
        
        # Within same entity_type, should be ordered by score
        expect(results.first.entity.name).to eq('Apple Juice') # Beverage
        expect(results.second.entity.name).to eq('Apple Pie') # Dessert
        expect(results.third.entity.name).to eq('Green Apple') # Fruit
      end
    end

    context 'with entity_type specific queries' do
      it 'prioritizes entity_type matches with highest score' do
        results = strategy.search('beverage')
        
        expect(results.length).to eq(2)
        # Both should match entity_type, but Apple Juice should score higher (exact match)
        expect(results.first.entity.name).to eq('Apple Juice')
        expect(results.second.entity.name).to eq('Cocktail Mixer')
        
        # Check that entity_type matches get higher scores than name/alias matches
        beverage_result = results.find { |r| r.entity.name == 'Apple Juice' }
        expect(beverage_result.score).to be >= 15 # At least base entity_type weight
        expect(beverage_result.matched_fields).to include('entity_type')
      end

      it 'handles partial entity_type matches' do
        results = strategy.search('baked')
        
        expect(results.length).to eq(1)
        expect(results.first.entity.name).to eq('Banana Bread')
        expect(results.first.matched_fields).to include('entity_type')
      end
    end

    context 'with multi-token queries' do
      it 'finds entities matching multiple tokens across different fields' do
        results = strategy.search('apple dessert')
        
        expect(results.length).to be >= 2
        
        # Apple Pie should be first (matches both: apple in name, dessert in entity_type)
        expect(results.first.entity.name).to eq('Apple Pie')
        expect(results.first.matched_fields).to include('name', 'entity_type')
      end

      it 'gives higher scores for matching more tokens' do
        results = strategy.search('apple fruit')
        
        apple_pie_result = results.find { |r| r.entity.name == 'Apple Pie' }
        green_apple_result = results.find { |r| r.entity.name == 'Green Apple' }
        
        # Green Apple should score higher (matches apple in name, fruit in entity_type)
        expect(green_apple_result.score).to be > apple_pie_result.score
      end

      it 'handles duplicate tokens' do
        results = strategy.search('apple apple dessert')
        
        # Should treat as unique tokens: ['apple', 'dessert']
        expect(results.first.entity.name).to eq('Apple Pie')
      end
    end

    context 'with no matches' do
      it 'returns empty array when no entities match' do
        results = strategy.search('chocolate')
        expect(results).to eq([])
      end
    end

    context 'relevance scoring' do
      it 'prioritizes entity_type matches over name matches' do
        # Create specific test data
        entity_with_type = MemoryEntity.create!(
          name: 'Random Name',
          entity_type: 'Test Category',
          aliases: 'other stuff'
        )
        entity_with_name = MemoryEntity.create!(
          name: 'Test Name',
          entity_type: 'Other Category',
          aliases: 'different stuff'
        )
        
        results = strategy.search('test')
        
        # entity_with_type should score higher (entity_type weight 15 > name weight 10)
        type_match_result = results.find { |r| r.entity.id == entity_with_type.id }
        name_match_result = results.find { |r| r.entity.id == entity_with_name.id }
        
        expect(type_match_result.score).to be > name_match_result.score
      ensure
        entity_with_type&.destroy
        entity_with_name&.destroy
      end

      it 'prioritizes name matches over alias matches' do
        results = strategy.search('cake')
        
        # Carrot Cake has "cake" in name, Banana Bread has "cake" in aliases
        carrot_result = results.find { |r| r.entity.name == 'Carrot Cake' }
        banana_result = results.find { |r| r.entity.name == 'Banana Bread' }
        
        expect(carrot_result.score).to be > banana_result.score
      end

      it 'includes matched fields information' do
        results = strategy.search('apple')
        
        apple_pie_result = results.find { |r| r.entity.name == 'Apple Pie' }
        expect(apple_pie_result.matched_fields).to include('name')
        
        # Check if any result has entity_type match
        type_match_result = results.find { |r| r.matched_fields.include?('entity_type') }
        expect(type_match_result).to be_nil # 'apple' doesn't match any entity_type
        
        # Test entity_type match
        dessert_results = strategy.search('dessert')
        expect(dessert_results.first.matched_fields).to include('entity_type')
      end

      it 'gives bonus for exact word matches' do
        results = strategy.search('dessert')
        
        # Both Apple Pie and Carrot Cake should get exact word bonus for entity_type match
        results.each do |result|
          expect(result.score).to be >= 15 + (15 * 0.5) # Base + exact word bonus
        end
      end

      it 'applies multi-token bonus correctly' do
        single_token_results = strategy.search('apple')
        multi_token_results = strategy.search('apple dessert')
        
        apple_pie_single = single_token_results.find { |r| r.entity.name == 'Apple Pie' }
        apple_pie_multi = multi_token_results.find { |r| r.entity.name == 'Apple Pie' }
        
        # Multi-token should have higher score due to bonus
        expect(apple_pie_multi.score).to be > apple_pie_single.score
      end
    end

    context 'result ordering' do
      it 'orders results by entity_type alphabetically first' do
        results = strategy.search('apple')
        
        entity_types = results.map { |r| r.entity.entity_type }
        expect(entity_types).to eq(entity_types.sort)
      end

      it 'orders by score within same entity_type' do
        # Create two desserts with different relevance scores
        dessert1 = MemoryEntity.create!(
          name: 'Chocolate Cake',
          entity_type: 'Dessert',
          aliases: 'cocoa cake'
        )
        dessert2 = MemoryEntity.create!(
          name: 'Test Dessert',
          entity_type: 'Dessert', 
          aliases: 'test cake'
        )
        
        results = strategy.search('cake')
        dessert_results = results.select { |r| r.entity.entity_type == 'Dessert' }
        
        # Should be ordered by score within the Dessert category
        scores = dessert_results.map(&:score)
        expect(scores).to eq(scores.sort.reverse)
        
      ensure
        dessert1&.destroy
        dessert2&.destroy
      end
    end

    context 'with limit parameter' do
      it 'respects the limit parameter' do
        results = strategy.search('apple', limit: 2)
        expect(results.length).to eq(2)
      end

      it 'returns top results when limited' do
        results_unlimited = strategy.search('apple')
        results_limited = strategy.search('apple', limit: 2)
        
        expect(results_limited.length).to eq(2)
        expect(results_limited.first.entity.id).to eq(results_unlimited.first.entity.id)
        expect(results_limited.last.entity.id).to eq(results_unlimited.second.entity.id)
      end
    end

    context 'result format' do
      it 'returns SearchResult objects' do
        results = strategy.search('apple')
        expect(results.first).to be_a(EntitySearchStrategy::SearchResult)
      end

      it 'SearchResult#to_h returns expected format' do
        results = strategy.search('apple')
        result_hash = results.first.to_h
        
        expect(result_hash).to include(
          :entity_id,
          :name,
          :entity_type,
          :aliases,
          :created_at,
          :updated_at,
          :relevance_score,
          :matched_fields
        )
        
        expect(result_hash[:entity_id]).to be_a(Integer)
        expect(result_hash[:name]).to be_a(String)
        expect(result_hash[:entity_type]).to be_a(String)
        expect(result_hash[:relevance_score]).to be_a(Integer)
        expect(result_hash[:matched_fields]).to be_an(Array)
      end
    end
  end

  describe 'private methods' do
    describe '#tokenize_query' do
      it 'splits on whitespace and normalizes' do
        tokens = strategy.send(:tokenize_query, 'Apple  Dessert   Cake')
        expect(tokens).to eq(['apple', 'dessert', 'cake'])
      end

      it 'removes duplicates' do
        tokens = strategy.send(:tokenize_query, 'apple dessert apple')
        expect(tokens).to eq(['apple', 'dessert'])
      end

      it 'handles empty and whitespace strings' do
        expect(strategy.send(:tokenize_query, '')).to eq([])
        expect(strategy.send(:tokenize_query, '   ')).to eq([])
      end
    end

    describe '#calculate_entity_score' do
      it 'calculates correct scores for entity_type matches' do
        tokens = ['dessert']
        score, fields = strategy.send(:calculate_entity_score, apple_entity, tokens)
        
        expect(score).to be >= 15 # At least base entity_type weight
        expect(fields).to include('entity_type')
      end

      it 'calculates correct scores for name matches' do
        tokens = ['apple']
        score, fields = strategy.send(:calculate_entity_score, apple_entity, tokens)
        
        expect(score).to be > 0
        expect(fields).to include('name')
      end

      it 'calculates correct scores for alias matches' do
        tokens = ['fruit']
        score, fields = strategy.send(:calculate_entity_score, apple_entity, tokens)
        
        expect(score).to be > 0
        expect(fields).to include('aliases')
      end

      it 'gives higher scores for multiple token matches' do
        single_token_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['apple'])
        multi_token_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['apple', 'dessert'])
        
        expect(multi_token_score).to be > single_token_score
      end

      it 'scores entity_type matches higher than name matches' do
        entity_type_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['dessert'])
        name_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['apple'])
        
        expect(entity_type_score).to be > name_score
      end
    end
  end

  describe 'constants' do
    it 'has expected field weights with entity_type highest' do
      expect(EntitySearchStrategy::FIELD_WEIGHTS).to eq({
        entity_type: 15,
        name: 10,
        aliases: 5
      })
    end

    it 'has minimum score threshold' do
      expect(EntitySearchStrategy::MIN_SCORE_THRESHOLD).to eq(1)
    end
  end
end