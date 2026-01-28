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
              observations: [ { content: 'New observation' } ],
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

      it 'returns stats with all keys' do
        result = strategy.match(import_data)

        expect(result[:stats]).to include(:total, :root_nodes, :high_confidence, :low_confidence, :new, :skip, :add_relation)
      end
    end

    context 'matching behavior for root nodes' do
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

        it 'marks root node as not a child' do
          result = strategy.match(import_data)

          match_result = result[:match_results].first.to_h
          expect(match_result[:is_child]).to be false
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
    end

    context 'child node matching (1:1 exact match)' do
      # Create relation so Task One is a child of Project Alpha
      let!(:task_relation) do
        MemoryRelation.create!(
          from_entity: task_one,
          to_entity: project_alpha,
          relation_type: 'part_of'
        )
      end

      let!(:observation_one) do
        MemoryObservation.create!(
          memory_entity: task_one,
          content: 'Existing observation'
        )
      end

      context 'skip - child exists with same parent' do
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
                  }
                ]
              }
            ]
          }
        end

        it 'marks child with same parent as skip' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:status]).to eq('skip')
          expect(child_match.to_h[:child_action]).to eq('skip')
        end

        it 'marks child as is_child true' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:is_child]).to be true
        end

        it 'includes import_parent_name' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:import_parent_name]).to eq('Project Alpha')
        end

        it 'includes exact_match entity' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:exact_match]).not_to be_nil
          expect(child_match.to_h[:exact_match][:entity_id]).to eq(task_one.id)
        end

        it 'will_add_observations is false when no new observations' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:will_add_observations]).to be false
        end
      end

      context 'add_relation - child exists but different parent' do
        let!(:other_project) do
          MemoryEntity.create!(
            name: 'Other Project',
            entity_type: 'Project',
            aliases: ''
          )
        end

        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'Other Project',
                entity_type: 'Project',
                observations: [],
                children: [
                  {
                    name: 'Task One',
                    entity_type: 'Task',
                    relation_type: 'part_of',
                    observations: [ { content: 'New observation for task' } ],
                    children: []
                  }
                ]
              }
            ]
          }
        end

        it 'marks child with different parent as add_relation' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:status]).to eq('add_relation')
          expect(child_match.to_h[:child_action]).to eq('add_relation')
        end

        it 'includes import_parent_name' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:import_parent_name]).to eq('Other Project')
        end

        it 'will_add_observations is true when new observations exist' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:will_add_observations]).to be true
        end
      end

      context 'create - child does not exist' do
        let(:import_data) do
          {
            root_nodes: [
              {
                name: 'Project Alpha',
                entity_type: 'Project',
                observations: [],
                children: [
                  {
                    name: 'Completely New Child',
                    entity_type: 'NewType',
                    relation_type: 'part_of',
                    observations: [ { content: 'Observation' } ],
                    children: []
                  }
                ]
              }
            ]
          }
        end

        it 'marks non-existent child as new with create action' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:status]).to eq('new')
          expect(child_match.to_h[:child_action]).to eq('create')
        end

        it 'exact_match is nil for new child' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:exact_match]).to be_nil
        end

        it 'will_add_observations is true for new child with observations' do
          result = strategy.match(import_data)

          child_match = result[:match_results].find { |r| r.to_h[:node_path] == '0.children.0' }
          expect(child_match.to_h[:will_add_observations]).to be true
        end
      end
    end

    context 'stats calculation' do
      let!(:task_relation) do
        MemoryRelation.create!(
          from_entity: task_one,
          to_entity: project_alpha,
          relation_type: 'part_of'
        )
      end

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

      it 'calculates root_nodes correctly' do
        result = strategy.match(import_data)

        expect(result[:stats][:root_nodes]).to eq(1)
      end

      it 'calculates skip correctly' do
        result = strategy.match(import_data)

        # Task One should be skipped (same parent)
        expect(result[:stats][:skip]).to eq(1)
      end

      it 'calculates new correctly' do
        result = strategy.match(import_data)

        # ZyxUnique789 should be new
        expect(result[:stats][:new]).to eq(1)
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
    it 'has expected structure for root node' do
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Test', entity_type: 'Type' },
        matches: [],
        status: 'new',
        selected_match_id: nil,
        parent_entity_id: nil,
        node_path: '0',
        is_child: false,
        import_parent_name: nil,
        exact_match: nil,
        child_action: nil,
        will_add_observations: nil
      )

      expect(match_result.import_node).to eq({ name: 'Test', entity_type: 'Type' })
      expect(match_result.matches).to eq([])
      expect(match_result.status).to eq('new')
      expect(match_result.node_path).to eq('0')
      expect(match_result.is_child).to be false
    end

    it 'has expected structure for child node' do
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Child', entity_type: 'Task' },
        matches: [],
        status: 'skip',
        selected_match_id: task_one.id,
        parent_entity_id: nil,
        node_path: '0.children.0',
        is_child: true,
        import_parent_name: 'Project Alpha',
        exact_match: task_one,
        child_action: 'skip',
        will_add_observations: false
      )

      expect(match_result.is_child).to be true
      expect(match_result.import_parent_name).to eq('Project Alpha')
      expect(match_result.exact_match).to eq(task_one)
      expect(match_result.child_action).to eq('skip')
    end

    it 'to_h returns expected format for root node' do
      entity = project_alpha
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Test', entity_type: 'Type', observations: [], children: [] },
        matches: [ { entity: entity, score: 25.0, matched_fields: [ 'name', 'entity_type' ] } ],
        status: 'high',
        selected_match_id: entity.id,
        parent_entity_id: nil,
        node_path: '0',
        is_child: false,
        import_parent_name: nil,
        exact_match: nil,
        child_action: nil,
        will_add_observations: nil
      )

      hash = match_result.to_h

      expect(hash[:import_node]).to include(:name, :entity_type)
      expect(hash[:matches]).to be_an(Array)
      expect(hash[:matches].first).to include(:entity_id, :name, :score)
      expect(hash[:status]).to eq('high')
      expect(hash[:selected_match_id]).to eq(entity.id)
      expect(hash[:node_path]).to eq('0')
      expect(hash[:is_child]).to be false
    end

    it 'to_h returns expected format for child node' do
      match_result = ImportMatchingStrategy::MatchResult.new(
        import_node: { name: 'Child', entity_type: 'Task', observations: [], children: [] },
        matches: [],
        status: 'add_relation',
        selected_match_id: task_one.id,
        parent_entity_id: nil,
        node_path: '0.children.0',
        is_child: true,
        import_parent_name: 'Parent Node',
        exact_match: task_one,
        child_action: 'add_relation',
        will_add_observations: true
      )

      hash = match_result.to_h

      expect(hash[:is_child]).to be true
      expect(hash[:import_parent_name]).to eq('Parent Node')
      expect(hash[:child_action]).to eq('add_relation')
      expect(hash[:will_add_observations]).to be true
      expect(hash[:exact_match][:entity_id]).to eq(task_one.id)
      expect(hash[:matches]).to eq([])  # Empty for child nodes
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
      expect(ImportMatchingStrategy::STATUS_SKIP).to eq('skip')
      expect(ImportMatchingStrategy::STATUS_ADD_RELATION).to eq('add_relation')
    end

    it 'defines child action constants' do
      expect(ImportMatchingStrategy::CHILD_ACTION_SKIP).to eq('skip')
      expect(ImportMatchingStrategy::CHILD_ACTION_ADD_RELATION).to eq('add_relation')
      expect(ImportMatchingStrategy::CHILD_ACTION_CREATE).to eq('create')
    end
  end
end
