require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Entities', type: :request do
  path '/api/v1/memory_entities' do
    get('list memory entities') do
      tags 'Memory Entities'
      produces 'application/json'

      response(200, 'successful') do
        schema type: :array,
               'items': {
                 '$ref' => '#/components/schemas/memory_entity'
               }

        # RSpec Example Tests
        let!(:entity1) { MemoryEntity.create!(name: 'Entity One', entity_type: 'TypeA') }
        let!(:entity2) { MemoryEntity.create!(name: 'Entity Two', entity_type: 'TypeB') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data.size).to eq(2)
          expect(data.first['name']).to eq(entity1.name)
          expect(data.last['name']).to eq(entity2.name)
        end
      end
    end

    post('create memory entity') do
      tags 'Memory Entities'
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

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data['name']).to eq('Test Entity')
          expect(data['entity_type']).to eq('TestType')
          expect(MemoryEntity.count).to eq(1) # Assuming clean DB before test
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_entity) { { name: nil, entity_type: 'Invalid Type' } } # Invalid example

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['name']).to include("can't be blank") # Check specific error message
          expect(MemoryEntity.count).to eq(0)
        end
      end
    end
  end

  path '/api/v1/memory_entities/{id}' do
    # Define the existing entity needed for show/update/delete tests within this scope
    let!(:existing_entity) { MemoryEntity.create!(name: 'Existing Entity', entity_type: 'ExistingType') }

    parameter name: 'id', in: :path, type: :string, description: 'id'

    get('show memory entity') do
      tags 'Memory Entities'
      produces 'application/json'

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_entity'
        let(:id) { existing_entity.id } # Define ID for successful case

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_entity.id)
          expect(data['name']).to eq(existing_entity.name)
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-or-nonexistent-id' } # Use a more descriptive invalid ID

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory entity') do
      tags 'Memory Entities'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_entity, in: :body, schema: {
        type: :object,
        properties: {
          name: { type: :string, example: 'Updated Name' },
          entity_type: { type: :string, example: 'Updated Type' }
        }
        # Not strictly required for PATCH, but good practice
        # required: [ 'name', 'entity_type' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_entity'
        let(:id) { existing_entity.id } # Define ID for successful case
        let(:memory_entity) { { name: 'Updated Name Patch' } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['name']).to eq('Updated Name Patch')
          expect(existing_entity.reload.name).to eq('Updated Name Patch') # Verify DB change
          expect(existing_entity.reload.entity_type).to eq('ExistingType') # Verify other fields unchanged
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-id' }
        let(:memory_entity) { { name: 'Updated Name Patch' } }

        # RSpec Example Tests
        run_test! do |response|
           expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'unprocessable entity') do
        let(:id) { existing_entity.id } # Define ID for successful case
        let(:memory_entity) { { name: nil } } # Invalid example

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['name']).to include("can't be blank")
          expect(existing_entity.reload.name).to eq('Existing Entity') # Verify DB unchanged
        end
      end
    end

    put('update memory entity') do
      tags 'Memory Entities'
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
        let(:id) { existing_entity.id } # Define ID for successful case
        let(:memory_entity) { { name: 'Updated Name Put', entity_type: 'Updated Type Put' } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['name']).to eq('Updated Name Put')
          expect(data['entity_type']).to eq('Updated Type Put')
          expect(existing_entity.reload.name).to eq('Updated Name Put') # Verify DB change
          expect(existing_entity.reload.entity_type).to eq('Updated Type Put') # Verify DB change
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-id' }
        let(:memory_entity) { { name: 'Updated Name Put', entity_type: 'Updated Type Put' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'unprocessable entity') do
        let(:id) { existing_entity.id } # Define ID for successful case
        let(:memory_entity) { { name: nil, entity_type: 'Updated Type Put' } } # Invalid example

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['name']).to include("can't be blank")
          expect(existing_entity.reload.name).to eq('Existing Entity') # Verify DB unchanged
          expect(existing_entity.reload.entity_type).to eq('ExistingType') # Verify DB unchanged
        end
      end
    end

    delete('delete memory entity') do
      tags 'Memory Entities'

      response(204, 'no content') do
        let(:id) { existing_entity.id } # Define ID for successful case
        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryEntity.exists?(existing_entity.id)).to be_falsey
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-id' }

        # RSpec Example Tests
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
      produces 'application/json'
      parameter name: :q, in: :query, type: :string, required: true, description: 'Search query for entity name (case-insensitive)'

      response(200, 'successful') do
        schema type: :array, items: { '$ref' => '#/components/schemas/MemoryEntitySearchResult' }

        # Create entities for searching
        let!(:entity_apple) { MemoryEntity.create!(name: 'Apple Pie', entity_type: 'Dessert') }
        let!(:entity_banana) { MemoryEntity.create!(name: 'Banana Bread', entity_type: 'Dessert') }
        let!(:entity_carrot) { MemoryEntity.create!(name: 'Carrot Cake', entity_type: 'Dessert') }
        let!(:entity_apple_juice) { MemoryEntity.create!(name: 'apple juice', entity_type: 'Drink') }

        context 'when searching for exact name (case-insensitive)' do
          let(:q) { 'apple pie' }
          run_test! do |response|
            data = JSON.parse(response.body)
            expect(data.size).to eq(2) # "apple pie" and "apple juice", the second with less relevance
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
            # Controller returns empty array for empty query
            data = JSON.parse(response.body)
            expect(data.size).to eq(0)
          end
        end
      end

      response(400, 'bad request - missing query parameter') do
        # Rswag doesn't automatically test for missing required parameters easily
        # We'll rely on the controller logic returning empty for now.
        # To test this properly, one might need a separate non-Rswag test
        # or adjust controller to raise error for missing 'q'.
        # For now, this response definition is for documentation.
      end
    end
  end
end
