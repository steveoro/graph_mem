# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'DataExchange', type: :request do
  before { sign_in_operator }

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
        expect(response.headers['Content-Disposition']).to match(/graph_mem_export_\d{8}_\d{6}\.json/)
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

    it 'leaves the membership advisory lock free after the request' do
      # Request-level regression for the query-cache leak: the executor's
      # query cache could swallow the outer RELEASE_LOCK and leave this
      # connection holding graph_mem.project_membership:* for every other
      # writer until it was recycled.
      post move_node_data_exchange_index_path, params: {
        node_id: orphan_task.id,
        parent_id: project1.id
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(membership_lock_free?).to be true
    end

    it 'returns a friendly 422 (not a 500) when the membership lock is held' do
      stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
      conn = ActiveRecord::Base.connection
      name = ProjectMembership.lock_name(conn)
      holder = stub_const("MoveNodeLockHolder",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

      post move_node_data_exchange_index_path, params: {
        node_id: orphan_task.id,
        parent_id: project1.id
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['error']).to match(/membership lock|retry shortly/i)
      expect(MemoryEntity.find(orphan_task.id).project_id).to be_nil
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
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

  describe 'POST /data_exchange/create_relation' do
    it 'creates a new relation' do
      post create_relation_data_exchange_index_path, params: {
        from_id: task1.id,
        to_id: project2.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)

      expect(data['success']).to be true
      expect(data['relation']['relation_type']).to eq('part_of')
      expect(MemoryRelation.find_by(from_entity_id: task1.id, to_entity_id: project2.id, relation_type: 'part_of')).to be_present
      expect(MemoryRelation.find_by(from_entity_id: task1.id, to_entity_id: project1.id, relation_type: 'part_of')).to be_nil
    end

    it 'returns error for invalid parameters' do
      post create_relation_data_exchange_index_path, params: {
        from_id: task1.id
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'stamps project scope through sync and leaves the lock free (fresh part_of edge)' do
      new_task = MemoryEntity.create!(name: 'Scoped UI Task', entity_type: 'Task')

      post create_relation_data_exchange_index_path, params: {
        from_id: new_task.id,
        to_id: project2.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['success']).to be true
      # Without sync! the child stays global until the next backfill (U1).
      expect(MemoryEntity.find(new_task.id).project_id).to eq(project2.id)
      # Same query-cache leak guard as move_node.
      expect(membership_lock_free?).to be true
    end

    it 'takes the membership lock BEFORE the transaction on a fresh part_of edge' do
      # Without the outer with_membership_lock the first GET_LOCK observed is
      # reassign!'s — issued INSIDE the transaction (the deadlock ordering).
      new_task = MemoryEntity.create!(name: 'Ordered UI Task', entity_type: 'Task')

      excess = open_transactions_at_get_lock do
        post create_relation_data_exchange_index_path, params: {
          from_id: new_task.id,
          to_id: project2.id,
          relation_type: 'part_of'
        }, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(excess).to eq(0)
    end

    it 'returns a friendly 422 (not a 500) when the membership lock is held' do
      new_task = MemoryEntity.create!(name: 'Blocked UI Task', entity_type: 'Task')
      stub_const("ProjectMembership::LOCK_TIMEOUT_SECONDS", 0)
      conn = ActiveRecord::Base.connection
      name = ProjectMembership.lock_name(conn)
      holder = stub_const("CreateRelLockHolder",
                          Class.new(ActiveRecord::Base) { self.abstract_class = true })
      holder.establish_connection(ActiveRecord::Base.connection_db_config)
      holder.connection.select_value("SELECT GET_LOCK(#{conn.quote(name)}, 5)")

      post create_relation_data_exchange_index_path, params: {
        from_id: new_task.id,
        to_id: project2.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['error']).to match(/retry shortly/i)
      expect(MemoryRelation.exists?(from_entity_id: new_task.id, relation_type: 'part_of')).to be false
    ensure
      holder.connection.select_value("SELECT RELEASE_LOCK(#{conn.quote(name)})") if holder&.connection
      holder.connection_pool&.disconnect! if holder
    end

    it 'returns 422 (not a 500) when the part_of edge already exists' do
      post create_relation_data_exchange_index_path, params: {
        from_id: task1.id,
        to_id: project1.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['error']).to be_present
    end

    it 'returns 422 with the validation message when the relation fails validation' do
      new_task = MemoryEntity.create!(name: 'Invalid Rel Task', entity_type: 'Task')
      invalid = MemoryRelation.new
      invalid.errors.add(:relation_type, 'is bogus')
      allow(MemoryRelation).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

      post create_relation_data_exchange_index_path, params: {
        from_id: new_task.id,
        to_id: project2.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['error']).to match(/bogus/)
    end

    it 'hints rename/re-parent (not "retry shortly") on a scope name collision' do
      MemoryEntity.create!(name: 'Dup Member', entity_type: 'Task', project_id: project2.id)
      dup = MemoryEntity.create!(name: 'Dup Member', entity_type: 'Task')

      post create_relation_data_exchange_index_path, params: {
        from_id: dup.id,
        to_id: project2.id,
        relation_type: 'part_of'
      }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      error = JSON.parse(response.body)['error']
      expect(error).to match(/rename|pick another parent/i)
      expect(error).not_to match(/retry shortly/i)
      expect(MemoryRelation.exists?(from_entity_id: dup.id, relation_type: 'part_of')).to be false
    end
  end

  describe 'ImportDecisions.project_entity_id (moved from the controller in UI-6)' do
    def scope_for(import_data, decisions)
      ImportDecisions.project_entity_id(import_data, decisions)
    end

    it 'pins the merged ROOT node, not a child merged into another project' do
      # New Project root (created fresh — no decision target) with a nested
      # Project child that merged into an existing OTHER project: the scope
      # must stay the new root, not the child's merge target.
      import_data = {
        'root_nodes' => [
          { 'name' => 'Fresh Proj', 'entity_type' => 'Project',
            'children' => [
              { 'name' => 'Project Beta', 'entity_type' => 'Project' }
            ] }
        ]
      }
      fresh = MemoryEntity.create!(name: 'Fresh Proj', entity_type: 'Project')
      decisions = [
        { node_path: '0', action: 'create' },
        { node_path: '0.children.0', action: 'merge', target_id: project2.id }
      ]

      expect(scope_for(import_data, decisions)).to eq(fresh.id)
    end

    it 'returns the merged root target when the root itself merged' do
      import_data = {
        'root_nodes' => [ { 'name' => 'Old Name', 'entity_type' => 'Project' } ]
      }
      decisions = [ { node_path: '0', action: 'merge', target_id: project2.id } ]

      expect(scope_for(import_data, decisions)).to eq(project2.id)
    end

    it 'accepts a merge target that is itself a nested (non-global) Project' do
      # The strategy's @import_project_id pins WHATEVER the root mapped to —
      # nested Projects own their own scope, so merging the payload root into
      # a nested Project scopes the import there, not to the global namespace.
      nested = MemoryEntity.create!(name: 'Nested Proj', entity_type: 'Project',
                                    project_id: project1.id)
      import_data = {
        'root_nodes' => [ { 'name' => 'Any Name', 'entity_type' => 'Project' } ]
      }
      decisions = [ { node_path: '0', action: 'merge', target_id: nested.id } ]

      expect(scope_for(import_data, decisions)).to eq(nested.id)
    end
  end
end
