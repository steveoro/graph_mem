# frozen_string_literal: true

module GraphMem
  # Per-profile MCP server `instructions` text: what graph_mem is and when an
  # agent should recall from it or write to it.
  #
  # Not sent yet: fast-mcp 1.7.1 cannot deliver `instructions`. The initializer
  # wires it in once graph_mem runs on fast-mcp 1.8.0.
  #
  # @example
  #   GraphMem::McpInstructions.for(:readonly) # => "graph_mem is a shared knowledge graph ..."
  class McpInstructions
    INTRO = "graph_mem is a shared knowledge graph of what earlier agent sessions learned about this user's " \
            "projects: conventions, preferences, where things live, and verified fixes."
    ORIENT = "At the start of a task, run the `orient` prompt or call `get_context`, then load the project's " \
             "Conventions entity."
    RECALL = "Before choosing a convention (versioning, changelog, docs or test style, config, release steps) or " \
             "first editing a file or component, call `search` with the file paths and component names; if a rule " \
             "needs a value you don't have, look it up before acting."
    PERSIST = "Before your final reply, if the user corrected you, stated a preference, or you verified a fix or a " \
              "location, persist it as one general rule (`persist` prompt, `graph_write`, or `graph_edit` with " \
              "supersede to rewrite an old rule)."
    SAFETY = "Prefer entity ids over names for edits and deletes. Maintenance tools are on /mcp/maintenance."

    TEXTS = {
      default: [ INTRO, ORIENT, RECALL, PERSIST, SAFETY ].join("\n"),
      readonly: [ INTRO, ORIENT, RECALL, SAFETY ].join("\n"),
      maintenance: [ INTRO, ORIENT, RECALL, PERSIST, SAFETY ].join("\n")
    }.freeze

    # Returns the instructions text for a connection profile.
    #
    # @param profile [Symbol, String] one of {McpProfile::NAMES}
    # @return [String]
    # @raise [McpProfile::InvalidProfile] for an unknown profile
    def self.for(profile)
      TEXTS.fetch(McpProfile.normalize(profile))
    end
  end
end
