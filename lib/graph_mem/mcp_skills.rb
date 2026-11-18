# frozen_string_literal: true

module GraphMem
  # Skills over MCP (SEP-2640, extension io.modelcontextprotocol/skills; docs/plans/auto-adoption-plan.md
  # section 6): the repo's skills/ served as skill:// resources, and whether they are on.
  #
  # @example
  #   GraphMem::McpSkills.for(:readonly).map(&:name) # => ["graph-mem-mcp-toolset"]
  module McpSkills
    ROOT = Rails.root.join("skills").to_s

    # The profiles that serve each skill. project-scan calls graph_write and set_context, and
    # scan_project is maintenance-only, so it stays off readonly (auto-adoption-tests.md Q2, static
    # part). A skill missing here is served nowhere: adding one to skills/ is a choice made here.
    PROFILES = {
      "graph-mem-mcp-toolset" => %i[default readonly maintenance],
      "project-scan" => %i[default maintenance]
    }.freeze

    # Whether servers built now declare the extension and serve the skills (Settings ›
    # mcp_skills_enabled, default off). Like McpApps, a change rebuilds the HTTP servers
    # (SettingsGroupUpdate) and needs a stdio runner restart.
    #
    # @return [Boolean]
    def self.enabled?
      AppSettings.mcp_skills_enabled?
    end

    # The skills a profile serves, read from disk on every call (once per server build): the gem
    # records each file's digest at registration and refuses a file changed since with -32603, so
    # a rebuilt server or a restarted runner picks up edited skills.
    #
    # @param profile [Symbol, String] one of McpProfile::NAMES
    # @param root [String] the directory holding the skill directories
    # @return [Array<MCP::Skill>] sorted by URI
    # @raise [McpProfile::InvalidProfile] for an unknown profile
    # @raise [ArgumentError] when a skill under root breaks the SEP-2640 or Agent Skills rules
    def self.for(profile, root: ROOT)
      profile = McpProfile.normalize(profile)
      MCP::Skill.from_directory(root.to_s).select { |skill| PROFILES.fetch(skill.name, []).include?(profile) }
    end

    # {for}, for a server build: a file under root the gem refuses (a stray editor file, a hard
    # link, a skill breaking the rules) must not take the tools down with it, so it is logged and
    # the server is built without the extension.
    #
    # @param profile [Symbol, String]
    # @param root [String]
    # @return [Array<MCP::Skill>, nil] nil when the skills can't be loaded
    # @raise [McpProfile::InvalidProfile] for an unknown profile (not swallowed)
    def self.for_server(profile, root: ROOT)
      profile = McpProfile.normalize(profile)
      self.for(profile, root: root)
    rescue McpProfile::InvalidProfile
      raise
    rescue ArgumentError => e
      Rails.logger.warn("[McpSkills] skills not served on #{profile}: #{e.message}")
      Rails.error.report(e, handled: true, context: { profile: profile.to_s })
      nil
    end
  end
end
