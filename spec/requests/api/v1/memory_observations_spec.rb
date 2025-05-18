require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Observations', type: :request do
  # Shared setup for memory_entity_id parameter
  let(:memory_entity) { MemoryEntity.create!(name: 'Parent Entity', entity_type: 'ParentType') }
  let(:memory_entity_id) { memory_entity.id }

  path '/api/v1/memory_entities/{memory_entity_id}/memory_observations' do
    parameter name: 'memory_entity_id', in: :path, type: :string, description: 'ID of the parent Memory Entity'

    get('list memory observations for an entity') do
      tags 'Memory Observations'
      produces 'application/json'

      response(200, 'successful') do
        schema type: :array,
               'items': { '$ref' => '#/components/schemas/memory_observation' }

        # RSpec Example Tests
        let!(:observation1) { memory_entity.memory_observations.create!(content: 'Observation 1') }
        let!(:observation2) { memory_entity.memory_observations.create!(content: 'Observation 2') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data.size).to eq(2)
          expect(data.first['content']).to eq(observation1.content)
        end
      end

      response(404, 'parent entity not found') do
        let(:memory_entity_id) { 'invalid-id' }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    post('create memory observation for an entity') do
      tags 'Memory Observations'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'This is an observation.' }
        },
        required: [ 'content' ]
      }

      response(201, 'created') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) { { content: 'Test Observation Content' } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:created)
          expect(data['content']).to eq('Test Observation Content')
          expect(data['memory_entity_id']).to eq(memory_entity.id)
          expect(memory_entity.reload.memory_observations.count).to eq(1) # Assuming clean before
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_observation) { { content: nil } } # Invalid example

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['content']).to include("can't be blank")
          expect(memory_entity.reload.memory_observations.count).to eq(0)
        end
      end

      response(404, 'parent entity not found') do
        let(:memory_entity_id) { 'invalid-id' }
        let(:memory_observation) { { content: 'Test Observation Content' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  path '/api/v1/memory_entities/{memory_entity_id}/memory_observations/{id}' do
    parameter name: 'memory_entity_id', in: :path, type: :string, description: 'ID of the parent Memory Entity'
    parameter name: 'id', in: :path, type: :string, description: 'ID of the Memory Observation'

    # Shared setup for existing observation
    let(:existing_observation) { memory_entity.memory_observations.create!(content: 'Existing Observation') }
    let(:id) { existing_observation.id }

    get('show memory observation') do
      tags 'Memory Observations'
      produces 'application/json'

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_observation.id)
          expect(data['content']).to eq(existing_observation.content)
          expect(data['memory_entity_id']).to eq(memory_entity.id)
        end
      end

      response(404, 'observation not found') do
        let(:id) { 'invalid-observation-id' }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        let(:memory_entity_id) { 'invalid-entity-id' }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory observation') do
      tags 'Memory Observations'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'Updated Observation Content' }
        },
        required: [ 'content' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) { { content: 'Updated Content' } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['content']).to eq('Updated Content')
          expect(existing_observation.reload.content).to eq('Updated Content')
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_observation) { { content: nil } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['content']).to include("can't be blank")
          expect(existing_observation.reload.content).to eq('Existing Observation') # Check it didn't change
        end
      end

      response(404, 'observation not found') do
        let(:id) { 'invalid-observation-id' }
        let(:memory_observation) { { content: 'Update Attempt' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        let(:memory_entity_id) { 'invalid-entity-id' }
        let(:memory_observation) { { content: 'Update Attempt' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    put('update memory observation') do
      tags 'Memory Observations'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'Updated Observation Content via PUT' }
        },
        required: [ 'content' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) { { content: 'Updated Content via PUT' } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['content']).to eq('Updated Content via PUT')
          expect(existing_observation.reload.content).to eq('Updated Content via PUT')
        end
      end

      response(422, 'unprocessable entity') do
        let(:memory_observation) { { content: nil } }

        # RSpec Example Tests
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(data['content']).to include("can't be blank")
          expect(existing_observation.reload.content).to eq('Existing Observation') # Check it didn't change
        end
      end

      response(404, 'observation not found') do
        let(:id) { 'invalid-observation-id' }
        let(:memory_observation) { { content: 'Update Attempt via PUT' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        let(:memory_entity_id) { 'invalid-entity-id' }
        let(:memory_observation) { { content: 'Update Attempt via PUT' } }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    delete('delete memory observation') do
      tags 'Memory Observations'

      response(204, 'no content') do
        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryObservation.exists?(existing_observation.id)).to be_falsey
          expect(memory_entity.reload.memory_observations.count).to eq(0)
        end
      end

      response(404, 'not found') do
        let(:id) { 'invalid-observation-id' }

        # RSpec Example Tests
        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
