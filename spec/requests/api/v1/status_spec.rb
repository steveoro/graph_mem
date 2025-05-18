# frozen_string_literal: true

require 'rails_helper'
require 'swagger_helper' # Include swagger helper if documenting

RSpec.describe 'API V1 Status', type: :request do
  path '/api/v1/status' do
    get('show status') do
      tags 'Status'
      produces 'application/json'

      response(200, 'successful') do
        schema type: :object,
               properties: {
                 status: { type: :string, example: 'ok' },
                 version: { type: :string, example: '0.1.0' }
               },
               required: [ 'status', 'version' ]

        # RSpec Example Test
        run_test! do |response|
          data = JSON.parse(response.body)
          expect(response).to have_http_status(:ok)
          expect(data['status']).to eq('ok')
          expect(data['version']).to eq(GraphMemoryBackend::VERSION)
        end
      end
    end
  end
end
