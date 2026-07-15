# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  # Specify a root folder where Swagger JSON files are generated
  # NOTE: If you're using the rswag-api to serve API descriptions, you'll need
  # to ensure that it's configured to serve Swagger from the same folder
  config.openapi_root = Rails.root.join('swagger').to_s

  # Define one or more Swagger documents and provide global metadata for each one
  # When you run the 'rswag:specs:swaggerize' rake task, the complete Swagger will
  # be generated at the provided relative path under openapi_root
  # By default, the operations defined in spec files are added to the first
  # document below. You can override this behavior by adding a openapi_spec tag to the
  # the root example_group in your specs, e.g. describe '...', openapi_spec: 'v2/swagger.json'
  config.openapi_specs = {
    'v1/swagger.yaml' => {
      openapi: '3.0.1',
      info: {
        title: 'API V1',
        version: 'v1'
      },
      paths: {},
      servers: [
        {
          url: 'http://localhost:3000',
          description: 'Local development server'
        }
      ],
      components: {
        schemas: {
          error_response: {
            type: :object,
            properties: {
              error: { type: :string },
              details: {}
            },
            required: [ 'error' ]
          },
          MemoryEntitySearchResult: {
            type: :object,
            properties: {
              entity_id: { type: :integer },
              name: { type: :string },
              entity_type: { type: :string },
              aliases: { type: [ :string, :null ] },
              memory_observations_count: { type: :integer },
              created_at: { type: :string, format: 'date-time' },
              updated_at: { type: :string, format: 'date-time' },
              relevance_score: { type: :number, format: 'float' },
              matched_fields: { type: :array, items: { type: :string } }
            },
            required: [ 'entity_id', 'name', 'entity_type', 'memory_observations_count', 'created_at', 'updated_at', 'relevance_score', 'matched_fields' ]
          },
          memory_entity: {
            type: :object,
            properties: {
              id: { type: :integer, readOnly: true },
              name: { type: :string },
              entity_type: { type: :string },
              aliases: { type: [ :string, :null ], nullable: true },
              description: { type: [ :string, :null ], nullable: true },
              memory_observations_count: { type: :integer, readOnly: true },
              created_at: { type: :string, format: 'date-time', readOnly: true },
              updated_at: { type: :string, format: 'date-time', readOnly: true }
            },
            required: [ 'id', 'name', 'entity_type', 'memory_observations_count', 'created_at', 'updated_at' ]
          },
          memory_observation: {
            type: :object,
            properties: {
              id: { type: :integer, readOnly: true },
              content: { type: :string },
              memory_entity_id: { type: :integer, readOnly: true },
              confidence: { type: [ :number, :null ], format: :float, nullable: true, minimum: 0, maximum: 1 },
              source: { type: [ :string, :null ], nullable: true },
              valid_from: { type: [ :string, :null ], format: 'date-time', nullable: true },
              valid_until: { type: [ :string, :null ], format: 'date-time', nullable: true },
              tags: { type: :array, items: { type: :string } },
              created_at: { type: :string, format: 'date-time', readOnly: true },
              updated_at: { type: :string, format: 'date-time', readOnly: true }
            },
            required: [ 'id', 'content', 'memory_entity_id', 'created_at', 'updated_at' ]
          },
          memory_relation: {
            type: :object,
            properties: {
              id: { type: :integer, readOnly: true },
              from_entity_id: { type: :integer },
              to_entity_id: { type: :integer },
              relation_type: { type: :string },
              weight: { type: [ :number, :null ], format: :float, nullable: true, minimum: 0 },
              confidence: { type: [ :number, :null ], format: :float, nullable: true, minimum: 0, maximum: 1 },
              properties: { type: :object, additionalProperties: true },
              created_at: { type: :string, format: 'date-time', readOnly: true },
              updated_at: { type: :string, format: 'date-time', readOnly: true }
            },
            required: [ 'id', 'from_entity_id', 'to_entity_id', 'relation_type', 'created_at', 'updated_at' ]
          },
          traversal_entity: {
            type: :object,
            properties: {
              entity_id: { type: :integer },
              name: { type: :string },
              entity_type: { type: :string },
              aliases: { type: [ :string, :null ], nullable: true },
              observations: {
                type: :array,
                items: {
                  type: :object,
                  properties: {
                    observation_id: { type: :integer },
                    content: { type: :string },
                    confidence: { type: [ :number, :null ], format: :float, nullable: true },
                    source: { type: [ :string, :null ], nullable: true },
                    valid_from: { type: [ :string, :null ], format: 'date-time', nullable: true },
                    valid_until: { type: [ :string, :null ], format: 'date-time', nullable: true },
                    tags: { type: :array, items: { type: :string } },
                    created_at: { type: :string, format: 'date-time' },
                    updated_at: { type: :string, format: 'date-time' }
                  },
                  required: [ 'observation_id', 'content', 'created_at', 'updated_at' ]
                }
              },
              created_at: { type: :string, format: 'date-time' },
              updated_at: { type: :string, format: 'date-time' }
            },
            required: [ 'entity_id', 'name', 'entity_type', 'observations', 'created_at', 'updated_at' ]
          },
          traversal_relation: {
            type: :object,
            properties: {
              relation_id: { type: :integer },
              from_entity_id: { type: :integer },
              to_entity_id: { type: :integer },
              relation_type: { type: :string },
              weight: { type: [ :number, :null ], format: :float, nullable: true },
              confidence: { type: [ :number, :null ], format: :float, nullable: true },
              properties: { type: :object, additionalProperties: true },
              created_at: { type: :string, format: 'date-time' },
              updated_at: { type: :string, format: 'date-time' }
            },
            required: [ 'relation_id', 'from_entity_id', 'to_entity_id', 'relation_type', 'created_at', 'updated_at' ]
          },
          graph_traversal: {
            type: :object,
            properties: {
              start_entity_id: { type: :integer },
              max_depth: { type: :integer },
              direction: { type: :string, enum: %w[both outgoing incoming] },
              visited_depth: { type: :integer },
              truncated: { type: :boolean }
            },
            required: [ 'start_entity_id', 'max_depth', 'direction', 'visited_depth', 'truncated' ]
          }
        }
      }
    }
  }

  # Specify the format of the output Swagger file when running 'rswag:specs:swaggerize'.
  # The openapi_specs configuration option has the filename including format in
  # the key, this may want to be changed to avoid putting yaml in json files.
  # Defaults to json. Accepts ':json' and ':yaml'.
  config.openapi_format = :yaml
end
