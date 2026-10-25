# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Generates an MCP::Prompt class from an ApplicationPrompt subclass.
    module PromptWrapper
      Result = Data.define(:payload) do
        def to_h = payload
      end

      # @param prompt_class [Class<ApplicationPrompt>]
      # @return [Class<MCP::Prompt>]
      def self.build(prompt_class)
        arguments = Array(prompt_class.arguments).map do |argument|
          MCP::Prompt::Argument.new(name: argument[:name].to_s, description: argument[:description], required: argument[:required] == true)
        end

        Class.new(MCP::Prompt) do
          prompt_name prompt_class.prompt_name
          description prompt_class.description
          arguments arguments

          define_singleton_method(:template) do |args, server_context: nil|
            messages = prompt_class.new.messages(**(args || {}).to_h.transform_keys(&:to_sym))
            Result.new({ description: prompt_class.description.to_s, messages: messages })
          end
        end
      end
    end
  end
end
