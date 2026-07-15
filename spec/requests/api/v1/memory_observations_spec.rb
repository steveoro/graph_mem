require 'rails_helper'
require 'swagger_helper'

RSpec.describe 'API V1 Memory Observations', type: :request do
  let(:memory_entity) { MemoryEntity.create!(name: 'Parent Entity', entity_type: 'ParentType') }
  let(:memory_entity_id) { memory_entity.id }

  path '/api/v1/memory_entities/{memory_entity_id}/memory_observations' do
    parameter name: 'memory_entity_id', in: :path, type: :string, description: 'ID of the parent Memory Entity'

    get('list memory observations for an entity') do
      tags 'Memory Observations'
      operationId 'listMemoryObservations'
      produces 'application/json'
      parameter name: :include_obsolete, in: :query, type: :boolean, required: false,
                description: 'Include obsolete and superseded observation history'

      response(200, 'successful') do
        schema type: :array,
               'items': { '$ref' => '#/components/schemas/memory_observation' }

        let!(:observation1) { memory_entity.memory_observations.create!(content: 'Observation 1') }
        let!(:observation2) { memory_entity.memory_observations.create!(content: 'Observation 2') }
        let!(:obsolete_observation) do
          memory_entity.memory_observations.create!(content: 'Obsolete').tap(&:mark_obsolete!)
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data.size).to eq(2)
          expect(data.first['content']).to eq(observation1.content)
          expect(data.pluck('status')).to all(eq(MemoryObservation::ACTIVE_STATUS))
          expect(data.pluck('id')).not_to include(obsolete_observation.id)
        end
      end

      response(200, 'historical observations included') do
        schema type: :array,
               'items': { '$ref' => '#/components/schemas/memory_observation' }
        let(:include_obsolete) { true }
        let!(:active_observation) { memory_entity.memory_observations.create!(content: 'Current observation') }
        let!(:obsolete_observation) do
          memory_entity.memory_observations.create!(content: 'Historical observation').tap do |observation|
            observation.mark_obsolete!(reason: 'Outdated')
          end
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data.pluck('id')).to contain_exactly(active_observation.id, obsolete_observation.id)
          expect(data.find { |item| item['id'] == obsolete_observation.id }).to include(
            'status' => MemoryObservation::OBSOLETE_STATUS,
            'obsolescence_reason' => 'Outdated'
          )
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    post('create memory observation for an entity') do
      tags 'Memory Observations'
      operationId 'createMemoryObservation'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'This is an observation.' },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          source: { type: :string, nullable: true },
          valid_from: { type: :string, format: 'date-time', nullable: true },
          valid_until: { type: :string, format: 'date-time', nullable: true },
          tags: { type: :array, items: { type: :string } }
        },
        required: [ 'content' ]
      }

      response(201, 'created') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) do
          {
            content: 'Test Observation Content',
            confidence: 0.9,
            source: 'integration-test',
            valid_from: '2026-07-01T00:00:00Z',
            valid_until: '2026-08-01T00:00:00Z',
            tags: %w[test api]
          }
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:created)
          expect(data['content']).to eq('Test Observation Content')
          expect(data['memory_entity_id']).to eq(memory_entity.id)
          expect(data['confidence']).to eq(0.9)
          expect(data['source']).to eq('integration-test')
          expect(data['tags']).to eq(%w[test api])
          expect(memory_entity.reload.memory_observations.count).to eq(1)
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_observation) { { content: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['content']).to include("can't be blank")
          expect(memory_entity.reload.memory_observations.count).to eq(0)
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-id' }
        let(:memory_observation) { { content: 'Test Observation Content' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  path '/api/v1/memory_entities/{memory_entity_id}/memory_observations/{id}' do
    parameter name: 'memory_entity_id', in: :path, type: :string, description: 'ID of the parent Memory Entity'
    parameter name: 'id', in: :path, type: :string, description: 'ID of the Memory Observation'

    let(:existing_observation) { memory_entity.memory_observations.create!(content: 'Existing Observation') }
    let(:id) { existing_observation.id }

    get('show memory observation') do
      tags 'Memory Observations'
      operationId 'showMemoryObservation'
      produces 'application/json'

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['id']).to eq(existing_observation.id)
          expect(data['content']).to eq(existing_observation.content)
          expect(data['memory_entity_id']).to eq(memory_entity.id)
          expect(data['status']).to eq(MemoryObservation::ACTIVE_STATUS)
          expect(data).to include(
            'obsoleted_at' => nil,
            'obsolescence_reason' => nil,
            'superseded_by_id' => nil
          )
        end
      end

      response(404, 'observation not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-observation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-entity-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch('update memory observation') do
      tags 'Memory Observations'
      operationId 'patchMemoryObservation'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'Updated Observation Content' },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          source: { type: :string, nullable: true },
          valid_from: { type: :string, format: 'date-time', nullable: true },
          valid_until: { type: :string, format: 'date-time', nullable: true },
          tags: { type: :array, items: { type: :string } },
          supersede: { type: :boolean, default: false },
          reason: { type: :string, nullable: true }
        },
        required: []
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) { { content: 'Updated Content', confidence: 0.75, tags: [ 'updated' ] } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['content']).to eq('Updated Content')
          expect(data['confidence']).to eq(0.75)
          expect(data['tags']).to eq([ 'updated' ])
          expect(data['status']).to eq(MemoryObservation::ACTIVE_STATUS)
          expect(existing_observation.reload.content).to eq('Updated Content')
        end
      end

      response(200, 'superseded') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) do
          { content: 'Replacement Content', supersede: true, reason: 'Corrected' }
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          replacement = MemoryObservation.find(data['id'])
          expect(replacement).to be_active
          expect(replacement.content).to eq('Replacement Content')
          expect(existing_observation.reload).to be_superseded
          expect(existing_observation.superseded_by_id).to eq(replacement.id)
          expect(existing_observation.obsolescence_reason).to eq('Corrected')
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_observation) { { content: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['content']).to include("can't be blank")
          expect(existing_observation.reload.content).to eq('Existing Observation')
        end
      end

      response(404, 'observation not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-observation-id' }
        let(:memory_observation) { { content: 'Update Attempt' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-entity-id' }
        let(:memory_observation) { { content: 'Update Attempt' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    put('update memory observation') do
      tags 'Memory Observations'
      operationId 'putMemoryObservation'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :memory_observation, in: :body, schema: {
        type: :object,
        properties: {
          content: { type: :string, example: 'Updated Observation Content via PUT' },
          confidence: { type: :number, format: :float, minimum: 0, maximum: 1, nullable: true },
          source: { type: :string, nullable: true },
          valid_from: { type: :string, format: 'date-time', nullable: true },
          valid_until: { type: :string, format: 'date-time', nullable: true },
          tags: { type: :array, items: { type: :string } },
          supersede: { type: :boolean, default: false },
          reason: { type: :string, nullable: true }
        },
        required: [ 'content' ]
      }

      response(200, 'successful') do
        schema '$ref' => '#/components/schemas/memory_observation'
        let(:memory_observation) { { content: 'Updated Content via PUT' } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['content']).to eq('Updated Content via PUT')
          expect(existing_observation.reload.content).to eq('Updated Content via PUT')
        end
      end

      response(422, 'unprocessable entity') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_observation) { { content: nil } }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:unprocessable_content)
          expect(data['error']).to eq('Validation failed')
          expect(data['details']['content']).to include("can't be blank")
          expect(existing_observation.reload.content).to eq('Existing Observation')
        end
      end

      response(404, 'observation not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-observation-id' }
        let(:memory_observation) { { content: 'Update Attempt via PUT' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-entity-id' }
        let(:memory_observation) { { content: 'Update Attempt via PUT' } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    delete('mark memory observation obsolete') do
      tags 'Memory Observations'
      operationId 'deleteMemoryObservation'
      parameter name: :reason, in: :query, type: :string, required: false,
                description: 'Reason for marking the observation obsolete'

      response(204, 'no content') do
        let(:reason) { 'Outdated' }

        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(MemoryObservation.exists?(existing_observation.id)).to be(true)
          expect(existing_observation.reload).to be_obsolete
          expect(existing_observation.obsoleted_at).to be_present
          expect(existing_observation.obsolescence_reason).to eq('Outdated')
          expect(memory_entity.reload.memory_observations.count).to eq(1)
        end
      end

      response(404, 'not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:id) { 'invalid-observation-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  path '/api/v1/memory_entities/{memory_entity_id}/memory_observations/delete_duplicates' do
    parameter name: 'memory_entity_id', in: :path, type: :string, description: 'ID of the parent Memory Entity'

    delete('delete duplicate observations') do
      tags 'Memory Observations'
      operationId 'deleteDuplicateObservations'
      produces 'application/json'

      response(200, 'successful deletion') do
        schema type: :object,
               properties: {
                 message: { type: :string, example: 'Successfully deleted 2 duplicate observations' },
                 deleted_count: { type: :integer, example: 2 }
               },
               required: [ 'message', 'deleted_count' ]

        let!(:obs1) { memory_entity.memory_observations.create!(content: 'Duplicate content') }
        let!(:obs2) { memory_entity.memory_observations.create!(content: 'Unique content') }
        let!(:obs3) { memory_entity.memory_observations.create!(content: 'Duplicate content') }
        let!(:obs4) { memory_entity.memory_observations.create!(content: 'Another duplicate') }
        let!(:obs5) { memory_entity.memory_observations.create!(content: 'Another duplicate') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['deleted_count']).to eq(2)
          expect(data['message']).to include('Successfully deleted 2 duplicate observations')

          remaining_observations = memory_entity.reload.memory_observations.order(:created_at)
          expect(remaining_observations.count).to eq(3)
          expect(remaining_observations.pluck(:content)).to contain_exactly(
            'Duplicate content', 'Unique content', 'Another duplicate'
          )

          expect(remaining_observations.find_by(content: 'Duplicate content').id).to eq(obs1.id)
          expect(remaining_observations.find_by(content: 'Another duplicate').id).to eq(obs4.id)
        end
      end

      response(200, 'no duplicates found') do
        schema type: :object,
               properties: {
                 message: { type: :string, example: 'Successfully deleted 0 duplicate observations' },
                 deleted_count: { type: :integer, example: 0 }
               },
               required: [ 'message', 'deleted_count' ]

        let!(:obs1) { memory_entity.memory_observations.create!(content: 'Unique content 1') }
        let!(:obs2) { memory_entity.memory_observations.create!(content: 'Unique content 2') }
        let!(:obs3) { memory_entity.memory_observations.create!(content: 'Unique content 3') }

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['deleted_count']).to eq(0)
          expect(data['message']).to include('Successfully deleted 0 duplicate observations')

          expect(memory_entity.reload.memory_observations.count).to eq(3)
        end
      end

      response(404, 'parent entity not found') do
        schema '$ref' => '#/components/schemas/error_response'
        let(:memory_entity_id) { 'invalid-id' }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response(422, 'operation failed') do
        schema '$ref' => '#/components/schemas/error_response'
      end
    end
  end
end
