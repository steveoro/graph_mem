# frozen_string_literal: true

class UpdateObservationTool < ApplicationTool
  def self.tool_name
    "update_observation"
  end

  description "Edit an active observation in place or, with supersede true, create a replacement and mark the original " \
    "superseded. Pass required `observation_id` (integer); optional `text_content`, `confidence`, `source`, " \
    "`valid_from`, `valid_until`, `tags`, `supersede` (bool, default false), `reason`. Inactive observations cannot be edited. " \
    "Do not use to add a new fact; use `create_observation` instead. " \
    "Do not use to obsolete a fact without replacement; use `delete_observation` instead. " \
    "Do not use to change entity metadata; use `update_entity` instead."

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
      raise FastMcp::Tool::InvalidArgumentsError,
            "At least one observation attribute must be provided for update. " \
            "Provide `text_content`, `confidence`, `source`, `valid_from`, `valid_until`, or `tags` and retry."
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
  rescue ActiveRecord::RecordNotFound => e
    error_message = "Observation with ID=#{observation_id} not found."
    logger.error "ResourceNotFound in UpdateObservationTool: #{error_message} (was: #{e.message})"
    raise McpGraphMemErrors::ResourceNotFound.new(
      error_message,
      next_move: "Call `get_entity` with include_obsolete if needed to list observation ids, then retry `update_observation`."
    )
  rescue MemoryObservation::InactiveObservationError => e
    logger.error "InvalidArguments in UpdateObservationTool: #{e.message}"
    raise FastMcp::Tool::InvalidArgumentsError,
          "#{e.message} Call `delete_observation` or `create_observation` instead of `update_observation`."
  rescue ActiveRecord::RecordInvalid => e
    message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}. " \
      "Correct the observation fields to match the `update_observation` schema and retry."
    logger.error "InvalidArguments in UpdateObservationTool: #{message} (was: #{e.message})"
    raise FastMcp::Tool::InvalidArgumentsError, message
  rescue StandardError => e
    raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }
    raise if e.is_a?(McpGraphMemErrors::Error)

    logger.error "InternalServerError in UpdateObservationTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
    raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
  end

  private

  def normalize_attributes(attributes)
    attributes = attributes.slice(:text_content, :confidence, :source, :valid_from, :valid_until, :tags)
    attributes[:content] = attributes.delete(:text_content) if attributes.key?(:text_content)
    attributes
  end
end
