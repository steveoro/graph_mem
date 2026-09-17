# frozen_string_literal: true

module Operator
  # Presents read-only MCP tool telemetry and retention controls.
  class TelemetryController < BaseController
    helper Operator::TelemetryHelper

    # Renders aggregate analytics and filtered invocation details.
    #
    # @return [void]
    def index
      @filters = ToolInvocation.normalize_filter_params(filter_params)
      @snapshot = ToolTelemetryDashboardSnapshot.call(filters: @filters)
      @tool_invocations = ToolInvocation.filter(@filters)
                                        .page(params[:page])
                                        .per(ToolInvocation::PER_PAGE)
      @filter_options = filter_options
    end

    # Deletes rows outside the configured retention window.
    #
    # @return [void]
    def prune
      pruned = ToolInvocation.prune!
      redirect_to operator_telemetry_path(filter_redirect_params),
                  notice: t("operator.telemetry.prune.notice", count: pruned)
    end

    private

    def filter_redirect_params
      ToolInvocation.normalize_filter_params(filter_params).compact
    end

    def filter_params
      params.permit(:since_days, :tool_name, :client_id, :outcome, :error_category, :page)
    end

    def filter_options
      {
        tool_names: ToolInvocation.distinct.order(:tool_name).pluck(:tool_name),
        client_ids: ToolInvocation.distinct.order(:client_id).pluck(:client_id),
        error_categories: error_categories
      }
    end

    def error_categories
      categories = ToolInvocation.errors.where.not(error_category: [ nil, "" ])
                                 .distinct.order(:error_category).pluck(:error_category)
      categories << "uncategorized" if ToolInvocation.errors.where(error_category: [ nil, "" ]).exists?
      categories
    end
  end
end
