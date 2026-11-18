# frozen_string_literal: true

module GraphMem
  # Per-profile MCP server `instructions` text: when an agent should reach for
  # graph_mem (every coding task, in any repository) and which tools to call.
  #
  # Sent as `instructions` in the `initialize` result, one text per profile
  # (GraphMem::OfficialMcp::ServerFactory). Hosts that defer tool definitions
  # load this text at session start, so it opens with the trigger and names the
  # tools to call; prompts are mentioned only as something the user can type.
  #
  # @example
  #   GraphMem::McpInstructions.for(:readonly) # => "Use graph_mem in EVERY coding task ..."
  class McpInstructions
    TRIGGER = "Use graph_mem in EVERY coding task in ANY repository, not only in graph_mem itself: it holds this " \
              "user's conventions, preferences, file locations and verified fixes for all their projects, learned " \
              "in earlier sessions."
    ORIENT = "1. First tool calls of a session, before reading or editing code: `get_context`; if no project is " \
             "active, `search` for the repository name and `set_context` to its Project entity; then " \
             "`get_entities` for \"<Project> Conventions\" and \"User Preferences\". Skip any that don't exist yet."
    RECALL = "2. Before choosing a convention (version bump, changelog, docs or test style, naming, config " \
             "location, release steps) or first editing a file or component: `search` with the file paths and " \
             "component names. Prefer a stored rule over your own default."
    PERSIST = "3. Before your final reply, if the user corrected you, stated a preference, or you verified a fix " \
              "or a location: save it as one general rule with `graph_write` (or `graph_edit` with supersede to " \
              "replace an old rule)."
    SAFETY = "Prefer entity ids over names for edits and deletes. Maintenance tools are on /mcp/maintenance."
    PROMPTS = "The user can also type the `orient`, `recall` and `persist` prompts."
    READONLY_PROMPTS = "The user can also type the `orient` and `recall` prompts."

    TEXTS = {
      default: [ TRIGGER, ORIENT, RECALL, PERSIST, "#{PROMPTS} #{SAFETY}" ].join("\n"),
      readonly: [ TRIGGER, ORIENT, RECALL, "#{READONLY_PROMPTS} #{SAFETY}" ].join("\n"),
      maintenance: [ TRIGGER, ORIENT, RECALL, PERSIST, "#{PROMPTS} #{SAFETY}" ].join("\n")
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
