# frozen_string_literal: true

module GraphMem
  module OfficialMcp
    # Builds one MCP::Server per profile (default, readonly, maintenance).
    #
    # @example
    #   ServerFactory.for(:readonly).tools.keys # => the 9 read tools
    module ServerFactory
      # graph_mem sends no list_changed, resources/updated or logging notifications (its lists are
      # fixed at boot), so it advertises none; the gem's default would.
      CAPABILITIES = {
        resources: { subscribe: false, listChanged: false },
        tools: { listChanged: false },
        prompts: { listChanged: false }
      }.freeze

      # The capabilities a server declares: CAPABILITIES (the same frozen object) when no extension is
      # on; otherwise CAPABILITIES with one `extensions` Hash holding the MCP Apps extension
      # (io.modelcontextprotocol/ui) and/or the Skills extension (io.modelcontextprotocol/skills,
      # never directoryRead). A plain Hash on purpose: an MCP::Server::Capabilities object would drop
      # the explicit false values.
      #
      # @param apps_enabled [Boolean]
      # @param skills_enabled [Boolean]
      # @return [Hash]
      def self.capabilities(apps_enabled:, skills_enabled: false)
        extensions = {}
        extensions.merge!(MCP::Apps.capability) if apps_enabled
        extensions.merge!(MCP::Skill.capability) if skills_enabled
        extensions.empty? ? CAPABILITIES : CAPABILITIES.merge(extensions: extensions)
      end

      # @param profile [Symbol, String] one of GraphMem::McpProfile::NAMES
      # @param apps_enabled [Boolean] declare the MCP Apps extension and list the profile's views
      # @param skills_enabled [Boolean] declare the Skills extension and serve the profile's skills
      # @return [MCP::Server]
      def self.for(profile, apps_enabled: GraphMem::McpApps.enabled?, skills_enabled: GraphMem::McpSkills.enabled?)
        profile = GraphMem::McpProfile.normalize(profile)
        GraphMem::McpToolRegistry.load_all!
        providers = [ TemplateResourceProvider.new(GraphMem::McpToolRegistry.resource_classes) ]
        providers << GraphMem::McpApps::Views.provider_for(profile) if apps_enabled
        views = apps_enabled ? GraphMem::McpApps::Views.uris_for(profile) : []
        # nil, never []: an empty Array would still register skills/list and skills/get. A skills
        # tree that can't be loaded gives nil too, and the extension isn't declared.
        skills = skills_enabled ? GraphMem::McpSkills.for_server(profile) : nil
        skills_enabled = !skills.nil?

        server = MCP::Server.new(
          name: "graph-mem",
          version: GraphMem::VERSION.to_s,
          instructions: GraphMem::McpInstructions.for(profile),
          capabilities: capabilities(apps_enabled: apps_enabled, skills_enabled: skills_enabled),
          tools: GraphMem::McpToolRegistry.tool_classes_for(profile).select(&:mcp_advertised?).map { |klass| ToolWrapper.build(klass, views: views) },
          prompts: GraphMem::McpToolRegistry.prompt_classes_for(profile).map { |klass| PromptWrapper.build(klass) },
          resources: ResourceCatalog.resources(providers),
          resource_templates: ResourceCatalog.templates(providers),
          skills: skills,
          configuration: OfficialMcp.configuration
        )
        server.resources_read_handler { |params| read(providers, skills, params) }
        server
      end

      # resources/read. This handler replaces the gem's reader, so it serves the skill files itself:
      # MCP::Skill.read_file first, then the resource providers. A skill:// URI under a served skill
      # that names none of its files answers -32602 "Skill file not found", as the gem's reader does;
      # any other unknown URI is ResourceCatalog's ResourceNotFoundError (also -32602).
      #
      # @param providers [Array] the resource providers
      # @param skills [Array<MCP::Skill>, nil] the served skills, nil when the extension is off
      # @param params [Hash] the request params, with :uri
      # @return [Array<Hash>] the contents
      # @raise [MCP::Server::RequestHandlerError]
      def self.read(providers, skills, params)
        uri = params[:uri].to_s
        if skills
          contents = MCP::Skill.read_file(skills, uri)
          return contents if contents
          raise skill_file_not_found(uri, params) if skills.any? { |skill| uri.start_with?("skill://#{skill.skill_path.join('/')}/") }
        end
        ResourceCatalog.read(providers, uri)
      end

      def self.skill_file_not_found(uri, params)
        MCP::Server::RequestHandlerError.new(
          "Skill file not found: #{uri.dump}", params,
          error_type: :invalid_params, error_code: JsonRpcHandler::ErrorCode::INVALID_PARAMS, error_data: { uri: uri.dup.force_encoding(Encoding::UTF_8).scrub }
        )
      end
      private_class_method :skill_file_not_found
    end
  end
end
