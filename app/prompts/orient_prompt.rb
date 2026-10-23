# frozen_string_literal: true

class OrientPrompt < ApplicationPrompt
  prompt_name "orient"
  description "Run at the start of a task: sets the project context and loads its conventions and the " \
              "user's preferences."
  mcp_metadata(profiles: %i[default readonly maintenance])

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
            2. If no context is active, call search for the Project this task belongs to, then call set_context with its entity id.
            3. Load the project's "<Project> Conventions" entity and the global "User Preferences" entity with get_entities (search for them by name if you don't have their ids; skip any that don't exist yet).
            4. Keep their active rules as a checklist for this session; a newer active observation overrides an older one.
            5. Before choosing a convention or first editing a file or component, run recall or search by those file paths and component names.
            Context is per X-MCP-Client, and the context project boosts search results rather than filtering them.
          TEXT
        }
      }
    ]
  end
end
