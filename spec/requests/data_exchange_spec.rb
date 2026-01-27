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
        get export_data_exchange_index_path, params: { ids: [project1.id] }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include('application/json')
        expect(response.headers['Content-Disposition']).to include('attachment')
      end

      it 'exports selected entities with children' do
        get export_data_exchange_index_path, params: { ids: [project1.id] }

        data = JSON.parse(response.body)

        expect(data['version']).to eq('1.0')
        expect(data['root_nodes']).to be_an(Array)
        expect(data['root_nodes'].length).to eq(1)

        root_node = data['root_nodes'].first
        expect(root_node['name']).to eq('Project Alpha')
        expect(root_node['observations'].length).to eq(1)
      end

      it 'includes child entities' do
        get export_data_exchange_index_path, params: { ids: [project1.id] }

        data = JSON.parse(response.body)
        root_node = data['root_nodes'].first

        child_names = root_node['children'].map { |c| c['name'] }
        expect(child_names).to include('Task One')
      end
    end

    context 'with no entity IDs' do
      it 'returns error' do
        get export_data_exchange_index_path

        expect(response).to have_http_status(:unprocessable_entity)
        data = JSON.parse(response.body)
        expect(data['error']).to eq('No entity IDs provided')
      end
    end

    context 'with multiple entity IDs' do
      it 'exports multiple root nodes' do
        get export_data_exchange_index_path, params: { ids: [project1.id, project2.id] }

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
              observations: [{ content: 'Imported observation' }],
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
end
