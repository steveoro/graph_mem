# frozen_string_literal: true

class UpdateObservationTool < ApplicationTool
  def self.tool_name
    "update_observation"
  end

  description "Updates an active observation in place or supersedes it with a new observation version. " \
    "Superseded observations are retained for history and excluded from reads and search by default."

  arguments do
    required(:observation_id).filled(:integer).description("The ID of the active observation to update.")
    optional(:text_content).maybe(:string).description("Replacement observation content.")
    optional(:confidence).maybe(:float).description("Confidence score from 0.0 to 1.0.")
    optional(:source).maybe(:string).description("Source or provenance identifier.")
    optional(:valid_from).maybe(:string).description("ISO 8601 start of the validity period.")
    optional(:valid_until).maybe(:string).description("ISO 8601 end of the validity period.")
    optional(:tags).array(:string).description("Structured tags.")
    optional(:supersede).filled(:bool).description("Create a replacement and retain this observation as superseded.")
    optional(:reason).maybe(:string).description("Reason for supersession.")
  end

  def call(observation_id:, supersede: false, reason: nil, **attributes)
    update_attributes = normalize_attributes(attributes)
    if update_attributes.empty?
      raise FastMcp::Tool::InvalidArgumentsError, "At least one observation attribute must be provided for update."
    end

    observation = MemoryObservation.find(observation_id)
    result = if supersede
      observation.supersede!(update_attributes, reason: reason)
    else
      observation.update_active!(update_attributes)
    end

    MemoryObservationSerializer.call(
      result,
      content_key: :observation_content,
      include_entity_id: true
    ).merge(superseded_observation_id: supersede ? observation.id : nil)
  rescue FastMcp::Tool::InvalidArgumentsError
    raise
  rescue ActiveRecord::RecordNotFound
    raise McpGraphMemErrors::ResourceNotFound, "Observation with ID=#{observation_id} not found."
  rescue MemoryObservation::InactiveObservationError => e
    raise FastMcp::Tool::InvalidArgumentsError, e.message
  rescue ActiveRecord::RecordInvalid => e
    message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}"
    raise FastMcp::Tool::InvalidArgumentsError, message
  rescue McpGraphMemErrors::ResourceNotFound
    raise
  rescue StandardError => e
    logger.error "InternalServerError in UpdateObservationTool: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An internal server error occurred in UpdateObservationTool: #{e.message}"
  end

  private

  def normalize_attributes(attributes)
    attributes = attributes.slice(:text_content, :confidence, :source, :valid_from, :valid_until, :tags)
    attributes[:content] = attributes.delete(:text_content) if attributes.key?(:text_content)
    attributes
  end
end
