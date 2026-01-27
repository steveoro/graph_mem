# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExportStrategy, type: :model do
  let(:strategy) { described_class.new }

  # Setup test data with a graph structure
  let!(:project1) do
    MemoryEntity.create!(
      name: 'Project Alpha',
      entity_type: 'Project',
      aliases: 'alpha, project-a'
    )
  end

  let!(:project2) do
    MemoryEntity.create!(
      name: 'Project Beta',
      entity_type: 'Project',
      aliases: 'beta'
    )
  end

  let!(:task1) do
    MemoryEntity.create!(
      name: 'Task One',
      entity_type: 'Task',
      aliases: 'task-1'
    )
  end

  let!(:task2) do
    MemoryEntity.create!(
      name: 'Task Two',
      entity_type: 'Task',
      aliases: 'task-2'
    )
  end

  let!(:orphan_entity) do
    MemoryEntity.create!(
      name: 'Orphan Node',
      entity_type: 'Other',
      aliases: ''
    )
  end

  let!(:observation1) do
    MemoryObservation.create!(
      memory_entity: project1,
      content: 'This is the first observation'
    )
  end

  let!(:observation2) do
    MemoryObservation.create!(
      memory_entity: project1,
      content: 'This is the second observation'
    )
  end

  let!(:task_observation) do
    MemoryObservation.create!(
      memory_entity: task1,
      content: 'Task observation content'
    )
  end

  # Create relations: task1 is part_of project1
  let!(:relation1) do
    MemoryRelation.create!(
      from_entity: task1,
      to_entity: project1,
      relation_type: 'part_of'
    )
  end

  # task2 depends_on task1
  let!(:relation2) do
    MemoryRelation.create!(
      from_entity: task2,
      to_entity: task1,
      relation_type: 'depends_on'
    )
  end

  describe '#root_nodes' do
    it 'returns entities with no incoming part_of or depends_on relations' do
      roots = strategy.root_nodes

      root_names = roots.map(&:name)
      expect(root_names).to include('Project Alpha', 'Project Beta', 'Orphan Node')
      expect(root_names).not_to include('Task One', 'Task Two')
    end

    it 'returns Projects first, sorted by name' do
      roots = strategy.root_nodes

      # First entities should be Projects
      projects = roots.take_while { |e| e.entity_type == 'Project' }
      project_names = projects.map(&:name)

      expect(project_names).to eq(['Project Alpha', 'Project Beta'])
    end

    it 'returns other root entities after Projects, sorted by name' do
      roots = strategy.root_nodes
      non_projects = roots.reject { |e| e.entity_type == 'Project' }

      expect(non_projects.first.name).to eq('Orphan Node')
    end
  end

  describe '#export' do
    context 'with empty entity_ids' do
      it 'returns empty export structure for nil' do
        result = strategy.export(nil)

        expect(result[:version]).to eq(ExportStrategy::FORMAT_VERSION)
        expect(result[:exported_at]).to be_present
        expect(result[:root_nodes]).to eq([])
      end

      it 'returns empty export structure for empty array' do
        result = strategy.export([])

        expect(result[:root_nodes]).to eq([])
      end
    end

    context 'with single entity' do
      it 'exports entity with its observations' do
        result = strategy.export([project1.id])

        expect(result[:root_nodes].length).to eq(1)

        root_node = result[:root_nodes].first
        expect(root_node[:name]).to eq('Project Alpha')
        expect(root_node[:entity_type]).to eq('Project')
        expect(root_node[:aliases]).to eq('alpha, project-a')
        expect(root_node[:observations].length).to eq(2)
      end

      it 'includes children through part_of relations' do
        result = strategy.export([project1.id])

        root_node = result[:root_nodes].first
        children = root_node[:children]

        expect(children.length).to be >= 1

        task_child = children.find { |c| c[:name] == 'Task One' }
        expect(task_child).to be_present
        expect(task_child[:entity_type]).to eq('Task')
        expect(task_child[:relation_type]).to eq('part_of')
      end

      it 'recursively includes nested children' do
        result = strategy.export([project1.id])

        root_node = result[:root_nodes].first
        task_child = root_node[:children].find { |c| c[:name] == 'Task One' }

        expect(task_child[:children]).to be_present
        task2_child = task_child[:children].find { |c| c[:name] == 'Task Two' }
        expect(task2_child).to be_present
        expect(task2_child[:relation_type]).to eq('depends_on')
      end

      it 'includes observations for child entities' do
        result = strategy.export([project1.id])

        root_node = result[:root_nodes].first
        task_child = root_node[:children].find { |c| c[:name] == 'Task One' }

        expect(task_child[:observations].length).to eq(1)
        expect(task_child[:observations].first[:content]).to eq('Task observation content')
      end
    end

    context 'with multiple entities' do
      it 'exports multiple root nodes' do
        result = strategy.export([project1.id, project2.id])

        expect(result[:root_nodes].length).to eq(2)

        root_names = result[:root_nodes].map { |r| r[:name] }
        expect(root_names).to contain_exactly('Project Alpha', 'Project Beta')
      end
    end

    context 'cycle detection' do
      it 'handles circular relations without infinite loop' do
        # Create a circular relation: project1 -> task1 -> project1
        MemoryRelation.create!(
          from_entity: project1,
          to_entity: task1,
          relation_type: 'relates_to'
        )

        # This should not hang
        expect { strategy.export([project1.id]) }.not_to raise_error
      end
    end

    context 'export format' do
      it 'includes version in export' do
        result = strategy.export([project1.id])
        expect(result[:version]).to eq('1.0')
      end

      it 'includes exported_at timestamp' do
        result = strategy.export([project1.id])
        expect(result[:exported_at]).to be_present
        expect { Time.parse(result[:exported_at]) }.not_to raise_error
      end

      it 'includes observation created_at in ISO8601 format' do
        result = strategy.export([project1.id])

        root_node = result[:root_nodes].first
        obs = root_node[:observations].first

        expect(obs[:created_at]).to be_present
        expect { Time.parse(obs[:created_at]) }.not_to raise_error
      end
    end
  end

  describe '#export_json' do
    it 'returns valid JSON string' do
      json = strategy.export_json([project1.id])

      expect(json).to be_a(String)
      expect { JSON.parse(json) }.not_to raise_error
    end

    it 'produces pretty-printed JSON' do
      json = strategy.export_json([project1.id])

      # Pretty-printed JSON has newlines
      expect(json).to include("\n")
    end

    it 'parses back to the same structure' do
      json = strategy.export_json([project1.id])
      parsed = JSON.parse(json)

      expect(parsed['version']).to eq('1.0')
      expect(parsed['root_nodes']).to be_an(Array)
    end
  end

  describe 'constants' do
    it 'defines FORMAT_VERSION' do
      expect(ExportStrategy::FORMAT_VERSION).to eq('1.0')
    end

    it 'defines CHILD_RELATION_TYPES' do
      expect(ExportStrategy::CHILD_RELATION_TYPES).to contain_exactly('part_of', 'depends_on')
    end
  end
end
