# frozen_string_literal: true

class MaintenanceController < ApplicationController
  def index
    @root_nodes = ExportStrategy.new.root_nodes
    @graph_stats = MaintenanceDashboardSnapshot.call[:graph_stats]
  end
end
