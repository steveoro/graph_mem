# frozen_string_literal: true

module GraphMem
  # Ensures all MCP tool/resource classes are loaded before FastMcp registration.
  #
  # In development, ApplicationTool.descendants only includes classes already
  # autoloaded at registration time. New files under app/tools/ are not picked
  # up unless we constantize them explicitly first.
  module McpToolRegistry
    TOOL_GLOB = "app/tools/**/*_tool.rb"
    RESOURCE_GLOB = "app/resources/**/*_resource.rb"
    TEST_TOOL_PATTERN = /TestTool$/

    module_function

    def load_all!
      load_glob(TOOL_GLOB)
      load_glob(RESOURCE_GLOB)
    end

    def register_with!(server)
      load_all!
      server.register_tools(*tool_classes)
      server.register_resources(*resource_classes)
      server
    end

    def tool_classes
      ApplicationTool.descendants.reject { |klass| skip_class?(klass) }
    end

    def resource_classes
      return [] unless defined?(ApplicationResource)

      ApplicationResource.descendants.reject { |klass| skip_class?(klass) }
    end

    def load_glob(pattern)
      Rails.root.glob(pattern).sort.each { |path| constantize_path(path) }
    end

    def constantize_path(path)
      # app/tools/*.rb map to top-level constants (e.g. BulkUpdateTool), not Tools::*
      File.basename(path, ".rb").camelize.constantize
    end

    def skip_class?(klass)
      klass.name.nil? || klass.name.match?(TEST_TOOL_PATTERN)
    end
  end
end
