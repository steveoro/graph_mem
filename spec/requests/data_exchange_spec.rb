# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'DataExchange', type: :request do
  # Setup test data
  let!(:project1) do
    MemoryEntity.create!(
      name: 'Project Alpha',
      entity_type: 'Project',
      aliases: 'alpha'
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
      aliases: ''
    )
  end

  let!(:observation1) do
    MemoryObservation.create!(
      memory_entity: project1,
      content: 'Test observation'
    )
  end

  let!(:relation1) do
    MemoryRelation.create!(
      from_entity: task1,
      to_entity: project1,
      relation_type: 'part_of'
    )
  end

  describe 'GET /data_exchange/root_nodes' do
    it 'returns list of root nodes as JSON' do
      get root_nodes_data_exchange_index_path

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['nodes']).to be_an(Array)
      expect(data['nodes'].length).to eq(2) # project1 and project2 are roots

      node_names = data['nodes'].map { |n| n['name'] }
      expect(node_names).to include('Project Alpha', 'Project Beta')
    end

    it 'includes entity details' do
      get root_nodes_data_exchange_index_path

      data = JSON.parse(response.body)
      node = data['nodes'].find { |n| n['name'] == 'Project Alpha' }

      expect(node['id']).to eq(project1.id)
      expect(node['entity_type']).to eq('Project')
      expect(node['observations_count']).to eq(1)
    end
  end

  describe 'GET /data_exchange/export' do
    context 'with valid entity IDs' do
      it 'returns JSON file download' do
        get export_data_exchange_index_path, params: { ids: [ project1.id ] }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include('application/json')
        expect(response.headers['Content-Disposition']).to include('attachment')
      end

      it 'exports selected entities with children' do
        get export_data_exchange_index_path, params: { ids: [ project1.id ] }

        data = JSON.parse(response.body)

        expect(data['version']).to eq('1.0')
        expect(data['root_nodes']).to be_an(Array)
        expect(data['root_nodes'].length).to eq(1)

        root_node = data['root_nodes'].first
        expect(root_node['name']).to eq('Project Alpha')
        expect(root_node['observations'].length).to eq(1)
      end

      it 'includes child entities' do
        get export_data_exchange_index_path, params: { ids: [ project1.id ] }

        data = JSON.parse(response.body)
        root_node = data['root_nodes'].first

        child_names = root_node['children'].map { |c| c['name'] }
        expect(child_names).to include('Task One')
      end
    end

    context 'with no entity IDs' do
      it 'returns error' do
        get export_data_exchange_index_path

        expect(response).to have_http_status(:unprocessable_content)
        data = JSON.parse(response.body)
        expect(data['error']).to eq('No entity IDs provided')
      end
    end

    context 'with multiple entity IDs' do
      it 'exports multiple root nodes' do
        get export_data_exchange_index_path, params: { ids: [ project1.id, project2.id ] }

        data = JSON.parse(response.body)
        expect(data['root_nodes'].length).to eq(2)
      end
    end
  end

  describe 'POST /data_exchange/import_upload' do
    context 'with valid JSON file' do
      let(:valid_json) do
        {
          version: '1.0',
          exported_at: '2026-01-27T12:00:00Z',
          root_nodes: [
            {
              name: 'New Project',
              entity_type: 'Project',
              observations: [],
              children: []
            }
          ]
        }.to_json
      end

      let(:uploaded_file) do
        Rack::Test::UploadedFile.new(
          StringIO.new(valid_json),
          'application/json',
          original_filename: 'import.json'
        )
      end

      it 'redirects to import review page' do
        post import_upload_data_exchange_index_path, params: { file: uploaded_file }

        expect(response).to redirect_to(import_review_data_exchange_index_path)
      end

      it 'stores import data in session' do
        post import_upload_data_exchange_index_path, params: { file: uploaded_file }

        # Follow redirect and check session data is available
        follow_redirect!
        expect(response).to have_http_status(:ok)
      end
    end

    context 'with no file' do
      it 'redirects with error' do
        post import_upload_data_exchange_index_path

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(flash[:error]).to eq('Please select a file to import')
      end
    end

    context 'with invalid JSON file' do
      let(:invalid_json) { 'not valid json {' }

      let(:uploaded_file) do
        Rack::Test::UploadedFile.new(
          StringIO.new(invalid_json),
          'application/json',
          original_filename: 'invalid.json'
        )
      end

      it 'redirects with error' do
        post import_upload_data_exchange_index_path, params: { file: uploaded_file }

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(flash[:error]).to include('Invalid JSON file')
      end
    end
  end

  describe 'GET /data_exchange/import_review' do
    context 'with no session data' do
      it 'redirects to root with error' do
        get import_review_data_exchange_index_path

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(flash[:error]).to include('No import data found')
      end
    end

    context 'with session data' do
      before do
        # First upload a file to set session data
        valid_json = {
          version: '1.0',
          root_nodes: [
            { name: 'Test', entity_type: 'Project', observations: [], children: [] }
          ]
        }.to_json

        uploaded_file = Rack::Test::UploadedFile.new(
          StringIO.new(valid_json),
          'application/json',
          original_filename: 'test.json'
        )

        post import_upload_data_exchange_index_path, params: { file: uploaded_file }
      end

      it 'renders the review page' do
        get import_review_data_exchange_index_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Import Review')
      end
    end
  end

  describe 'POST /data_exchange/import_execute' do
    context 'with no session data' do
      it 'redirects to root with error' do
        post import_execute_data_exchange_index_path

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(flash[:error]).to include('No import data found')
      end
    end

    context 'with session data' do
      before do
        valid_json = {
          version: '1.0',
          root_nodes: [
            {
              name: 'Imported Project',
              entity_type: 'Project',
              aliases: '',
              observations: [ { content: 'Imported observation' } ],
              children: []
            }
          ]
        }.to_json

        uploaded_file = Rack::Test::UploadedFile.new(
          StringIO.new(valid_json),
          'application/json',
          original_filename: 'test.json'
        )

        post import_upload_data_exchange_index_path, params: { file: uploaded_file }
      end

      it 'creates new entities and redirects to report' do
        expect {
          post import_execute_data_exchange_index_path, params: {
            decisions: {
              '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
            }
          }
        }.to change(MemoryEntity, :count).by(1)

        expect(response).to redirect_to(import_report_data_exchange_index_path)
      end

      it 'creates observations' do
        expect {
          post import_execute_data_exchange_index_path, params: {
            decisions: {
              '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
            }
          }
        }.to change(MemoryObservation, :count).by(1)
      end

      it 'can merge into existing entity' do
        post import_execute_data_exchange_index_path, params: {
          decisions: {
            '0' => { node_path: '0', action: 'merge', target_id: project1.id.to_s, parent_id: '' }
          }
        }

        expect(response).to redirect_to(import_report_data_exchange_index_path)

        # Should not create new entity
        expect(MemoryEntity.where(name: 'Imported Project')).not_to exist
      end
    end

    context 'with child nodes (merged decisions)' do
      before do
        # Create import data with root and child nodes
        json_with_children = {
          version: '1.0',
          root_nodes: [
            {
              name: 'Parent Project',
              entity_type: 'Project',
              aliases: '',
              observations: [],
              children: [
                {
                  name: 'Child Task New',
                  entity_type: 'Task',
                  aliases: '',
                  relation_type: 'part_of',
                  observations: [ { content: 'Child observation' } ],
                  children: []
                },
                {
                  name: 'Task One',  # This exists in the DB
                  entity_type: 'Task',
                  aliases: '',
                  relation_type: 'part_of',
                  observations: [ { content: 'New observation for existing task' } ],
                  children: []
                }
              ]
            }
          ]
        }.to_json

        uploaded_file = Rack::Test::UploadedFile.new(
          StringIO.new(json_with_children),
          'application/json',
          original_filename: 'import_with_children.json'
        )

        post import_upload_data_exchange_index_path, params: { file: uploaded_file }
      end

      it 'processes import with only root node form params' do
        # Only submit decision for root node (index 0)
        # Child decisions should be loaded from stored matches
        expect {
          post import_execute_data_exchange_index_path, params: {
            decisions: {
              '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
            }
          }
        }.to change(MemoryEntity, :count).by(2)  # Parent + new child (existing task is merged/skipped)

        expect(response).to redirect_to(import_report_data_exchange_index_path)
      end

      it 'creates child entities from stored match decisions' do
        post import_execute_data_exchange_index_path, params: {
          decisions: {
            '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
          }
        }

        # New child should be created
        new_child = MemoryEntity.find_by(name: 'Child Task New')
        expect(new_child).to be_present
        expect(new_child.entity_type).to eq('Task')
      end

      it 'creates relations for child entities' do
        post import_execute_data_exchange_index_path, params: {
          decisions: {
            '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
          }
        }

        parent = MemoryEntity.find_by(name: 'Parent Project')
        new_child = MemoryEntity.find_by(name: 'Child Task New')

        relation = MemoryRelation.find_by(
          from_entity_id: new_child.id,
          to_entity_id: parent.id,
          relation_type: 'part_of'
        )
        expect(relation).to be_present
      end

      it 'imports observations for child entities' do
        post import_execute_data_exchange_index_path, params: {
          decisions: {
            '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
          }
        }

        new_child = MemoryEntity.find_by(name: 'Child Task New')
        expect(new_child.memory_observations.pluck(:content)).to include('Child observation')
      end
    end

    context 'with empty decisions params (uses default decisions from stored matches)' do
      before do
        # Use a truly unique name that won't match any existing entities
        valid_json = {
          version: '1.0',
          root_nodes: [
            {
              name: 'UniqueXyzProject999ForDefaultTest',
              entity_type: 'UniqueTypeXyz',
              aliases: '',
              observations: [],
              children: []
            }
          ]
        }.to_json

        uploaded_file = Rack::Test::UploadedFile.new(
          StringIO.new(valid_json),
          'application/json',
          original_filename: 'default_test.json'
        )

        post import_upload_data_exchange_index_path, params: { file: uploaded_file }
      end

      it 'uses default create action when decisions param is empty hash' do
        expect {
          post import_execute_data_exchange_index_path, params: { decisions: {} }
        }.to change(MemoryEntity, :count).by(1)

        expect(MemoryEntity.find_by(name: 'UniqueXyzProject999ForDefaultTest')).to be_present
      end
    end
  end

  describe 'GET /data_exchange/import_report' do
    context 'with no report in session' do
      it 'redirects to root with error' do
        get import_report_data_exchange_index_path

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(flash[:error]).to include('No import report found')
      end
    end

    context 'with report in session' do
      before do
        valid_json = {
          version: '1.0',
          root_nodes: [
            { name: 'Test Project', entity_type: 'Project', observations: [], children: [] }
          ]
        }.to_json

        uploaded_file = Rack::Test::UploadedFile.new(
          StringIO.new(valid_json),
          'application/json',
          original_filename: 'test.json'
        )

        post import_upload_data_exchange_index_path, params: { file: uploaded_file }

        post import_execute_data_exchange_index_path, params: {
          decisions: {
            '0' => { node_path: '0', action: 'create', target_id: '', parent_id: '' }
          }
        }
      end

      it 'renders the report page' do
        get import_report_data_exchange_index_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Import Report')
      end

      it 'displays import statistics' do
        get import_report_data_exchange_index_path

        expect(response.body).to include('Entities Created')
      end
    end
  end

  describe 'DELETE /data_exchange/import_cancel' do
    before do
      valid_json = {
        version: '1.0',
        root_nodes: [
          { name: 'Test', entity_type: 'Project', observations: [], children: [] }
        ]
      }.to_json

      uploaded_file = Rack::Test::UploadedFile.new(
        StringIO.new(valid_json),
        'application/json',
        original_filename: 'test.json'
      )

      post import_upload_data_exchange_index_path, params: { file: uploaded_file }
    end

    it 'clears session data and redirects to root' do
      delete import_cancel_data_exchange_index_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(flash[:notice]).to eq('Import cancelled')
    end

    it 'clears import review access' do
      delete import_cancel_data_exchange_index_path

      get import_review_data_exchange_index_path
      expect(response).to redirect_to(root_path)
    end
  end

  # Cleanup endpoints
  describe 'GET /data_exchange/orphan_nodes' do
    let!(:orphan_task) do
      MemoryEntity.create!(
        name: 'Orphan Task',
        entity_type: 'Task',
        aliases: ''
      )
    end

    it 'returns list of orphan nodes' do
      get orphan_nodes_data_exchange_index_path

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['orphans']).to be_an(Array)
      orphan_names = data['orphans'].map { |o| o['name'] }
      expect(orphan_names).to include('Orphan Task')
    end

    it 'excludes Projects from orphan list' do
      get orphan_nodes_data_exchange_index_path

      data = JSON.parse(response.body)
      entity_types = data['orphans'].map { |o| o['entity_type'] }
      expect(entity_types).not_to include('Project')
    end
  end

  describe 'POST /data_exchange/move_node' do
    let!(:orphan_task) do
      MemoryEntity.create!(
        name: 'Move Me Task',
        entity_type: 'Task',
        aliases: ''
      )
    end

    it 'moves node to new parent' do
      post move_node_data_exchange_index_path, params: {
        node_id: orphan_task.id,
        parent_id: project1.id
      }, as: :json

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['success']).to be true

      relation = MemoryRelation.find_by(
        from_entity_id: orphan_task.id,
        to_entity_id: project1.id
      )
      expect(relation).to be_present
    end

    it 'returns error for invalid node' do
      post move_node_data_exchange_index_path, params: {
        node_id: 99999,
        parent_id: project1.id
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'POST /data_exchange/merge_node' do
    let!(:source_task) do
      entity = MemoryEntity.create!(
        name: 'Source Task',
        entity_type: 'Task',
        aliases: ''
      )
      MemoryObservation.create!(memory_entity: entity, content: 'Source observation')
      entity
    end

    let!(:target_task) do
      MemoryEntity.create!(
        name: 'Target Task',
        entity_type: 'Task',
        aliases: ''
      )
    end

    it 'merges source into target' do
      post merge_node_data_exchange_index_path, params: {
        source_id: source_task.id,
        target_id: target_task.id
      }, as: :json

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['success']).to be true

      # Source should be deleted
      expect(MemoryEntity.find_by(id: source_task.id)).to be_nil

      # Target should have the observation
      target_task.reload
      expect(target_task.memory_observations.count).to eq(1)
    end

    it 'returns error for invalid source' do
      post merge_node_data_exchange_index_path, params: {
        source_id: 99999,
        target_id: target_task.id
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'DELETE /data_exchange/delete_node' do
    let!(:delete_me_task) do
      MemoryEntity.create!(
        name: 'Delete Me Task',
        entity_type: 'Task',
        aliases: ''
      )
    end

    it 'deletes the node' do
      delete delete_node_data_exchange_index_path, params: {
        node_id: delete_me_task.id
      }

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['success']).to be true

      expect(MemoryEntity.find_by(id: delete_me_task.id)).to be_nil
    end

    it 'returns error for invalid node' do
      delete delete_node_data_exchange_index_path, params: {
        node_id: 99999
      }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # Async export endpoints
  describe 'POST /data_exchange/export_async' do
    it 'starts async export and returns export_id' do
      expect {
        post export_async_data_exchange_index_path, params: {
          ids: [ project1.id ]
        }, as: :json
      }.to have_enqueued_job(ExportJob)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data['success']).to be true
      expect(data['export_id']).to be_present
    end

    it 'returns error without entity IDs' do
      post export_async_data_exchange_index_path, params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'GET /data_exchange/download_export' do
    it 'returns error when export file not found' do
      get download_export_data_exchange_index_path, params: {
        export_id: 'non-existent-id'
      }

      expect(response).to have_http_status(:not_found)
    end

    it 'returns error without export_id' do
      get download_export_data_exchange_index_path

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # Relation management endpoints
  describe 'GET /data_exchange/duplicate_relations' do
    context 'with no duplicates' do
      it 'returns empty duplicates list' do
        get duplicate_relations_data_exchange_index_path

        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)

        expect(data['count']).to eq(0)
        expect(data['duplicates']).to be_empty
      end
    end

    context 'with duplicate relations' do
      let!(:relation_a_to_b) do
        MemoryRelation.create!(
          from_entity: task1,
          to_entity: project1,
          relation_type: 'depends_on'
        )
      end

      let!(:relation_b_to_a) do
        MemoryRelation.create!(
          from_entity: project1,
          to_entity: task1,
          relation_type: 'depends_on'
        )
      end

      it 'returns duplicate relation pairs' do
        get duplicate_relations_data_exchange_index_path

        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)

        expect(data['count']).to eq(1)
        expect(data['duplicates'].length).to eq(1)

        dup = data['duplicates'].first
        expect(dup['relation_type']).to eq('depends_on')
        expect(dup['keep']['id']).to eq(relation_a_to_b.id)  # older one
        expect(dup['delete']['id']).to eq(relation_b_to_a.id)  # newer one
      end
    end
  end

  describe 'DELETE /data_exchange/delete_duplicate_relations' do
    let!(:relation_a_to_b) do
      MemoryRelation.create!(
        from_entity: task1,
        to_entity: project1,
        relation_type: 'depends_on'
      )
    end

    let!(:relation_b_to_a) do
      MemoryRelation.create!(
        from_entity: project1,
        to_entity: task1,
        relation_type: 'depends_on'
      )
    end

    it 'deletes duplicate relations keeping the older one' do
      expect {
        delete delete_duplicate_relations_data_exchange_index_path
      }.to change(MemoryRelation, :count).by(-1)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['success']).to be true
      expect(data['deleted_count']).to eq(1)

      # Older relation should remain
      expect(MemoryRelation.find_by(id: relation_a_to_b.id)).to be_present
      # Newer relation should be deleted
      expect(MemoryRelation.find_by(id: relation_b_to_a.id)).to be_nil
    end

    it 'returns success when no duplicates exist' do
      # Delete one to remove the duplicate
      relation_b_to_a.destroy

      delete delete_duplicate_relations_data_exchange_index_path

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['success']).to be true
      expect(data['deleted_count']).to eq(0)
    end
  end

  describe 'PATCH /data_exchange/update_relation' do
    it 'updates the relation type' do
      patch update_relation_data_exchange_index_path, params: {
        id: relation1.id,
        relation_type: 'depends_on'
      }, as: :json

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['success']).to be true
      expect(data['relation']['relation_type']).to eq('depends_on')

      relation1.reload
      expect(relation1.relation_type).to eq('depends_on')
    end

    it 'returns error for invalid relation ID' do
      patch update_relation_data_exchange_index_path, params: {
        id: 99999,
        relation_type: 'depends_on'
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'returns error when relation type is missing' do
      patch update_relation_data_exchange_index_path, params: {
        id: relation1.id
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'DELETE /data_exchange/delete_relation' do
    it 'deletes the relation' do
      expect {
        delete delete_relation_data_exchange_index_path, params: {
          id: relation1.id
        }
      }.to change(MemoryRelation, :count).by(-1)

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['success']).to be true
      expect(MemoryRelation.find_by(id: relation1.id)).to be_nil
    end

    it 'returns error for invalid relation ID' do
      delete delete_relation_data_exchange_index_path, params: {
        id: 99999
      }

      expect(response).to have_http_status(:not_found)
    end
  end
end
