# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportExecutionStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup existing entities in the database
  let!(:existing_project) do
    MemoryEntity.create!(
      name: 'Existing Project',
      entity_type: 'Project',
      aliases: 'existing'
    )
  end

  let!(:existing_task) do
    MemoryEntity.create!(
      name: 'Existing Task',
      entity_type: 'Task',
      aliases: ''
    )
  end

  let!(:existing_observation) do
    MemoryObservation.create!(
      memory_entity: existing_project,
      content: 'Existing observation'
    )
  end

  describe '#execute' do
    context 'creating new entities' do
      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'New Project',
              'entity_type' => 'Project',
              'aliases' => 'new-proj',
              'observations' => [
                { 'content' => 'First observation', 'created_at' => '2026-01-27T12:00:00Z' },
                { 'content' => 'Second observation', 'created_at' => '2026-01-27T12:01:00Z' }
              ],
              'children' => []
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'create', target_id: nil, parent_id: nil }
        ]
      end

      it 'creates a new entity' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryEntity, :count).by(1)
      end

      it 'creates entity with correct attributes' do
        strategy.execute(import_data, decisions)

        entity = MemoryEntity.find_by(name: 'New Project')
        expect(entity).to be_present
        expect(entity.entity_type).to eq('Project')
        expect(entity.aliases).to eq('new-proj')
      end

      it 'creates observations for new entity' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryObservation, :count).by(2)
      end

      it 'returns successful report' do
        report = strategy.execute(import_data, decisions)

        expect(report.success).to be true
        expect(report.entities_created).to eq(1)
        expect(report.observations_created).to eq(2)
        expect(report.errors).to be_empty
      end
    end

    context 'merging into existing entities' do
      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Project to Merge',
              'entity_type' => 'Project',
              'aliases' => 'merge-alias',
              'observations' => [
                { 'content' => 'New merged observation', 'created_at' => '2026-01-27T12:00:00Z' }
              ],
              'children' => []
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'merge', target_id: existing_project.id, parent_id: nil }
        ]
      end

      it 'does not create new entity' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryEntity, :count)
      end

      it 'merges aliases into existing entity' do
        strategy.execute(import_data, decisions)

        existing_project.reload
        expect(existing_project.aliases).to include('merge-alias')
      end

      it 'adds observations to existing entity' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryObservation, :count).by(1)

        existing_project.reload
        contents = existing_project.memory_observations.pluck(:content)
        expect(contents).to include('New merged observation')
      end

      it 'returns successful report with merge count' do
        report = strategy.execute(import_data, decisions)

        expect(report.success).to be true
        expect(report.entities_merged).to eq(1)
        expect(report.entities_created).to eq(0)
      end

      it 'skips duplicate observations' do
        # Create an observation that already exists
        import_data_with_dup = {
          'root_nodes' => [
            {
              'name' => 'Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [
                { 'content' => 'Existing observation', 'created_at' => '2026-01-27T12:00:00Z' },
                { 'content' => 'Unique observation', 'created_at' => '2026-01-27T12:01:00Z' }
              ],
              'children' => []
            }
          ]
        }

        report = strategy.execute(import_data_with_dup, decisions)

        # Should only create 1 observation (the unique one)
        expect(report.observations_created).to eq(1)
      end
    end

    context 'with nested children' do
      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Parent Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => [
                {
                  'name' => 'Child Task',
                  'entity_type' => 'Task',
                  'aliases' => '',
                  'relation_type' => 'part_of',
                  'observations' => [ { 'content' => 'Child observation' } ],
                  'children' => [
                    {
                      'name' => 'Grandchild Issue',
                      'entity_type' => 'Issue',
                      'aliases' => '',
                      'relation_type' => 'depends_on',
                      'observations' => [],
                      'children' => []
                    }
                  ]
                }
              ]
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'create', target_id: nil, parent_id: nil },
          { node_path: '0.children.0', action: 'create', target_id: nil, parent_id: nil },
          { node_path: '0.children.0.children.0', action: 'create', target_id: nil, parent_id: nil }
        ]
      end

      it 'creates all entities in hierarchy' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryEntity, :count).by(3)
      end

      it 'creates relations between parent and children' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryRelation, :count).by(2)
      end

      it 'creates correct relation types' do
        strategy.execute(import_data, decisions)

        parent = MemoryEntity.find_by(name: 'Parent Project')
        child = MemoryEntity.find_by(name: 'Child Task')
        grandchild = MemoryEntity.find_by(name: 'Grandchild Issue')

        relation1 = MemoryRelation.find_by(from_entity_id: child.id, to_entity_id: parent.id)
        expect(relation1.relation_type).to eq('part_of')

        relation2 = MemoryRelation.find_by(from_entity_id: grandchild.id, to_entity_id: child.id)
        expect(relation2.relation_type).to eq('depends_on')
      end

      it 'returns correct counts in report' do
        report = strategy.execute(import_data, decisions)

        expect(report.entities_created).to eq(3)
        expect(report.relations_created).to eq(2)
        expect(report.observations_created).to eq(1)
      end
    end

    context 'with parent_id assignment' do
      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Imported Node',
              'entity_type' => 'Task',
              'aliases' => '',
              'observations' => [],
              'children' => []
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'create', target_id: nil, parent_id: existing_project.id }
        ]
      end

      it 'creates relation to specified parent' do
        strategy.execute(import_data, decisions)

        imported = MemoryEntity.find_by(name: 'Imported Node')
        relation = MemoryRelation.find_by(from_entity_id: imported.id, to_entity_id: existing_project.id)

        expect(relation).to be_present
        expect(relation.relation_type).to eq('part_of')
      end
    end

    context 'handling duplicates' do
      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Existing Project',  # Same name as existing entity
              'entity_type' => 'Project',
              'aliases' => 'new-alias',
              'observations' => [ { 'content' => 'New observation' } ],
              'children' => []
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'create', target_id: nil, parent_id: nil }
        ]
      end

      it 'merges instead of creating duplicate' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryEntity, :count)
      end

      it 'adds to existing entity' do
        strategy.execute(import_data, decisions)

        existing_project.reload
        expect(existing_project.aliases).to include('new-alias')
      end
    end

    context 'relation deduplication' do
      let!(:existing_relation) do
        MemoryRelation.create!(
          from_entity: existing_task,
          to_entity: existing_project,
          relation_type: 'part_of'
        )
      end

      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Existing Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => [
                {
                  'name' => 'Existing Task',
                  'entity_type' => 'Task',
                  'aliases' => '',
                  'relation_type' => 'part_of',
                  'observations' => [],
                  'children' => []
                }
              ]
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'merge', target_id: existing_project.id, parent_id: nil },
          { node_path: '0.children.0', action: 'merge', target_id: existing_task.id, parent_id: nil }
        ]
      end

      it 'does not create duplicate relations' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryRelation, :count)
      end
    end

    context 'skip action for child nodes' do
      let!(:existing_relation) do
        MemoryRelation.create!(
          from_entity: existing_task,
          to_entity: existing_project,
          relation_type: 'part_of'
        )
      end

      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Existing Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => [
                {
                  'name' => 'Existing Task',
                  'entity_type' => 'Task',
                  'aliases' => '',
                  'relation_type' => 'part_of',
                  'observations' => [],
                  'children' => []
                }
              ]
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'merge', target_id: existing_project.id, parent_id: nil },
          { node_path: '0.children.0', action: 'skip', child_action: 'skip', target_id: existing_task.id, parent_id: nil }
        ]
      end

      it 'does not create new entity for skip action' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryEntity, :count)
      end

      it 'does not create new relation for skip action' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryRelation, :count)
      end

      it 'reports skipped entities in report' do
        report = strategy.execute(import_data, decisions)

        expect(report.success).to be true
        expect(report.entities_skipped).to eq(1)
      end

      it 'still processes children of skipped nodes' do
        import_data_with_grandchild = {
          'root_nodes' => [
            {
              'name' => 'Existing Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => [
                {
                  'name' => 'Existing Task',
                  'entity_type' => 'Task',
                  'aliases' => '',
                  'relation_type' => 'part_of',
                  'observations' => [],
                  'children' => [
                    {
                      'name' => 'New Grandchild',
                      'entity_type' => 'Issue',
                      'aliases' => '',
                      'relation_type' => 'part_of',
                      'observations' => [],
                      'children' => []
                    }
                  ]
                }
              ]
            }
          ]
        }

        decisions_with_grandchild = [
          { node_path: '0', action: 'merge', target_id: existing_project.id, parent_id: nil },
          { node_path: '0.children.0', action: 'skip', child_action: 'skip', target_id: existing_task.id, parent_id: nil },
          { node_path: '0.children.0.children.0', action: 'create', child_action: 'create', target_id: nil, parent_id: nil }
        ]

        expect {
          strategy.execute(import_data_with_grandchild, decisions_with_grandchild)
        }.to change(MemoryEntity, :count).by(1)

        grandchild = MemoryEntity.find_by(name: 'New Grandchild')
        expect(grandchild).to be_present

        # Grandchild should be linked to the skipped task
        relation = MemoryRelation.find_by(from_entity_id: grandchild.id, to_entity_id: existing_task.id)
        expect(relation).to be_present
      end
    end

    context 'add_relation action for child nodes' do
      let!(:other_project) do
        MemoryEntity.create!(
          name: 'Other Project',
          entity_type: 'Project',
          aliases: ''
        )
      end

      let!(:existing_relation) do
        MemoryRelation.create!(
          from_entity: existing_task,
          to_entity: existing_project,
          relation_type: 'part_of'
        )
      end

      let(:import_data) do
        {
          'root_nodes' => [
            {
              'name' => 'Other Project',
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => [
                {
                  'name' => 'Existing Task',
                  'entity_type' => 'Task',
                  'aliases' => '',
                  'relation_type' => 'part_of',
                  'observations' => [ { 'content' => 'New observation via add_relation' } ],
                  'children' => []
                }
              ]
            }
          ]
        }
      end

      let(:decisions) do
        [
          { node_path: '0', action: 'merge', target_id: other_project.id, parent_id: nil },
          { node_path: '0.children.0', action: 'add_relation', child_action: 'add_relation', target_id: existing_task.id, parent_id: nil }
        ]
      end

      it 'does not create new entity for add_relation action' do
        expect {
          strategy.execute(import_data, decisions)
        }.not_to change(MemoryEntity, :count)
      end

      it 'creates new relation to new parent' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryRelation, :count).by(1)

        new_relation = MemoryRelation.find_by(
          from_entity_id: existing_task.id,
          to_entity_id: other_project.id,
          relation_type: 'part_of'
        )
        expect(new_relation).to be_present
      end

      it 'adds new observations' do
        expect {
          strategy.execute(import_data, decisions)
        }.to change(MemoryObservation, :count).by(1)

        existing_task.reload
        expect(existing_task.memory_observations.pluck(:content)).to include('New observation via add_relation')
      end

      it 'reports merged entities (not created)' do
        report = strategy.execute(import_data, decisions)

        expect(report.success).to be true
        expect(report.entities_merged).to eq(2)  # other_project + existing_task
        expect(report.entities_created).to eq(0)
      end
    end

    context 'transaction rollback on error' do
      it 'rolls back all changes on failure' do
        # Create import data that will fail (invalid entity)
        import_data = {
          'root_nodes' => [
            {
              'name' => '',  # Empty name will fail validation
              'entity_type' => 'Project',
              'aliases' => '',
              'observations' => [],
              'children' => []
            }
          ]
        }
        decisions = [ { node_path: '0', action: 'create', target_id: nil, parent_id: nil } ]

        initial_count = MemoryEntity.count
        report = strategy.execute(import_data, decisions)

        expect(MemoryEntity.count).to eq(initial_count)
        expect(report.success).to be false
        expect(report.errors).not_to be_empty
      end
    end

    context 'error handling' do
      it 'reports errors for invalid merge target' do
        import_data = {
          'root_nodes' => [
            { 'name' => 'Test', 'entity_type' => 'Type', 'observations' => [], 'children' => [] }
          ]
        }
        decisions = [ { node_path: '0', action: 'merge', target_id: 99999, parent_id: nil } ]

        report = strategy.execute(import_data, decisions)

        expect(report.errors).not_to be_empty
        expect(report.errors.first).to include('not found')
      end
    end
  end

  describe 'ImportReport' do
    it 'has expected structure' do
      report = ImportExecutionStrategy::ImportReport.new(
        success: true,
        entities_created: 5,
        entities_merged: 2,
        entities_skipped: 1,
        observations_created: 10,
        relations_created: 3,
        errors: []
      )

      expect(report.success).to be true
      expect(report.entities_created).to eq(5)
      expect(report.entities_merged).to eq(2)
      expect(report.entities_skipped).to eq(1)
      expect(report.observations_created).to eq(10)
      expect(report.relations_created).to eq(3)
      expect(report.errors).to eq([])
    end

    it 'to_h returns expected format' do
      report = ImportExecutionStrategy::ImportReport.new(
        success: true,
        entities_created: 5,
        entities_merged: 2,
        entities_skipped: 1,
        observations_created: 10,
        relations_created: 3,
        errors: []
      )

      hash = report.to_h

      expect(hash).to eq({
        success: true,
        entities_created: 5,
        entities_merged: 2,
        entities_skipped: 1,
        observations_created: 10,
        relations_created: 3,
        errors: []
      })
    end
  end
end
