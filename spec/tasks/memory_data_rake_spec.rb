require 'rails_helper'
require 'rake'

describe 'db:memory_data rake tasks', type: :task do
  # Load all rake tasks
  before(:all) do
    Rails.application.load_tasks
  end

  # Re-enable tasks after each run, as they are only invoked once by default
  after(:each) do
    Rake::Task['db:migrate_json'].reenable
    Rake::Task['db:append_json'].reenable
  end

  # Helper to create a temporary JSON lines file
  let(:create_temp_json_file) do
    lambda do |data|
      temp_file = Tempfile.new(['memory_data', '.json'])
      data.each { |line| temp_file.puts(line.to_json) }
      temp_file.close
      temp_file.path
    end
  end

  # Initial data for migration
  let(:initial_json_data) do
    [
      { type: 'entity', name: 'Project Alpha', entityType: 'Project', observations: ['Is a cool project', 'Has one team member'] },
      { type: 'entity', name: 'Team Member 1', entityType: 'Person' },
      { type: 'relation', from: 'Project Alpha', to: 'Team Member 1', relationType: 'has_member' }
    ]
  end

  # Data for appending
  let(:append_json_data) do
    [
      # Update existing entity with a new observation
      { type: 'entity', name: 'Project Alpha', entityType: 'Project', observations: ['Is a cool project', 'Has a deadline'] },
      # Add a new entity
      { type: 'entity', name: 'Project Beta', entityType: 'Project', observations: ['A new project'] },
      # Add a new relation
      { type: 'relation', from: 'Project Beta', to: 'Team Member 1', relationType: 'has_member' },
      # This relation should be skipped as it already exists
      { type: 'relation', from: 'Project Alpha', to: 'Team Member 1', relationType: 'has_member' }
    ]
  end

  describe 'db:migrate_json' do
    let(:json_file_path) { create_temp_json_file.call(initial_json_data) }

    before do
      # Ensure DB is clean before migration
      MemoryRelation.delete_all
      MemoryObservation.delete_all
      MemoryEntity.delete_all
    end

    it 'populates the database from the JSON file' do
      Rake::Task['db:migrate_json'].invoke(json_file_path)

      expect(MemoryEntity.count).to eq(2)
      expect(MemoryObservation.count).to eq(2)
      expect(MemoryRelation.count).to eq(1)

      project_alpha = MemoryEntity.find_by(name: 'Project Alpha')
      expect(project_alpha).not_to be_nil
      expect(project_alpha.memory_observations.count).to eq(2)
      expect(project_alpha.memory_observations.map(&:content)).to contain_exactly('Is a cool project', 'Has one team member')
    end

    it 'clears existing data before migrating' do
      # Pre-seed the database
      MemoryEntity.create!(name: 'Old Project', entity_type: 'Project')
      expect(MemoryEntity.find_by(name: 'Old Project')).not_to be_nil

      Rake::Task['db:migrate_json'].invoke(json_file_path)

      expect(MemoryEntity.find_by(name: 'Old Project')).to be_nil
      expect(MemoryEntity.count).to eq(2)
    end
  end

  describe 'db:append_json' do
    let(:initial_file_path) { create_temp_json_file.call(initial_json_data) }
    let(:append_file_path) { create_temp_json_file.call(append_json_data) }

    before do
      # Setup initial state by running migrate_json first
      MemoryRelation.delete_all
      MemoryObservation.delete_all
      MemoryEntity.delete_all
      Rake::Task['db:migrate_json'].invoke(initial_file_path)
      Rake::Task['db:migrate_json'].reenable # Re-enable for the next test if needed
    end

    it 'appends new data without clearing existing data' do
      # Confirm initial state
      expect(MemoryEntity.count).to eq(2)
      expect(MemoryObservation.count).to eq(2)
      expect(MemoryRelation.count).to eq(1)

      # Run the append task
      Rake::Task['db:append_json'].invoke(append_file_path)

      # Check totals
      expect(MemoryEntity.count).to eq(3) # Initial 2 + 1 new
      expect(MemoryObservation.count).to eq(4) # Initial 2 + 1 new on existing entity + 1 on new entity
      expect(MemoryRelation.count).to eq(2) # Initial 1 + 1 new

      # Check Project Alpha (existing entity)
      project_alpha = MemoryEntity.find_by(name: 'Project Alpha')
      expect(project_alpha.memory_observations.count).to eq(3)
      expect(project_alpha.memory_observations.map(&:content)).to contain_exactly('Is a cool project', 'Has one team member', 'Has a deadline')

      # Check Project Beta (new entity)
      project_beta = MemoryEntity.find_by(name: 'Project Beta')
      expect(project_beta).not_to be_nil
      expect(project_beta.memory_observations.count).to eq(1)
      expect(project_beta.memory_observations.first.content).to eq('A new project')

      # Check new relation
      team_member = MemoryEntity.find_by(name: 'Team Member 1')
      new_relation = MemoryRelation.find_by(from_entity: project_beta, to_entity: team_member)
      expect(new_relation).not_to be_nil
      expect(new_relation.relation_type).to eq('has_member')
    end
  end
end
