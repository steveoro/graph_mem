# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Generates an MCP::Tool class from an ApplicationTool subclass, so tool code stays as it is.
    #
    # @example
    #   ToolWrapper.build(SearchTool) # => Class < MCP::Tool, tool_name "search"
    module ToolWrapper
      ANNOTATION_KEYS = ApplicationTool::MCP_ANNOTATION_KEYS

      # The gem rejects a call missing a `required` key before the tool runs, with its own text.
      # graph_mem tools accept aliases for required keys (`entityType`, names for ids) and
      # validate after normalising, so the tool decides and answers with the ToolError envelope.
      class LenientInputSchema < MCP::Tool::InputSchema
        # @return [Array<String>] always empty
        def missing_required_arguments(_arguments) = []
      end

      # Any object with #to_h is a valid tools/call result for the gem.
      Result = Data.define(:payload) do
        def to_h = payload
      end

      # @param tool_class [Class<ApplicationTool>]
      # @return [Class<MCP::Tool>] with the tool's name, description, schemas and annotations
      def self.build(tool_class)
        wrapper = self
        hints = tool_class.annotations.to_h.slice(*ANNOTATION_KEYS)
        output_schema = tool_class.output_schema_to_json

        Class.new(MCP::Tool) do
          tool_name tool_class.tool_name
          description tool_class.description
          input_schema LenientInputSchema.new(tool_class.input_schema_to_json)
          output_schema(output_schema) if output_schema
          annotations(**hints) if hints.any?

          define_singleton_method(:graph_mem_tool_class) { tool_class }
          define_singleton_method(:call) do |server_context: nil, **args|
            wrapper.invoke(tool_class, args, RequestContext.from_server_context(server_context))
          end
        end
      end

      # Runs the tool as before (normaliser, validation, telemetry, next_move) and returns the
      # same tools/call result; every error becomes the ToolError envelope as an isError result.
      #
      # @param tool_class [Class<ApplicationTool>]
      # @param args [Hash{Symbol => Object}]
      # @param context [RequestContext::Context]
      # @return [Result]
      def self.invoke(tool_class, args, context)
        context.around_call do
          tool = tool_class.new(headers: context.headers)
          result, meta = tool.call_with_schema_validation!(**args)
          Result.new(format(tool_class, result, meta))
        end
      rescue StandardError => e
        Result.new({ content: [ { type: "text", text: ToolError.dump(e, tool_name: tool_class.tool_name) } ], isError: true })
      end

      # The result shape graph_mem has always sent: text content, plus structuredContent when the
      # tool has an output schema, plus `_meta` (version, next_move, …).
      #
      # @return [Hash]
      def self.format(tool_class, result, meta)
        formatted = if result.is_a?(Hash) && result.key?(:content)
          result
        elsif tool_class.output_schema_to_json && result.is_a?(Hash)
          structured = JSON.parse(JSON.generate(result))
          { content: [ { type: "text", text: JSON.generate(structured) } ], structuredContent: structured, isError: false }
        else
          { content: [ { type: "text", text: text_for(result) } ], isError: false }
        end
        meta.is_a?(Hash) && meta.any? ? formatted.merge(_meta: meta) : formatted
      end

      def self.text_for(result)
        case result
        when String then result
        when Hash, Array then JSON.generate(result)
        else result.to_s
        end
      end
    end
  end
end
