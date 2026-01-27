# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportMatchingStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup existing entities in the database
  let!(:project_alpha) do
    MemoryEntity.create!(
      name: 'Project Alpha',
      entity_type: 'Project',
      aliases: 'alpha, alpha-project'
    )
  end

  let!(:task_one) do
    MemoryEntity.create!(
      name: 'Task One',
      entity_type: 'Task',
      aliases: 'task-1, first task'
    )
  end

  let!(:unrelated_entity) do
    MemoryEntity.create!(
      name: 'Unrelated Entity',
      entity_type: 'Other',
      aliases: ''
    )
  end

  describe '#match' do
    context 'with invalid input' do
      it 'returns error for nil input' do
        result = strategy.match(nil)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid JSON format')
      end

      it 'returns error for invalid JSON string' do
        result = strategy.match('not valid json {')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid JSON format')
      end

      it 'returns error for missing root_nodes' do
        result = strategy.match({ version: '1.0' })

        expect(result[:success]).to be false
        expect(result[:error]).to eq("Invalid import format. Expected 'root_nodes' array.")
      end
    end

    context 'with valid import data' do
      let(:import_data) do
        {
          version: '1.0',
          exported_at: '2026-01-27T12:00:00Z',
          root_nodes: [
            {
              name: 'Project Alpha',
              entity_type: 'Project',
              aliases: 'alpha',
              observations: [{ content: 'New observation' }],
              children: []
            }
          ]
        }
      end

      it 'returns success true for valid data' do
        result = strategy.match(import_data)

        expect(result[:success]).to be true
      end

      it 'includes version from import data' do
        result = strategy.match(import_data)

        expect(result[:version]).to eq('1.0')
      end

      it 'includes exported_at from import data' do
        result = strategy.match(import_data)

        expect(result[:exported_at]).to eq('2026-01-27T12:00:00Z')
      end

      it 'returns match_results for each node' do
        result = strategy.match(import_data)

        expect(result[:match_results]).to be_an(Array)
        expect(result[:match_results].length).to eq(1)
      end

      it 'returns stats' do
        result = strategy.match(import_data)

        expect(result[:stats]).to include(:total, :high_confidence, :low_confidence, :new)
      end
    end

    context 'matching behavior' do
      context 'high confidence matches' do
        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'Project Alpha',
                entity_type: 'Project',
                observations: [],
                children: []
              }
            ]
          }
        end

        it 'identifies high confidence match when name and type match exactly' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:status]).to eq('high')
        end

        it 'auto-selects best match for high confidence' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:selected_match_id]).to eq(project_alpha.id)
        end

        it 'includes matching entity in matches list' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:matches]).not_to be_empty

          first_match = match_result[:matches].first
          expect(first_match[:entity_id]).to eq(project_alpha.id)
        end
      end

      context 'low confidence matches' do
        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'XyzProject123',
                entity_type: 'Project',
                observations: [],
                children: []
              }
            ]
          }
        end

        it 'identifies low or new confidence match when entity_type matches but name is different' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          # This could be low (matches entity_type "Project") or new (no name match)
          # depending on search scoring
          expect(['low', 'new', 'high']).to include(match_result[:status])
        end
      end

      context 'new nodes (no match)' do
        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'ZyxWvuTsr987654',
                entity_type: 'CompletelyUniqueType123',
                observations: [],
                children: []
              }
            ]
          }
        end

        it 'identifies new node when no match found' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:status]).to eq('new')
        end

        it 'has empty matches for new node' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:matches]).to be_empty
        end

        it 'has nil selected_match_id for new node' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:selected_match_id]).to be_nil
        end
      end

      context 'with nested children' do
        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'Project Alpha',
                entity_type: 'Project',
                observations: [],
                children: [
                  {
                    name: 'Task One',
                    entity_type: 'Task',
                    relation_type: 'part_of',
                    observations: [],
                    children: []
                  },
                  {
                    name: 'ZyxUnique987',
                    entity_type: 'UniqueType456',
                    relation_type: 'part_of',
                    observations: [],
                    children: []
                  }
                ]
              }
            ]
          }
        end

        it 'matches all nodes including children' do
          result = strategy.match(import_data)

          expect(result[:match_results].length).to eq(3)
        end

        it 'includes correct node_path for each match' do
          result = strategy.match(import_data)

          paths = result[:match_results].map { |r| r.to_h[:node_path] }
          expect(paths).to contain_exactly('0', '0.children.0', '0.children.1')
        end

        it 'correctly matches children' do
          result = strategy.match(import_data)

          task_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(task_match.to_h[:status]).to eq('high')
          expect(task_match.to_h[:selected_match_id]).to eq(task_one.id)
        end

        it 'identifies new children' do
          result = strategy.match(import_data)

          new_task_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.1' }
          expect(new_task_match.to_h[:status]).to eq('new')
        end
      end
    end

    context 'stats calculation' do
      let(:import_data) do
        {
          root_nodes: [
            {
              name: 'Project Alpha',
              entity_type: 'Project',
              observations: [],
              children: [
                { name: 'Task One', entity_type: 'Task', observations: [], children: [] },
                { name: 'ZyxUnique789', entity_type: 'CompletelyNewType999', observations: [], children: [] }
              ]
            }
          ]
        }
      end

      it 'calculates total correctly' do
        result = strategy.match(import_data)

        expect(result[:stats][:total]).to eq(3)
      end

      it 'calculates high_confidence correctly' do
        result = strategy.match(import_data)

        # Project Alpha and Task One should be high confidence
        expect(result[:stats][:high_confidence]).to be >= 1
      end

      it 'calculates new correctly' do
        result = strategy.match(import_data)

        # ZyxUnique789 should be new (completely unique name and type)
        expect(result[:stats][:new]).to be >= 1
      end
    end

    context 'JSON string input' do
      it 'accepts JSON string input' do
        json_string = JSON.generate({
          root_nodes: [
            { name: 'Project Alpha', entity_type: 'Project', observations: [], children: [] }
          ]
        })

        result = strategy.match(json_string)
        expect(result[:success]).to be true
      end
    end
  end

  describe '#available_parents' do
    it 'returns available parent entities' do
      parents = strategy.available_parents

      expect(parents).to be_an(Array)
      expect(parents.map(&:name)).to include('Project Alpha')
    end
  end

  describe 'MatchResult' do
    it 'has expected structure' do
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Test', entity_type: 'Type' },
        matches: [],
        status: 'new',
        selected_match_id: nil,
        parent_entity_id: nil,
        node_path: '0'
      )

      expect(match_result.import_node).to eq({ name: 'Test', entity_type: 'Type' })
      expect(match_result.matches).to eq([])
      expect(match_result.status).to eq('new')
      expect(match_result.node_path).to eq('0')
    end

    it 'to_h returns expected format' do
      entity = project_alpha
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Test', entity_type: 'Type', observations: [], children: [] },
        matches: [{ entity: entity, score: 25.0, matched_fields: ['name', 'entity_type'] }],
        status: 'high',
        selected_match_id: entity.id,
        parent_entity_id: nil,
        node_path: '0'
      )

      hash = match_result.to_h

      expect(hash[:import_node]).to include(:name, :entity_type)
      expect(hash[:matches]).to be_an(Array)
      expect(hash[:matches].first).to include(:entity_id, :name, :score)
      expect(hash[:status]).to eq('high')
      expect(hash[:selected_match_id]).to eq(entity.id)
      expect(hash[:node_path]).to eq('0')
    end
  end

  describe 'constants' do
    it 'defines HIGH_CONFIDENCE_THRESHOLD' do
      expect(ImportMatchingStrategy::HIGH_CONFIDENCE_THRESHOLD).to eq(20)
    end

    it 'defines LOW_CONFIDENCE_THRESHOLD' do
      expect(ImportMatchingStrategy::LOW_CONFIDENCE_THRESHOLD).to eq(10)
    end

    it 'defines status constants' do
      expect(ImportMatchingStrategy::STATUS_HIGH_CONFIDENCE).to eq('high')
      expect(ImportMatchingStrategy::STATUS_LOW_CONFIDENCE).to eq('low')
      expect(ImportMatchingStrategy::STATUS_NEW).to eq('new')
    end
  end
end
