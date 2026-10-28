# frozen_string_literal: true

# The maintenance hub: export, import and cleanup, plus (until UI-5's Review › Generate and UI-6's
# Projects page land) the controls that left Home in UI-2b: the compactor, garbage collection,
# relation repair, project scans and the full MCP clients table.
class MaintenanceController < ApplicationController
  def index
    @root_nodes = ExportStrategy.new.root_nodes
    @snapshot = MaintenanceDashboardSnapshot.call
    @graph_stats = @snapshot[:graph_stats]
  end
end
