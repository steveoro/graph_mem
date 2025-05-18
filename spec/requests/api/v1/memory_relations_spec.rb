require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Relations', type: :request do
  path '/api/v1/memory_relations' do
    get('list memory relations') do
      tags 'Memory Relations'
      produces 'application/json'
      parameter name: :from_entity_id, in: :query, type: :integer, required: false, description: 'Filter by source entity ID'
      parameter name: :to_entity_id, in: :query, type: :integer, required: false, description: 'Filter by target entity ID'
      parameter name: :relation_type, in: :query, type: :string, required: false, description: 'Filter by relation type'

      response(200, 'successful') do
        schema type: :array,
               'items': { '$ref' => '#/components/schemas/memory_relation' }

        let!(:entity1) { MemoryEntity.create!(name: 'Entity 1', entity_type: 'TypeA') }
        let!(:entity2) { MemoryEntity.create!(name: 'Entity 2', entity_type: 'TypeB') }
        let!(:entity3) { MemoryEntity.create!(name: 'Entity 3', entity_type: 'TypeC') }
        let!(:relation1) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity2.id, relation_type: 'connects_to') }
        let!(:relation2) { MemoryRelation.create!(from_entity_id: entity2.id, to_entity_id: entity3.id, relation_type: 'points_at') }
        let!(:relation3) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity3.id, relation_type: 'connects_to') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data.size).to eq(3)
        end

        context 'when filtering by from_entity_id' do
          let(:from_entity_id) { entity1.id }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['from_entity_id'] == entity1.id }).to be true
          end
        end

        context 'when filtering by to_entity_id' do
          let(:to_entity_id) { entity3.id }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['to_entity_id'] == entity3.id }).to be true
          end
        end

        context 'when filtering by relation_type' do
          let(:relation_type) { 'connects_to' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['relation_type'] == 'connects_to' }).to be true
          end
        end

        context 'when filtering by multiple parameters' do
          let(:from_entity_id) { entity1.id }
          let(:relation_type) { 'connects_to' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.all? { |rel| rel['from_entity_id'] == entity1.id && rel['relation_type'] == 'connects_to' }).to be true
          end
        end

        context 'when filter results in no matches' do
          let(:relation_type) { 'non_existent_type' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(0)
          end
        end
      end
    end

    post('create memory relation') do
      tags 'Memory Relations'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          from_entity_id: { type: :integer, description: 'ID of the source entity' },
          to_entity_id: { type: :integer, description: 'ID of the target entity' },
          relation_type: { type: :string, example: 'related_to' }
        },
        required: [ 'from_entity_id', 'to_entity_id', 'relation_type' ]
      }

      response(201, 'created') do
        schema '$ref' => '#/components/schemas/memory_relation'

        let(:entity_from) { MemoryEntity.create!(name: 'Create From Entity', entity_type: 'CreateFrom') }
        let(:entity_to) { MemoryEntity.create!(name: 'Create To Entity', entity_type: 'CreateTo') }
        let(:memory_relation) { { from_entity_id: entity_from.id, to_entity_id: entity_to.id, relation_type: 'points_to' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:created)
          expect(data['relation_type']).to eq('points_to')
          expect(data['from_entity_id']).to eq(entity_from.id)
          expect(data['to_entity_id']).to eq(entity_to.id)
          expect(MemoryRelation.count).to eq(1)
        end
      end

      response(422, 'unprocessable entity') do
        context 'when parent entities do not exist' do
          let(:memory_relation) { { from_entity_id: 9999, to_entity_id: 9998, relation_type: 'non_existent_link' } }

          run_test! do |response|
            data = JSON.parse(response.body)
            expect(response).to have_http_status(:unprocessable_entity)
            expect(data['from_entity']).to include('must exist')
            expect(data['to_entity']).to include('must exist')
            expect(MemoryRelation.count).to eq(0)
          end
        end

        context 'when relation_type is missing' do
          let(:entity_from) { MemoryEntity.create!(name: 'Create From Entity', entity_type: 'CreateFrom') }
          let(:entity_to) { MemoryEntity.create!(name: 'Create To Entity', entity_type: 'CreateTo') }
          let(:memory_relation) { { from_entity_id: entity_from.id, to_entity_id: entity_to.id, relation_type: nil } }

          run_test! do |response|
            data = JSON.parse(response.body)
            expect(response).to have_http_status(:unprocessable_entity)
            expect(data['relation_type']).to include("can't be blank")
            expect(MemoryRelation.count).to eq(0)
          end
        end
      end
    end
  end

  path '/api/v1/memory_relations/{id}' do
    parameter name: 'id', in: :path, type: :string, description: 'ID of the Memory Relation'

    let!(:entity1) { MemoryEntity.create!(name: 'Existing Entity 1', entity_type: 'ExistingType1') }
    let!(:entity2) { MemoryEntity.create!(name: 'Existing Entity 2', entity_type: 'ExistingType2') }
    let!(:existing_relation) { MemoryRelation.create!(from_entity_id: entity1.id, to_entity_id: entity2.id, relation_type: 'has_link') }
    let(:id) { existing_relation.id }

    get('show memory relation') do
      tags 'Memory Relations'
      produces 'application/json'

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_relation.id)
          expect(data['from_entity_id']).to eq(entity1.id)
          expect(data['to_entity_id']).to eq(entity2.id)
          expect(data['relation_type']).to eq('has_link')
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-relation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory relation') do
      tags 'Memory Relations'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          # Note: Only relation_type is updatable via controller
          relation_type: { type: :string, example: 'updated_link' }
        },
        required: [ 'relation_type' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'
        let(:memory_relation) { { relation_type: 'updated_link_patch' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['relation_type']).to eq('updated_link_patch')
          # Verify DB change and that other fields are unchanged
          reloaded_relation = existing_relation.reload
          expect(reloaded_relation.relation_type).to eq('updated_link_patch')
          expect(reloaded_relation.from_entity_id).to eq(entity1.id)
          expect(reloaded_relation.to_entity_id).to eq(entity2.id)
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_relation) { { relation_type: nil } } # Invalid update

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['relation_type']).to include("can't be blank")
          expect(existing_relation.reload.relation_type).to eq('has_link') # Verify no change
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-relation-id' }
        let(:memory_relation) { { relation_type: 'update_attempt_patch' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    put('update memory relation') do
      tags 'Memory Relations'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_relation, in: :body, schema: {
        type: :object,
        properties: {
          # Note: Only relation_type is updatable via controller
          relation_type: { type: :string, example: 'updated_link_put' }
        },
        required: [ 'relation_type' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_relation'
        let(:memory_relation) { { relation_type: 'updated_link_put' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['relation_type']).to eq('updated_link_put')
          # Verify DB change and that other fields are unchanged
          reloaded_relation = existing_relation.reload
          expect(reloaded_relation.relation_type).to eq('updated_link_put')
          expect(reloaded_relation.from_entity_id).to eq(entity1.id)
          expect(reloaded_relation.to_entity_id).to eq(entity2.id)
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_relation) { { relation_type: nil } } # Invalid update

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['relation_type']).to include("can't be blank")
          expect(existing_relation.reload.relation_type).to eq('has_link') # Verify no change
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-relation-id' }
        let(:memory_relation) { { relation_type: 'update_attempt_put' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    delete('delete memory relation') do
      tags 'Memory Relations'

      response(204, 'no content') do
        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryRelation.exists?(existing_relation.id)).to be_falsey
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-relation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
