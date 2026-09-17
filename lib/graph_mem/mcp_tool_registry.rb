# frozen_string_literal: true

require_relative "mcp_profile"

module GraphMem
  # Ensures all MCP tool/resource/prompt classes are loaded before registration.
  #
  # In development, ApplicationTool.descendants only includes classes already
  # autoloaded at registration time. New files under app/tools/ are not picked
  # up unless we constantize them explicitly first.
  module McpToolRegistry
    TOOL_GLOB = "app/tools/**/*_tool.rb"
    RESOURCE_GLOB = "app/resources/**/*_resource.rb"
    PROMPT_GLOB = "app/prompts/**/*_prompt.rb"
    TEST_CLASS_PATTERN = /Test(?:Tool|Prompt)$/

    module_function

    def load_all!
      load_glob(TOOL_GLOB)
      load_glob(RESOURCE_GLOB)
      load_glob(PROMPT_GLOB)
    end

    def register_with!(server, profile: nil)
      load_all!
      classes = profile ? tool_classes_for(profile) : tool_classes
      server.register_tools(*classes)
      server.register_resources(*resource_classes)
      server.register_prompts(*prompt_classes)
      server
    end

    def tool_classes
      ApplicationTool.descendants.reject { |klass| skip_class?(klass) }
    end

    def tool_classes_for(profile)
      GraphMem::McpProfile.select_tools(tool_classes, profile)
    end

    def resource_classes
      return [] unless defined?(ApplicationResource)

      ApplicationResource.descendants.reject { |klass| skip_class?(klass) }
    end

    def prompt_classes
      return [] unless defined?(ApplicationPrompt)

      ApplicationPrompt.descendants.reject { |klass| skip_class?(klass) }
    end

    def load_glob(pattern)
      Rails.root.glob(pattern).sort.each { |path| constantize_path(path) }
    end

    def constantize_path(path)
      # app/tools/*.rb map to top-level constants (e.g. BulkUpdateTool), not Tools::*
      File.basename(path, ".rb").camelize.constantize
    end

    def skip_class?(klass)
      klass.name.nil? || klass.name.match?(TEST_CLASS_PATTERN)
    end
  end
end
