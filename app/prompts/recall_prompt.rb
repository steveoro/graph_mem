# frozen_string_literal: true

class RecallPrompt < ApplicationPrompt
  prompt_name "recall"
  description "Run before choosing a convention or first editing a file or component: recalls rules by " \
              "topic, file paths and decision type."
  mcp_metadata(profiles: %i[default readonly maintenance])
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
            Recall GraphMem knowledge for: #{topic.inspect}
            1. Call search with the topic, then search again with this task's file paths, component names and decision types (for example "version bump", "changelog", "docs examples", "tests", "config").
            2. Load the best ids with get_entities. If you haven't yet this session, also load the project's Conventions entity and the global User Preferences entity.
            3. Turn each relevant rule into a checklist item for this task. If a rule depends on a value you don't have yet (a tier, a flag, a config key, a version), find that value in the repository or project metadata before acting.
            4. When rules conflict, follow the newest active observation and mention the conflict in your reply.
            5. Use traverse_graph or find_shortest_path only when structure matters, and summarize only for a source-backed overview.
            Prefer active observations; maintenance tools exist only on the maintenance profile.
          TEXT
        }
      }
    ]
  end
end
