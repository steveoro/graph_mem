# frozen_string_literal: true

# Vendored from fast-mcp 1.8.0 (https://github.com/yjacquin/fast-mcp, fork https://github.com/steveoro/fast-mcp,
# tag 1.8.0), MIT License, Copyright (c) 2025 Yorick Jacquin. Namespaced under GraphMem::McpSchema;
# the full licence text is in lib/graph_mem/mcp_schema/LICENSE.fast-mcp.

module GraphMem
  module McpSchema
    # The prompt class API: `prompt_name`, `description`, `argument` declarations and `#messages`.
    #
    # @example
    #   class GreetPrompt
    #     include GraphMem::McpSchema::PromptApi
    #     prompt_name "greet"
    #     argument :name, description: "Who to greet", required: true
    #     def messages(name:) = [ { role: "user", content: { type: "text", text: "Greet #{name}" } } ]
    #   end
    module PromptApi
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Class-level declarations.
      module ClassMethods
        # Sets or returns the prompt name (default: the class name without "Prompt", snake_cased).
        def prompt_name(value = nil)
          @prompt_name = value.to_s if value
          @prompt_name || default_prompt_name
        end

        # Sets or returns the description.
        def description(value = nil)
          @description = value if value
          @description
        end

        # Declares an argument.
        #
        # @return [Hash] { name:, required:, description: }
        def argument(name, description: nil, required: false)
          @arguments ||= []
          definition = { name: name.to_s, required: required == true }
          definition[:description] = description if description
          @arguments << definition.freeze
          definition
        end

        # @return [Array<Hash>] this prompt's arguments, inherited ones first
        def arguments
          inherited = superclass.respond_to?(:arguments) ? superclass.arguments : []
          (inherited + (@arguments || [])).uniq { |argument| argument[:name] }
        end

        private

        def default_prompt_name
          return if name.nil?

          name.split("::").last.sub(/Prompt\z/, "").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end
      end

      # @return [Array<Hash>] the prompt's messages
      def messages(**_arguments)
        raise NotImplementedError, "#{self.class.name} must implement #messages"
      end
    end
  end
end
