# frozen_string_literal: true

module Operator
  class AuditLogsController < ApplicationController
    helper AuditLogsHelper

    def index
      @filters = AuditLog.normalize_filter_params(filter_params)
      scoped = AuditLog.filter(filter_params)
      @summary = {
        total: AuditLog.count,
        filtered_count: scoped.count,
        expired_count: AuditLog.expired.count
      }
      @audit_logs = scoped.page(params[:page]).per(AuditLog::PER_PAGE)
    end

    def prune
      pruned = AuditLog.prune!
      redirect_to operator_audit_logs_path(filter_redirect_params),
                  notice: t("operator.audit_logs.prune_notice", count: pruned)
    end

    private

    def filter_redirect_params
      AuditLog.normalize_filter_params(filter_params).compact
    end

    def filter_params
      params.permit(:log_action, :auditable_type, :actor, :auditable_id, :since_days, :page)
    end
  end
end
