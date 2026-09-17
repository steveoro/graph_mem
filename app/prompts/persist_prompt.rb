# frozen_string_literal: true

class PersistPrompt < ApplicationPrompt
  prompt_name "persist"
  description "Persist newly learned facts safely before ending work."

  # Renders the end-of-task persistence workflow.
  #
  # @return [Array<Hash>] one MCP user message
  def messages
    [
      {
        role: "user",
        content: {
          type: "text",
          text: <<~TEXT.strip
            Persist durable GraphMem knowledge:
            1. Search or load the target entity first; do not restate an active fact.
            2. Use graph_write create_observation for new facts.
            3. Use graph_edit update_observation with supersede when correcting history.
            4. Use graph_write create_entity/create_relation for new concepts and links.
            5. Follow possible_duplicate and next_move responses; never force a duplicate.
          TEXT
        }
      }
    ]
  end
end
