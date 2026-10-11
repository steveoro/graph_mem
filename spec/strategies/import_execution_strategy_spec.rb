# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportExecutionStrategy, type: :model do
  let(:observation_duplicate_detector) { instance_double(ImportObservationDuplicateDetector) }
  let(:strategy) { described_class.new(observation_duplicate_detector: observation_duplicate_detector) }

  before do
    allow(observation_duplicate_detector).to receive(:find_duplicate) do |entity:, content:|
      ImportObservationDuplicateDetector::Result.new(
        duplicate: MemoryObservation.active.exists?(memory_entity_id: entity.id, content: content)
      )
    end
  end

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
                {
                  'content' => 'First observation',
                  'created_at' => '2026-01-27T12:00:00Z',
                  'confidence' => 0.9,
                  'source' => 'import-spec',
                  'valid_from' => '2026-07-01T00:00:00Z',
                  'valid_until' => '2026-08-01T00:00:00Z',
                  'tags' => %w[import verified]
                },
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

      it 'imports structured observation metadata' do
        strategy.execute(import_data, decisions)

        observation = MemoryObservation.find_by!(content: 'First observation')
        expect(observation).to have_attributes(
          confidence: 0.9,
          source: 'import-spec',
          tags: %w[import verified]
        )
        expect(observation.valid_from).to be_present
        expect(observation.valid_until).to be_present
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

      it 'enqueues an embedding backfill on a merge-only import' do
        # An alias-only merge creates nothing but clears embedded_at via
        # before_update — the backfill must be queued or the entity silently
        # drops out of vector search.
        merge_only_data = {
          'root_nodes' => [
            {
              'name' => 'Project to Merge',
              'entity_type' => 'Project',
              'aliases' => 'merge-alias',
              'observations' => [],
              'children' => []
            }
          ]
        }
        expect(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with('backfill')

        report = strategy.execute(merge_only_data, decisions)
        expect(report.success).to be true
        expect(report.entities_merged).to eq(1)
        expect(report.observations_created).to eq(0)
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
                  'relation_weight' => 2.0,
                  'relation_confidence' => 0.8,
                  'relation_properties' => { 'source' => 'import-spec' },
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

      it 'imports structured relation metadata' do
        strategy.execute(import_data, decisions)

        parent = MemoryEntity.find_by(name: 'Parent Project')
        child = MemoryEntity.find_by(name: 'Child Task')
        relation = MemoryRelation.find_by!(from_entity_id: child.id, to_entity_id: parent.id)

        expect(relation).to have_attributes(weight: 2.0, confidence: 0.8)
        expect(relation.properties).to eq('source' => 'import-spec')
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

      it 'imports missing observations for skipped nodes' do
        import_data_with_obs = {
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
                  'observations' => [ { 'content' => 'New observation for skipped node' } ],
                  'children' => []
                }
              ]
            }
          ]
        }

        expect {
          strategy.execute(import_data_with_obs, decisions)
        }.to change(MemoryObservation, :count).by(1)

        existing_task.reload
        expect(existing_task.memory_observations.pluck(:content)).to include('New observation for skipped node')
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
        strategy.execute(import_data, decisions)

        new_relation = MemoryRelation.find_by(
          from_entity_id: existing_task.id,
          to_entity_id: other_project.id,
          relation_type: 'part_of'
        )
        expect(new_relation).to be_present
        # part_of is single-parent: previous parent link is replaced
        expect(MemoryRelation.find_by(
          from_entity_id: existing_task.id,
          to_entity_id: existing_project.id,
          relation_type: 'part_of'
        )).to be_nil
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
        relations_unresolved: 1,
        errors: []
      )

      hash = report.to_h

      expect(hash).to eq({
        success: true,
        entities_created: 5,
        entities_merged: 2,
        entities_skipped: 1,
        observations_created: 10,
        observations_obsoleted: nil,
        observations_superseded: nil,
        relations_created: 3,
        relations_unresolved: 1,
        relations_skipped: nil,
        relations_cross_repo: nil,
        rescan: nil,
        rescan_entities_flagged: nil,
        rescan_relations_flagged: nil,
        rescan_reparents_flagged: nil,
        errors: []
      })
    end
  end

  describe 'non-tree relations' do
    let(:import_data) do
      {
        'root_nodes' => [
          {
            'name' => 'Sample App',
            'entity_type' => 'Project',
            'children' => [
              {
                'name' => 'app/models/swimmer.rb',
                'entity_type' => 'File',
                'relation_type' => 'part_of',
                'children' => [
                  {
                    'name' => 'Swimmer',
                    'entity_type' => 'Class',
                    'relation_type' => 'part_of',
                    'children' => [
                      {
                        'name' => 'Swimmer#name',
                        'entity_type' => 'Method',
                        'relation_type' => 'part_of',
                        'children' => []
                      },
                      {
                        'name' => 'Swimmer#find',
                        'entity_type' => 'Method',
                        'relation_type' => 'part_of',
                        'children' => []
                      }
                    ]
                  },
                  {
                    'name' => 'ApplicationRecord',
                    'entity_type' => 'Class',
                    'relation_type' => 'part_of',
                    'children' => []
                  }
                ]
              }
            ]
          }
        ],
        'relations' => [
          {
            'from_name' => 'Swimmer#name', 'from_type' => 'Method',
            'to_name' => 'Swimmer#find', 'to_type' => 'Method',
            'relation_type' => 'calls', 'confidence' => 1.0,
            'properties' => { 'source' => 'graphify', 'provenance' => 'EXTRACTED' }
          },
          {
            'from_name' => 'Swimmer', 'from_type' => 'Class',
            'to_name' => 'ApplicationRecord', 'to_type' => 'Class',
            'relation_type' => 'inherits', 'confidence' => 1.0
          },
          {
            'from_name' => 'Swimmer#name', 'from_type' => 'Method',
            'to_name' => 'Missing#thing', 'to_type' => 'Method',
            'relation_type' => 'calls', 'confidence' => 0.5
          }
        ]
      }
    end

    let(:decisions) { [ { node_path: '0', action: 'create' } ] }

    it 'creates name+type-addressed relations after the tree exists' do
      report = strategy.execute(import_data, decisions)

      swimmer = MemoryEntity.find_by(name: 'Swimmer')
      record = MemoryEntity.find_by(name: 'ApplicationRecord')
      name_m = MemoryEntity.find_by(name: 'Swimmer#name')
      find_m = MemoryEntity.find_by(name: 'Swimmer#find')

      expect(report.success).to be(true)
      expect(
        MemoryRelation.exists?(from_entity: name_m, to_entity: find_m, relation_type: 'calls')
      ).to be(true)
      expect(
        MemoryRelation.exists?(from_entity: swimmer, to_entity: record, relation_type: 'inherits')
      ).to be(true)
      # 5 containment edges in the tree + 2 emitted code relations
      expect(report.relations_created).to eq(7)
    end

    it 'counts unresolved endpoints without failing' do
      report = strategy.execute(import_data, decisions)

      expect(report.success).to be(true)
      expect(report.relations_unresolved).to eq(1)
      expect(report.errors).to eq([])
    end

    it 'resolves endpoint names case-insensitively like the old find_by did' do
      report = strategy.execute(
        import_data.merge(
          'relations' => [
            { 'from_name' => 'swimmer#name', 'from_type' => 'Method',
              'to_name' => 'SWIMMER#FIND', 'to_type' => 'Method',
              'relation_type' => 'calls', 'confidence' => 1.0 }
          ]
        ),
        decisions
      )

      expect(report.relations_unresolved).to eq(0)
      expect(
        MemoryRelation.exists?(
          from_entity: MemoryEntity.find_by(name: 'Swimmer#name'),
          to_entity: MemoryEntity.find_by(name: 'Swimmer#find'),
          relation_type: 'calls'
        )
      ).to be(true)
    end

    it 'is idempotent on a second run' do
      strategy.execute(import_data, decisions)
      report = described_class.new(observation_duplicate_detector: observation_duplicate_detector)
                          .execute(import_data, decisions)

      expect(report.relations_created).to eq(0)
      expect(MemoryRelation.where(relation_type: 'calls').count).to eq(1)
    end

    it 'omits the pass entirely when relations is absent' do
      data = { 'root_nodes' => [ { 'name' => 'Solo', 'entity_type' => 'Project', 'children' => [] } ] }
      report = strategy.execute(data, [ { node_path: '0', action: 'create' } ])

      expect(report.success).to be(true)
      expect(report.relations_unresolved).to eq(0)
    end

    it 'rejects hierarchical relation types instead of re-parenting' do
      report = strategy.execute(
        import_data.merge(
          'relations' => [
            { 'from_name' => 'Swimmer', 'from_type' => 'Class',
              'to_name' => 'Existing Project', 'to_type' => 'Project',
              'relation_type' => 'part_of' }
          ]
        ),
        decisions
      )

      swimmer = MemoryEntity.find_by(name: 'Swimmer')
      expect(report.success).to be(true)
      expect(report.relations_skipped).to eq(1)
      expect(
        MemoryRelation.where(from_entity_id: swimmer.id, relation_type: 'part_of').count
      ).to eq(1) # still parented under its import file, not re-parented
    end

    it 'skips an invalid edge instead of rolling back the import' do
      report = strategy.execute(
        import_data.merge(
          'relations' => import_data['relations'] + [
            { 'from_name' => 'Swimmer', 'from_type' => 'Class',
              'to_name' => 'ApplicationRecord', 'to_type' => 'Class',
              'relation_type' => 'calls', 'confidence' => 5.0 }
          ]
        ),
        decisions
      )

      expect(report.success).to be(true)
      expect(report.errors).to eq([])
      expect(report.relations_skipped).to eq(1)
      expect(report.relations_created).to eq(7) # the valid edges still applied
    end
  end

  describe 'exclude action (foreign subtrees)' do
    let(:import_data) do
      {
        'root_nodes' => [
          {
            'name' => 'RepoB',
            'entity_type' => 'Project',
            'children' => [
              {
                'name' => 'app/controllers/application_controller.rb',
                'entity_type' => 'File',
                'children' => [
                  { 'name' => 'ApplicationController', 'entity_type' => 'Class',
                    'children' => [
                      { 'name' => 'ApplicationController#beta_only', 'entity_type' => 'Method',
                        'children' => [] }
                    ] }
                ]
              }
            ]
          }
        ]
      }
    end

    let(:decisions) do
      [
        { node_path: '0', action: 'create' },
        { node_path: '0.children.0', child_action: 'exclude' },
        { node_path: '0.children.0.children.0', child_action: 'exclude' },
        { node_path: '0.children.0.children.0.children.0', child_action: 'exclude' }
      ]
    end

    it 'creates nothing under an excluded node — no orphans, counted as skipped' do
      report = strategy.execute(import_data, decisions)

      expect(report.success).to be(true)
      expect(MemoryEntity.find_by(name: 'RepoB')).to be_present
      expect(MemoryEntity.find_by(name: 'ApplicationController#beta_only')).to be_nil
      expect(MemoryEntity.find_by(name: 'ApplicationController')).to be_nil
      # the subtree root counts; its descendants are never reached
      expect(report.entities_skipped).to eq(1)
      # RepoB's root has no children attached
      repo_b = MemoryEntity.find_by(name: 'RepoB')
      expect(MemoryRelation.where(to_entity_id: repo_b.id, relation_type: 'part_of')).to be_empty
    end

    it 'allows in-subtree edges to excluded foreign endpoints, tagged cross_repo' do
      # RepoA's tree already exists; RepoB's import excludes the shared file
      # subtree but its relations payload still references entities in it.
      # A source inside the imported subtree bridging OUT is a legitimate
      # cross-repo edge: it lands, tagged, counted — only edges whose SOURCE
      # lives inside the excluded subtree are skipped (folded-A4 rule).
      foreign_file = MemoryEntity.create!(name: 'app/controllers/application_controller.rb', entity_type: 'File')
      foreign_class = MemoryEntity.create!(name: 'ApplicationController', entity_type: 'Class')
      MemoryRelation.create!(from_entity_id: foreign_class.id, to_entity_id: foreign_file.id,
                             relation_type: 'part_of')

      data_with_relations = import_data.deep_dup
      # Only endpoints flagged reference-only in the payload may bridge;
      # a declared endpoint matching a foreign entity is a name
      # collision, not a bridge — it skips and counts like before.
      data_with_relations['relations'] = [
        { 'from_name' => 'RepoB', 'from_type' => 'Project',
          'to_name' => 'ApplicationController', 'to_type' => 'Class',
          'relation_type' => 'depends_on',
          'properties' => { 'endpoint_reference' => true } },
        { 'from_name' => 'RepoB', 'from_type' => 'Project',
          'to_name' => 'app/controllers/application_controller.rb', 'to_type' => 'File',
          'relation_type' => 'depends_on',
          'properties' => { 'endpoint_reference' => true } },
        { 'from_name' => 'RepoB', 'from_type' => 'Project',
          'to_name' => 'ApplicationController', 'to_type' => 'Class',
          'relation_type' => 'belongs_to' }
      ]

      report = strategy.execute(data_with_relations, decisions)

      expect(report.success).to be(true)
      expect(report.relations_created).to eq(2)
      expect(report.relations_cross_repo).to eq(2)
      expect(report.relations_skipped).to eq(1)
      expect(MemoryRelation.where(relation_type: 'depends_on').count).to eq(2)
      expect(MemoryRelation.where(relation_type: 'depends_on')
              .map { |r| r.properties['cross_repo'] }.uniq).to eq([ true ])
    end
  end

  describe 'bulk-import callback suppression' do
    let(:import_data) do
      {
        'root_nodes' => [
          { 'name' => 'Bulk Project', 'entity_type' => 'Project',
            'observations' => [ { 'content' => 'some fact' } ], 'children' => [] }
        ]
      }
    end
    let(:decisions) { [ { node_path: '0', action: 'create' } ] }

    it 'suppresses inline embeddings and enqueues a maintenance backfill' do
      entity_embedder = instance_double(EmbeddingService)
      allow(EmbeddingService).to receive(:embed_entity).and_raise('should not be called')
      allow(EmbeddingService).to receive(:embed_observation).and_raise('should not be called')
      expect(EmbeddingsMaintenanceEnqueuer).to receive(:enqueue!).with('backfill')

      report = strategy.execute(import_data, decisions)
      expect(report.success).to be(true)
    end

    it 'degrades observation de-duplication to exact matching while suppressed' do
      entity = MemoryEntity.create!(name: 'Existing', entity_type: 'Project', aliases: '')
      MemoryObservation.create!(memory_entity: entity, content: 'verbatim fact')

      flagged = nil
      EmbeddingService.suppress_inline_embeddings do
        flagged = EmbeddingService.inline_embeddings_suppressed?
        # Stored rows are unembedded inside a suppressed import — semantic
        # dedup degrades to exact matching rather than raising.
        allow(EmbeddingService).to receive(:vector_enabled?).and_return(true)
        result = ImportObservationDuplicateDetector.new.find_duplicate(
          entity: entity, content: 'a semantically similar but different fact'
        )
        expect(result.duplicate).to be(false)
      end
      expect(flagged).to be(true)
    end
  end

  describe '#execute rescan (A3)' do
    let!(:project) { MemoryEntity.create!(name: 'Scan Project', entity_type: 'Project') }
    let!(:file_entity) { MemoryEntity.create!(name: 'foo.rb', entity_type: 'File') }
    let!(:class_entity) { MemoryEntity.create!(name: 'Foo', entity_type: 'Class') }
    let!(:part1) do
      MemoryRelation.create!(from_entity: file_entity, to_entity: project, relation_type: 'part_of')
    end
    let!(:part2) do
      MemoryRelation.create!(from_entity: class_entity, to_entity: file_entity, relation_type: 'part_of')
    end
    let!(:file_obs) do
      MemoryObservation.create!(memory_entity: file_entity, content: 'Defined at lib/foo.rb', source: 'graphify')
    end
    let!(:class_obs) do
      MemoryObservation.create!(memory_entity: class_entity, content: 'Defined at lib/foo.rb:10', source: 'graphify')
    end
    let!(:edge) do
      MemoryRelation.create!(from_entity: class_entity, to_entity: file_entity,
                             relation_type: 'calls', properties: { 'source' => 'graphify' })
    end

    def provenance(content)
      { 'content' => content, 'source' => 'graphify', 'confidence' => 1.0 }
    end

    let(:same_payload) do
      {
        'rescan' => true,
        'root_nodes' => [
          {
            'name' => 'Scan Project', 'entity_type' => 'Project',
            'children' => [
              {
                'name' => 'foo.rb', 'entity_type' => 'File', 'relation_type' => 'part_of',
                'observations' => [ provenance('Defined at lib/foo.rb') ],
                'children' => [
                  {
                    'name' => 'Foo', 'entity_type' => 'Class', 'relation_type' => 'part_of',
                    'observations' => [ provenance('Defined at lib/foo.rb:10') ],
                    'children' => []
                  }
                ]
              }
            ]
          }
        ],
        'relations' => [
          { 'from_name' => 'Foo', 'from_type' => 'Class',
            'to_name' => 'foo.rb', 'to_type' => 'File', 'relation_type' => 'calls' }
        ]
      }
    end

    let(:removed_class_payload) do
      payload = Marshal.load(Marshal.dump(same_payload))
      file_node = payload['root_nodes'][0]['children'][0]
      file_node['children'] = []
      payload['relations'] = []
      payload
    end

    let(:merge_decisions) do
      [ { node_path: '0', action: 'merge', target_id: project.id } ]
    end

    it 'runs a clean rescan: no obsoletion, no review items, idempotent' do
      report = strategy.execute(same_payload, merge_decisions)

      expect(report.rescan).to be(true)
      expect(report.observations_obsoleted).to eq(0)
      expect(report.observations_superseded).to eq(0)
      expect(report.rescan_entities_flagged).to eq(0)
      expect(report.rescan_relations_flagged).to eq(0)
      expect(file_obs.reload).to be_active
      expect(class_obs.reload).to be_active
      expect(MaintenanceReportRow.by_report_type('scan_review')).to be_empty
    end

    it 'obsoletes provenance of a vanished entity and queues a delete_entity review item' do
      report = strategy.execute(removed_class_payload, merge_decisions)

      expect(report.rescan).to be(true)
      expect(report.observations_obsoleted).to eq(1)
      expect(report.rescan_entities_flagged).to eq(1)
      expect(class_obs.reload).to be_obsolete
      expect(class_obs.obsolescence_reason).to include('graphify rescan')
      expect(class_entity.reload).to be_present # never auto-deleted

      row = MaintenanceReportRow.by_report_type('scan_review').pending.find_by(kind: 'delete_entity')
      expect(row).to be_present
      expect(row.effective_payload['entity_id']).to eq(class_entity.id)
    end

    it 'flags a removed graphify edge as a delete_relation review item' do
      payload = Marshal.load(Marshal.dump(same_payload))
      payload['relations'] = []

      report = strategy.execute(payload, merge_decisions)

      expect(report.rescan_relations_flagged).to eq(1)
      expect(edge.reload).to be_present # review-only, never auto-deleted

      row = MaintenanceReportRow.by_report_type('scan_review').pending.find_by(kind: 'delete_relation')
      expect(row).to be_present
      expect(row.effective_payload['relation_id']).to eq(edge.id)
    end

    it 'supersedes drifted provenance and lets merge dedup stay quiet' do
      payload = Marshal.load(Marshal.dump(same_payload))
      class_node = payload['root_nodes'][0]['children'][0]['children'][0]
      class_node['observations'] = [ provenance('Defined at lib/foo.rb:20') ]

      report = strategy.execute(payload, merge_decisions)

      expect(report.observations_superseded).to eq(1)
      expect(report.observations_obsoleted).to eq(0)

      class_obs.reload
      expect(class_obs.status).to eq(MemoryObservation::SUPERSEDED_STATUS)
      replacement = class_obs.superseded_by
      expect(replacement).to be_present
      expect(replacement.content).to eq('Defined at lib/foo.rb:20')
      expect(replacement).to be_active

      # The supersede replacement satisfies merge dedup — no duplicate row.
      active_contents = class_entity.memory_observations.active.where(source: 'graphify').pluck(:content)
      expect(active_contents).to eq([ 'Defined at lib/foo.rb:20' ])
    end

    it 'does not rescan when the payload lacks the rescan marker' do
      payload = removed_class_payload.except('rescan')
      report = strategy.execute(payload, merge_decisions)

      expect(report.rescan).to be(false)
      expect(report.observations_obsoleted).to eq(0)
      expect(class_obs.reload).to be_active
    end

    it 'does not rescan on a first import (no stored graphify entities)' do
      file_obs.destroy!
      class_obs.destroy!
      class_entity.destroy!
      part2.destroy!

      report = strategy.execute(same_payload, merge_decisions)
      expect(report.rescan).to be(false)
    end

    it 'supersedes L-prefixed line drift as a same-file change' do
      class_obs.update!(content: 'Defined at lib/foo.rb:L10')
      payload = Marshal.load(Marshal.dump(same_payload))
      class_node = payload['root_nodes'][0]['children'][0]['children'][0]
      class_node['observations'] = [ provenance('Defined at lib/foo.rb:L20') ]

      report = strategy.execute(payload, merge_decisions)

      expect(report.observations_superseded).to eq(1)
      expect(report.observations_obsoleted).to eq(0)
      expect(class_obs.reload.superseded_by.content).to eq('Defined at lib/foo.rb:L20')
    end

    it 'queues a reparent_entity item for a same-tree move and applies new provenance' do
      other_file = MemoryEntity.create!(name: 'bar.rb', entity_type: 'File')
      MemoryRelation.create!(from_entity: other_file, to_entity: project, relation_type: 'part_of')
      MemoryObservation.create!(memory_entity: other_file, content: 'Defined at lib/bar.rb',
                                source: 'graphify')

      payload = Marshal.load(Marshal.dump(same_payload))
      project_node = payload['root_nodes'][0]
      foo_node = project_node['children'][0]
      class_node = foo_node['children'].delete_at(0)
      project_node['children'] << {
        'name' => 'bar.rb', 'entity_type' => 'File', 'relation_type' => 'part_of',
        'observations' => [ provenance('Defined at lib/bar.rb') ],
        'children' => [ class_node ]
      }

      decisions = merge_decisions + [
        { node_path: '0.children.0', action: 'skip' },
        { node_path: '0.children.1', action: 'skip' },
        { node_path: '0.children.1.children.0', action: 'skip' }
      ]
      report = strategy.execute(payload, decisions)

      expect(report.rescan_reparents_flagged).to eq(1)
      row = MaintenanceReportRow.by_report_type('scan_review').pending.find_by(kind: 'reparent_entity')
      expect(row).to be_present
      expect(row.effective_payload['entity_id']).to eq(class_entity.id)
      expect(row.effective_payload['parent_id']).to eq(other_file.id)
      expect(part2.reload).to be_present # unattended imports never re-parent
    end

    def stale_scan_row(kind:, payload:, signature_payload:)
      report = MaintenanceReport.create!(report_type: 'scan_review', data: { 'source' => 'graphify' })
      MaintenanceReportRow.create!(
        maintenance_report: report,
        report_type: 'scan_review',
        row_uuid: "stale-#{kind}-#{payload.values.first}",
        kind: kind,
        status: 'active',
        signature: CompactionReviewService.signature_for(kind, signature_payload),
        payload: payload
      )
    end

    it 'dismisses a pending delete proposal when the target returns' do
      stale = stale_scan_row(
        kind: 'delete_entity',
        payload: { 'entity_id' => class_entity.id, 'entity_name' => 'Foo' },
        signature_payload: { entity_id: class_entity.id }
      )

      strategy.execute(same_payload, merge_decisions)

      expect(stale.reload.status).to eq('dismissed')
      expect(stale.resolution_reason).to include('stale')
    end

    it 'dismisses a pending delete_relation proposal when the edge returns' do
      stale = stale_scan_row(
        kind: 'delete_relation',
        payload: { 'relation_id' => edge.id },
        signature_payload: { relation_id: edge.id }
      )

      strategy.execute(same_payload, merge_decisions)

      expect(stale.reload.status).to eq('dismissed')
    end

    it 'retires a reparent proposal the payload no longer asks for' do
      stale = stale_scan_row(
        kind: 'reparent_entity',
        payload: { 'entity_id' => class_entity.id, 'parent_id' => file_entity.id },
        signature_payload: { entity_id: class_entity.id, parent_id: file_entity.id }
      )

      strategy.execute(same_payload, merge_decisions) # stored parent already matches

      expect(stale.reload.status).to eq('dismissed')
    end

    it 'counts only newly seeded flags on a re-run and skips the empty report' do
      first = strategy.execute(removed_class_payload, merge_decisions)
      expect(first.rescan_entities_flagged).to eq(1)

      expect do
        second = strategy.execute(removed_class_payload, merge_decisions)
        expect(second.rescan_entities_flagged).to eq(0)
      end.not_to change(MaintenanceReport, :count)

      expect(MaintenanceReportRow.by_report_type('scan_review').pending.where(kind: 'delete_entity').count)
        .to eq(1)
    end

    # Foo moved from foo.rb to a stored bar.rb — same helpers as the
    # reparent spec above: skip decisions keep Foo in place so reparent_diff
    # flags the move.
    def moved_foo_setup
      other_file = MemoryEntity.create!(name: 'bar.rb', entity_type: 'File')
      MemoryRelation.create!(from_entity: other_file, to_entity: project, relation_type: 'part_of')
      MemoryObservation.create!(memory_entity: other_file, content: 'Defined at lib/bar.rb',
                                source: 'graphify')

      payload = Marshal.load(Marshal.dump(same_payload))
      project_node = payload['root_nodes'][0]
      foo_node = project_node['children'][0]
      class_node = foo_node['children'].delete_at(0)
      project_node['children'] << {
        'name' => 'bar.rb', 'entity_type' => 'File', 'relation_type' => 'part_of',
        'observations' => [ provenance('Defined at lib/bar.rb') ],
        'children' => [ class_node ]
      }
      decisions = merge_decisions + [
        { node_path: '0.children.0', action: 'skip' },
        { node_path: '0.children.1', action: 'skip' },
        { node_path: '0.children.1.children.0', action: 'skip' }
      ]
      [ payload, decisions ]
    end

    it 'leaves an unapplied identical move proposal alone on a re-run' do
      payload, decisions = moved_foo_setup
      first = strategy.execute(payload, decisions)
      expect(first.rescan_reparents_flagged).to eq(1)

      expect do
        second = strategy.execute(payload, decisions)
        expect(second.rescan_reparents_flagged).to eq(0)
      end.not_to change(MaintenanceReport, :count)
      expect(MaintenanceReportRow.by_report_type('scan_review').pending.where(kind: 'reparent_entity').count).to eq(1)
    end

    it 'keeps an operator-ignored reparent proposal ignored on a re-run' do
      payload, decisions = moved_foo_setup
      strategy.execute(payload, decisions)
      row = MaintenanceReportRow.by_report_type('scan_review').find_by(kind: 'reparent_entity')
      row.update!(status: 'ignored')

      expect { strategy.execute(payload, decisions) }.not_to change(MaintenanceReport, :count)
      expect(row.reload.status).to eq('ignored')
      expect(MaintenanceReportRow.by_report_type('scan_review').where(kind: 'reparent_entity').count).to eq(1)
    end

    it "leaves another project's pending reparent proposal alone" do
      foreign = MemoryEntity.create!(name: 'Alien', entity_type: 'Class')
      foreign_parent = MemoryEntity.create!(name: 'elsewhere.rb', entity_type: 'File')
      stale = stale_scan_row(
        kind: 'reparent_entity',
        payload: { 'entity_id' => foreign.id, 'parent_id' => foreign_parent.id },
        signature_payload: { entity_id: foreign.id, parent_id: foreign_parent.id }
      )

      strategy.execute(same_payload, merge_decisions)

      expect(stale.reload.status).to eq('active')
    end

    it 'retires a reparent proposal whose entity was deleted' do
      ghost = MemoryEntity.create!(name: 'Ghost', entity_type: 'Class')
      MemoryRelation.create!(from_entity: ghost, to_entity: project, relation_type: 'part_of')
      MemoryObservation.create!(memory_entity: ghost, content: 'Defined at lib/ghost.rb', source: 'graphify')
      stale = stale_scan_row(
        kind: 'reparent_entity',
        payload: { 'entity_id' => ghost.id, 'parent_id' => file_entity.id },
        signature_payload: { entity_id: ghost.id, parent_id: file_entity.id }
      )
      ghost.destroy!

      strategy.execute(same_payload, merge_decisions)

      expect(stale.reload.status).to eq('dismissed')
    end

    it 'resolves the reparent target through the import mapping, not the namesake' do
      payload, decisions = moved_foo_setup
      bar_namesake = MemoryEntity.find_by!(name: 'bar.rb', entity_type: 'File') # moved_foo_setup's
      # The bar.rb payload node merges onto a DIFFERENTLY-named entity:
      # a global name+type lookup would point the proposal at bar_namesake.
      moved_here = MemoryEntity.create!(name: 'moved_here.rb', entity_type: 'File')
      decisions = decisions.map do |d|
        d[:node_path] == '0.children.1' ? d.merge(action: 'merge', target_id: moved_here.id) : d
      end

      report = strategy.execute(payload, decisions)

      row = MaintenanceReportRow.by_report_type('scan_review').pending.find_by(kind: 'reparent_entity')
      expect(report.rescan_reparents_flagged).to eq(1)
      expect(row.effective_payload['parent_id']).to eq(moved_here.id)
      expect(row.effective_payload['parent_id']).not_to eq(bar_namesake.id)
    end

    it 'keeps a pending delete proposal when the target is still absent' do
      stale = stale_scan_row(
        kind: 'delete_entity',
        payload: { 'entity_id' => class_entity.id, 'entity_name' => 'Foo' },
        signature_payload: { entity_id: class_entity.id }
      )

      strategy.execute(removed_class_payload, merge_decisions)

      expect(stale.reload.status).to eq('active')
    end

    it 'diffs the operator merge target, not the payload namesake' do
      other_root = MemoryEntity.create!(name: 'Other Project', entity_type: 'Project')
      other_file = MemoryEntity.create!(name: 'ghost.rb', entity_type: 'File')
      MemoryRelation.create!(from_entity: other_file, to_entity: other_root, relation_type: 'part_of')
      ghost_obs = MemoryObservation.create!(memory_entity: other_file, content: 'Defined at ghost.rb',
                                            source: 'graphify')
      other_decisions = [ { node_path: '0', action: 'merge', target_id: other_root.id } ]

      report = strategy.execute(same_payload, other_decisions)

      # Diffed Other Project's subtree: ghost.rb vanished from the payload.
      expect(report.rescan).to be(true)
      expect(ghost_obs.reload).to be_obsolete
      # And the payload namesake's subtree stayed untouched.
      expect(class_obs.reload).to be_active
    end

    it 'reports no rescan activity when the import fails mid-tree' do
      payload = Marshal.load(Marshal.dump(removed_class_payload))
      # Force a failure inside the transaction: a relation row that raises.
      allow_any_instance_of(described_class).to receive(:process_node_recursive)
        .and_wrap_original do |method, node, path, decision_map, parent_entity_id, tree_parent_id|
          raise ActiveRecord::StatementInvalid, 'boom' if path == '0'
          method.call(node, path, decision_map, parent_entity_id, tree_parent_id)
        end

      report = strategy.execute(payload, merge_decisions)

      expect(report.success).to be(false)
      expect(report.rescan).to be(false)
      expect(report.rescan_entities_flagged).to eq(0)
      expect(report.observations_obsoleted).to eq(0)
      expect(class_obs.reload).to be_active # rolled back
    end
  end
end
