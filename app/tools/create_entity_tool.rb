# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  description "Create a new entity in the graph memory database."

  arguments do
    required(:name).filled(:string).description("The unique name for the new entity.")
    required(:entity_type).filled(:string).description("The type classification for the new entity (e.g., 'Project', 'Task', 'Issue').")
    optional(:observations).array(:string).description("Optional list of initial observation strings associated with the entity.")
  end

  # Add validations if needed, e.g.:
  # validates :name, presence: true
  # validates :entityType, presence: true

  def call(name:, entity_type:, observations: [])
    logger.info "Performing CreateEntityTool with name: #{name}, entity_type: #{entity_type}, observations: #{observations.inspect}"

    begin
      new_entity = nil
      ActiveRecord::Base.transaction do
        new_entity = MemoryEntity.create!(
          name: name,
          entity_type: entity_type
        )

        observations.each do |obs_content|
          MemoryObservation.create!(
            memory_entity: new_entity,
            content: obs_content
          )
        end
      end

      new_entity.reload
      {
        id: new_entity.id,
        name: new_entity.name,
        entity_type: new_entity.entity_type,
        created_at: new_entity.created_at.iso8601,
        updated_at: new_entity.updated_at.iso8601,
        observations: new_entity.memory_observations.map do |obs|
          {
            id: obs.id,
            memory_entity_id: obs.memory_entity_id,
            content: obs.content,
            created_at: obs.created_at.iso8601,
            updated_at: obs.updated_at.iso8601
          }
        end
      }
    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateEntityTool: #{e.message}"
      raise FastMcp::Errors::InvalidParameters, "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
    rescue => e
      logger.error "Unexpected error in CreateEntityTool: #{e.message}\n#{e.backtrace.join("\n")}"
      raise FastMcp::Errors::InternalError, "Internal Server Error: #{e.message}"
    end
  end
end
