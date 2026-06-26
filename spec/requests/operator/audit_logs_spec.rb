# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator audit logs", type: :request do
  let!(:entity) { MemoryEntity.create!(name: "AuditBrowseEntity", entity_type: "Project") }

  describe "GET /operator/audit_logs" do
    it "redirects unauthenticated users to login" do
      get operator_audit_logs_path

      expect(response).to redirect_to(operator_login_path)
    end

    context "when signed in" do
      before { sign_in_operator }

      it "renders the audit log browse page with default 7-day window" do
        recent = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "update", changed_fields: { "name" => { "from" => "A", "to" => "B" } },
          actor: "mcp:update_entity"
        )
        old = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "create", changed_fields: {},
          created_at: 10.days.ago
        )

        get operator_audit_logs_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Audit Logs")
        expect(response.body).to include("mcp:update_entity")
        expect(response.body).to include("audit-log-#{recent.id}")
        expect(response.body).not_to include("audit-log-#{old.id}")
        expect(response.body).to include('id="audit_filter_since_days"')
      end

      it "filters by action" do
        update_log = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "update", changed_fields: {}
        )
        delete_log = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "delete", changed_fields: {}
        )

        get operator_audit_logs_path(since_days: "all", log_action: "update")

        expect(response.body).to include("audit-log-#{update_log.id}")
        expect(response.body).not_to include("audit-log-#{delete_log.id}")
      end

      it "paginates results" do
        51.times do |i|
          AuditLog.create!(
            auditable_type: "MemoryEntity", auditable_id: entity.id,
            action: "create", changed_fields: { "index" => i }
          )
        end

        get operator_audit_logs_path(since_days: "all", page: 2)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("audit-log-")
      end
    end
  end

  describe "POST /operator/audit_logs/prune" do
    it "redirects unauthenticated users to login" do
      post operator_prune_audit_logs_path

      expect(response).to redirect_to(operator_login_path)
    end

    context "when signed in" do
      before { sign_in_operator }

      it "deletes only expired logs and preserves filters in redirect" do
        expired = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "create", changed_fields: {},
          created_at: (AuditLog::MAX_AGE_DAYS + 1).days.ago
        )
        recent = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "update", changed_fields: {}
        )

        post operator_prune_audit_logs_path(since_days: "all", log_action: "update")

        expect(response).to redirect_to(operator_audit_logs_path(since_days: "all", log_action: "update"))
        follow_redirect!
        expect(response.body).to include("Pruned 1 audit log")
        expect(AuditLog.find_by(id: expired.id)).to be_nil
        expect(AuditLog.find_by(id: recent.id)).to be_present
      end

      it "shows the prune button only when expired logs exist" do
        get operator_audit_logs_path

        expect(response.body).not_to include('id="btn-audit-logs-prune"')

        AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "create", changed_fields: {},
          created_at: (AuditLog::MAX_AGE_DAYS + 1).days.ago
        )

        get operator_audit_logs_path

        expect(response.body).to include('id="btn-audit-logs-prune"')
      end
    end
  end
end
