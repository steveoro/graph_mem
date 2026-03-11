require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Entities', type: :request do
  path '/api/v1/memory_entities' do
    get('list memory entities') do
      tags 'Memory Entities'
      operationId 'listMemoryEntities'
      produces 'application/json'

      response(200, 'successful') do
        schema type: :object,
               properties: {
                 entities: { type: :array, items: { '$ref' => '#/components/schemas/memory_entity' } },
                 pagination: {
                   type: :object,
                   properties: {
                     total_entities: { type: :integer },
                     per_page: { type: :integer },
                     current_page: { type: :integer },
                     total_pages: { type: :integer }
                   }
                 }
               },
               required: %w[entities pagination]

        let!(:entity1) { MemoryEntity.create!(name: 'Entity One', entity_type: 'TypeA') }
        let!(:entity2) { MemoryEntity.create!(name: 'Entity Two', entity_type: 'TypeB') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data['entities'].size).to be >= 2
          expect(data['pagination']['total_entities']).to be >= 2
          expect(data).to have_key('pagination')
        end
      end
    end

    post('create memory entity') do
      tags 'Memory Entities'
      operationId 'createMemoryEntity'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :memory_entity, in: :body, schema: {
        type: :object,
        properties: {
          name: { type: :string, example: 'New Project' },
          entity_type: { type: :string, example: 'Project' }
        },
        required: [ 'name', 'entity_type' ]
      }

      response(201, 'created') do
        schema '$ref' => '#/components/schemas/memory_entity'
        let(:memory_entity) { { name: 'Test Entity', entity_type: 'TestType' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data['name']).to eq('Test Entity')
          expect(data['entity_type']).to eq('TestType')
          expect(data['id']).to be_present
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity) { { name: nil, entity_type: 'Invalid Type' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['name']).to include("can't be blank")
        end
      end
    end
  end

  path '/api/v1/memory_entities/{id}' do
    let!(:existing_entity) { MemoryEntity.create!(name: 'Existing Entity', entity_type: 'ExistingType') }

    parameter name: 'id', in: :path, type: :string, description: 'id'

    get('show memory entity') do
      tags 'Memory Entities'
      operationId 'showMemoryEntity'
      produces 'application/json'

      response(200, 'successful') do
        schema type: :object,
               properties: {
                 id: { type: :integer },
                 name: { type: :string },
                 entity_type: { type: :string },
                 aliases: { type: [ :string, :null ] },
                 description: { type: [ :string, :null ] },
                 memory_observations_count: { type: :integer },
                 created_at: { type: :string },
                 updated_at: { type: :string },
                 observations: { type: :array },
                 relations_from: { type: :array },
                 relations_to: { type: :array }
               },
               required: %w[id name entity_type]
        let(:id) { existing_entity.id }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_entity.id)
          expect(data['name']).to eq(existing_entity.name)
          expect(data).to have_key('observations')
          expect(data).to have_key('relations_from')
          expect(data).to have_key('relations_to')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-or-nonexistent-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory entity') do
      tags 'Memory Entities'
      operationId 'patchMemoryEntity'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_entity, in: :body, schema: {
        type: :object,
        properties: {
          name: { type: :string, example: 'Updated Name' },
          entity_type: { type: :string, example: 'Updated Type' }
        }
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_entity'
        let(:id) { existing_entity.id }
        let(:memory_entity) { { name: 'Updated Name Patch' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['name']).to eq('Updated Name Patch')
          expect(existing_entity.reload.name).to eq('Updated Name Patch')
          expect(existing_entity.reload.entity_type).to eq('ExistingType')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-id' }
        let(:memory_entity) { { name: 'Updated Name Patch' } }

        run_test! do |response|
           expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { existing_entity.id }
        let(:memory_entity) { { name: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['name']).to include("can't be blank")
          expect(existing_entity.reload.name).to eq('Existing Entity')
        end
      end
    end

    put('update memory entity') do
      tags 'Memory Entities'
      operationId 'putMemoryEntity'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_entity, in: :body, schema: {
        type: :object,
        properties: {
          name: { type: :string, example: 'Updated Name' },
          entity_type: { type: :string, example: 'Updated Type' }
        },
        required: [ 'name', 'entity_type' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_entity'
        let(:id) { existing_entity.id }
        let(:memory_entity) { { name: 'Updated Name Put', entity_type: 'Updated Type Put' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['name']).to eq('Updated Name Put')
          expect(data['entity_type']).to eq('Updated Type Put')
          expect(existing_entity.reload.name).to eq('Updated Name Put')
          expect(existing_entity.reload.entity_type).to eq('Updated Type Put')
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-id' }
        let(:memory_entity) { { name: 'Updated Name Put', entity_type: 'Updated Type Put' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'unprocessable entity - missing required fields') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { existing_entity.id }
        let(:memory_entity) { { name: 'Only Name' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to include('PUT requires')
          expect(existing_entity.reload.name).to eq('Existing Entity')
        end
      end

      response(422, 'unprocessable entity - validation error') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { existing_entity.id }
        let(:memory_entity) { { name: nil, entity_type: 'Updated Type Put' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(existing_entity.reload.name).to eq('Existing Entity')
          expect(existing_entity.reload.entity_type).to eq('ExistingType')
        end
      end
    end

    delete('delete memory entity') do
      tags 'Memory Entities'
      operationId 'deleteMemoryEntity'

      response(204, 'no content') do
        let(:id) { existing_entity.id }
        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryEntity.exists?(existing_entity.id)).to be_falsey
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  # --- Search Endpoint --- #
  path '/api/v1/memory_entities/search' do
    get('search memory entities') do
      tags 'Memory Entities'
      operationId 'searchMemoryEntities'
      produces 'application/json'
      parameter name: :q, in: :query, type: :string, required: true, description: 'Search query for entity name (case-insensitive)'

      response(200, 'successful') do
        schema type: :array, items: { '$ref' => '#/components/schemas/MemoryEntitySearchResult' }

        let!(:entity_apple) { MemoryEntity.create!(name: 'Apple Pie', entity_type: 'Dessert') }
        let!(:entity_banana) { MemoryEntity.create!(name: 'Banana Bread', entity_type: 'Dessert') }
        let!(:entity_carrot) { MemoryEntity.create!(name: 'Carrot Cake', entity_type: 'Dessert') }
        let!(:entity_apple_juice) { MemoryEntity.create!(name: 'apple juice', entity_type: 'Drink') }

        context 'when searching for exact name (case-insensitive)' do
          let(:q) { 'apple pie' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.first['entity_id']).to eq(entity_apple.id)
            expect(data.last['entity_id']).to eq(entity_apple_juice.id)
            expect(data.first['relevance_score']).to be > data.last['relevance_score']
          end
        end

        context 'when searching for partial name (case-insensitive)' do
          let(:q) { 'apple' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2)
            expect(data.map { |e| e['entity_id'] }).to contain_exactly(entity_apple.id, entity_apple_juice.id)
            expect(data.first['relevance_score']).to be >= data.last['relevance_score']
          end
        end

        context 'when search term matches nothing' do
          let(:q) { 'pineapple' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(0)
          end
        end

        context 'when search term is empty' do
          let(:q) { '' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(0)
          end
        end
      end

      response(400, 'bad request - missing query parameter') do
      end
    end
  end
end
