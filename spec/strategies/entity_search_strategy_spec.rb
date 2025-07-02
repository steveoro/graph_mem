# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EntitySearchStrategy, type: :model do
  let(:strategy) { described_class.new }

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

      it 'finds entities by alias match' do
        results = strategy.search('fruit')
        
        expect(results.length).to eq(2)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Apple Juice')
      end

      it 'is case insensitive' do
        results = strategy.search('APPLE')
        
        expect(results.length).to eq(3)
        entity_names = results.map { |r| r.entity.name }
        expect(entity_names).to contain_exactly('Apple Pie', 'Apple Juice', 'Green Apple')
      end

      it 'returns results ordered by relevance score' do
        results = strategy.search('apple')
        
        # Should be ordered by score (name matches should score higher than alias matches)
        expect(results.first.entity.name).to eq('Apple Juice') # Exact word match in name
        expect(results.first.score).to be > results.last.score
      end
    end

    context 'with multi-token queries' do
      it 'finds entities matching multiple tokens' do
        results = strategy.search('apple pie')
        
        expect(results.length).to eq(3) # Apple Pie (both tokens), Apple Juice (apple), others with pie/fruit
        
        # Apple Pie should be first (matches both tokens)
        expect(results.first.entity.name).to eq('Apple Pie')
        expect(results.first.score).to be > results[1].score
      end

      it 'gives higher scores for matching more tokens' do
        results = strategy.search('apple fruit')
        
        apple_pie_result = results.find { |r| r.entity.name == 'Apple Pie' }
        apple_juice_result = results.find { |r| r.entity.name == 'Apple Juice' }
        
        # Both should match, but Apple Pie should score higher (matches both in name+aliases)
        expect(apple_pie_result.score).to be > apple_juice_result.score
      end

      it 'handles duplicate tokens' do
        results = strategy.search('apple apple pie')
        
        # Should treat as unique tokens: ['apple', 'pie']
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
        
        # Check if any result has aliases match
        alias_match_result = results.find { |r| r.matched_fields.include?('aliases') }
        expect(alias_match_result).to be_present
      end

      it 'gives bonus for exact word matches' do
        results = strategy.search('apple')
        
        # "Apple Pie" and "Apple Juice" should score higher than "Green Apple" 
        # because "apple" is an exact word match at the beginning
        apple_juice_score = results.find { |r| r.entity.name == 'Apple Juice' }.score
        green_apple_score = results.find { |r| r.entity.name == 'Green Apple' }.score
        
        expect(apple_juice_score).to be >= green_apple_score
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
        expect(result_hash[:relevance_score]).to be_a(Integer)
        expect(result_hash[:matched_fields]).to be_an(Array)
      end
    end
  end

  describe 'private methods' do
    describe '#tokenize_query' do
      it 'splits on whitespace and normalizes' do
        tokens = strategy.send(:tokenize_query, 'Apple  Pie   Cake')
        expect(tokens).to eq(['apple', 'pie', 'cake'])
      end

      it 'removes duplicates' do
        tokens = strategy.send(:tokenize_query, 'apple pie apple')
        expect(tokens).to eq(['apple', 'pie'])
      end

      it 'handles empty and whitespace strings' do
        expect(strategy.send(:tokenize_query, '')).to eq([])
        expect(strategy.send(:tokenize_query, '   ')).to eq([])
      end
    end

    describe '#calculate_entity_score' do
      it 'calculates correct scores for name matches' do
        tokens = ['apple']
        score, fields = strategy.send(:calculate_entity_score, apple_entity, tokens)
        
        expect(score).to be > 0
        expect(fields).to include('name')
      end

      it 'calculates correct scores for alias matches' do
        tokens = ['dessert']
        score, fields = strategy.send(:calculate_entity_score, apple_entity, tokens)
        
        expect(score).to be > 0
        expect(fields).to include('aliases')
      end

      it 'gives higher scores for multiple token matches' do
        single_token_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['apple'])
        multi_token_score, _ = strategy.send(:calculate_entity_score, apple_entity, ['apple', 'dessert'])
        
        expect(multi_token_score).to be > single_token_score
      end
    end
  end

  describe 'constants' do
    it 'has expected field weights' do
      expect(EntitySearchStrategy::FIELD_WEIGHTS).to eq({
        name: 10,
        aliases: 5
      })
    end

    it 'has minimum score threshold' do
      expect(EntitySearchStrategy::MIN_SCORE_THRESHOLD).to eq(1)
    end
  end
end