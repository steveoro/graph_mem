# frozen_string_literal: true

class CreateObservationTool < ApplicationTool
  def self.tool_name
    "create_observation"
  end

  mcp_metadata(
    profiles: %i[default maintenance],
    advertised: false,
    read_only_hint: false,
    destructive_hint: false,
    idempotent_hint: false,
    open_world_hint: false
  )

  description "Add a new fact to an existing entity and generate an embedding. Pass required `entity_id` " \
    "(integer; also accepts entity name) and `text_content` (string); optional `confidence` (float 0-1), " \
    "`source` (string), `valid_from` (ISO 8601 string), `valid_until` (ISO 8601 string), `tags` (array of strings). " \
    "Aliases `content`/`contents` map to `text_content`. Do not use to edit or supersede an existing observation; " \
    "use `graph_edit` instead. Do not use to mark a fact obsolete; use `graph_delete` instead. " \
    "Do not use to create a new node; use `graph_write` instead. " \
    "Do not use for a batch of up to 50 creates; use `graph_write` instead."

  arguments do
    required(:entity_id).filled(:integer).description("The ID of the entity to add the observation to")
    required(:text_content).filled(:string).description("The textual content of the observation")
    optional(:confidence).maybe(:float).description("Optional confidence score from 0.0 to 1.0.")
    optional(:source).maybe(:string).description("Optional source or provenance identifier.")
    optional(:valid_from).maybe(:string).description("Optional ISO 8601 start of the validity period.")
    optional(:valid_until).maybe(:string).description("Optional ISO 8601 end of the validity period.")
    optional(:tags).array(:string).description("Optional list of tags.")
  end

  def call(entity_id:, text_content:, confidence: nil, source: nil, valid_from: nil, valid_until: nil, tags: [])
    logger.info "Performing CreateObservationTool with entity_id: #{entity_id}, text_content: '#{text_content}'"
    begin
      GraphWriteService.execute_one(
        "create_observation",
        {
          entity_id: entity_id,
          text_content: text_content,
          confidence: confidence,
          source: source,
          valid_from: valid_from,
          valid_until: valid_until,
          tags: tags
        },
        logger: logger
      )
    rescue ActiveRecord::RecordNotFound => e
      error_message = "Entity with ID=#{entity_id} not found."
      logger.error "ResourceNotFound in CreateObservationTool: #{error_message} (was: #{e.message})"
      raise McpGraphMemErrors::ResourceNotFound.new(
        error_message,
        next_move: "Call `search` to find the entity, then retry `graph_write`."
      )
    rescue ActiveRecord::RecordInvalid => e
      error_message = "Validation Failed: #{e.record.errors.full_messages.join(', ')}. " \
        "Correct `text_content` and optional fields to match the `graph_write` schema and retry."
      logger.error "InvalidArguments in CreateObservationTool: #{error_message} (was: #{e.message})"
      raise FastMcp::Tool::InvalidArgumentsError, error_message
    rescue FastMcp::Tool::InvalidArgumentsError => e
      raise FastMcp::Tool::InvalidArgumentsError,
            "Validation Failed: #{e.message}. Correct fields and retry `graph_write`."
    rescue McpGraphMemErrors::Error
      raise
    rescue StandardError => e
      raise if ToolError::TIMEOUT_CLASSES.any? { |klass| e.is_a?(klass) }

      logger.error "InternalServerError in CreateObservationTool: #{e.class}: #{e.message} - #{e.backtrace.join("\n")}"
      raise McpGraphMemErrors::InternalServerError, "An unexpected error occurred."
    end
  end
end
