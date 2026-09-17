# frozen_string_literal: true

class RecallPrompt < ApplicationPrompt
  prompt_name "recall"
  description "Recall source-backed GraphMem knowledge for a topic before work."
  argument :topic, description: "Keywords or subject to recall", required: true

  # Renders the topic-specific recall workflow.
  #
  # @param topic [String] subject or keywords to retrieve
  # @return [Array<Hash>] one MCP user message
  def messages(topic:)
    [
      {
        role: "user",
        content: {
          type: "text",
          text: <<~TEXT.strip
            Recall GraphMem knowledge about #{topic.inspect}:
            1. Call search with the topic.
            2. Load relevant known ids with get_entities.
            3. Use traverse_graph or find_shortest_path when structure matters.
            4. Use summarize only for a source-backed synthesized answer.
            Prefer active observations and inspect maintenance tools only on the maintenance profile.
          TEXT
        }
      }
    ]
  end
end
