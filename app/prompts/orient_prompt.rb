# frozen_string_literal: true

class OrientPrompt < ApplicationPrompt
  prompt_name "orient"
  description "Start a GraphMem session with the correct project context."

  # Renders the session-orientation workflow.
  #
  # @return [Array<Hash>] one MCP user message
  def messages
    [
      {
        role: "user",
        content: {
          type: "text",
          text: <<~TEXT.strip
            Start GraphMem session orientation:
            1. Call get_context.
            2. If no context is active, call search for the relevant Project.
            3. Call set_context with that Project entity id.
            Context is per X-MCP-Client and search context boosts rather than hard-filters results.
          TEXT
        }
      }
    ]
  end
end
