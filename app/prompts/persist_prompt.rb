# frozen_string_literal: true

class PersistPrompt < ApplicationPrompt
  prompt_name "persist"
  description "Run before your final reply when you were corrected, learned a preference or location, or " \
              "verified a fix."
  # Its workflow needs graph_write/graph_edit, which the readonly profile does not expose.
  mcp_metadata(profiles: %i[default maintenance])

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
            Persist durable GraphMem knowledge before your final reply:
            1. Keep only what a future session would need: user corrections and preferences, project conventions, where things live (paths, config keys, commands), verified fixes, and procedures that failed before they worked. Skip one-off task details.
            2. Write each as one general, imperative rule with its scope and reason: "In <project>, when <situation>, do <action> because <reason>." Drop incidental specifics (byte sizes, exact ids, timestamps) unless they are the rule.
            3. Search the owning entity first. If a rule on the same point exists, rewrite it with graph_edit update_observation and supersede: true; don't append another dated correction. Otherwise use graph_write create_observation with source ("<client>/<model>: <task>") and, for time-bound facts, valid_until.
            4. Put user preferences on the global "User Preferences" entity (type Preference), project conventions on "<Project> Conventions" (type BestPractice, part_of the Project), and environment facts on the component or configuration entity they describe. Create a missing home entity with graph_write create_entity first. New entities join the active context project, so create "User Preferences" after set_context with entity_id null, then restore the context.
            5. Follow possible_duplicate and next_move responses; never force a duplicate.
          TEXT
        }
      }
    ]
  end
end
