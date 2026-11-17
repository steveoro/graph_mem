# frozen_string_literal: true

module GraphMem
  # MCP Apps (SEP-1865, extension io.modelcontextprotocol/ui; docs/plans/mcp-apps-plan.md): the
  # interactive views graph_mem serves as ui:// resources, and whether they are on.
  module McpApps
    # Whether servers built now declare the extension, list the views and link tools to them
    # (Settings › mcp_apps_enabled, default on). Servers are built once per transport: a change
    # rebuilds the HTTP ones (SettingsGroupUpdate) and needs a stdio runner restart.
    #
    # @return [Boolean]
    def self.enabled?
      AppSettings.mcp_apps_enabled?
    end
  end
end
