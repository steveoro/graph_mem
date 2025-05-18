# frozen_string_literal: true

class CreateEntityTool < ApplicationTool
  description "Create a new entity in the graph memory database."

  property :name, type: "string", description: "The unique name for the new entity.", required: true
  property :entityType, type: "string", description: "The type classification for the new entity (e.g., 'Project', 'Task', 'Issue').", required: true
  property :observations, type: "array", item_type: "string", description: "Optional list of initial observation strings associated with the entity."

  # Add validations if needed, e.g.:
  # validates :name, presence: true
  # validates :entityType, presence: true

  def perform
    current_observations = observations || [] # Handle optional observations
    logger.info "Performing CreateEntityTool with name: #{name}, entityType: #{entityType}, observations: #{current_observations.inspect}"

    begin
      new_entity = nil
      ActiveRecord::Base.transaction do
        new_entity = MemoryEntity.create!(
          name: name,
          entity_type: entityType # Assuming your model uses entity_type
        )

        current_observations.each do |obs_content|
          MemoryObservation.create!(
            memory_entity: new_entity,
            content: obs_content
          )
        end
      end

      new_entity.reload # Ensure observations are loaded
      result_hash = {
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
      render(text: result_hash.to_json, mime_type: "application/json")

    rescue ActiveRecord::RecordInvalid => e
      logger.error "Validation Failed in CreateEntityTool: #{e.message}"
      render(error: [ "Validation Failed: #{e.record.errors.full_messages.join(', ')}" ])
    rescue => e
      logger.error "Unexpected error in CreateEntityTool: #{e.message}\n#{e.backtrace.join("\n")}"
      render(error: [ "Internal Server Error: #{e.message}" ])
    end
  end
end
