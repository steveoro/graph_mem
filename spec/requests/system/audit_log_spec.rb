# frozen_string_literal: true

require "rails_helper"

RSpec.describe "System › Audit log", type: :request do
  let!(:entity) { MemoryEntity.create!(name: "AuditBrowseEntity", entity_type: "Project") }

  describe "GET /system/audit_log" do
    it "redirects unauthenticated users to login" do
      get system_audit_log_path

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

        get system_audit_log_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Audit Logs")
        expect(response.body).to include("mcp:update_entity")
        expect(response.body).to include("audit-log-#{recent.id}")
        expect(response.body).not_to include("audit-log-#{old.id}")
        expect(response.body).to include('id="audit_filter_since_days"')
      end

      it "shows the actor, the claim on a second line and the reason, and filters on the actor only" do
        log = AuditLog.create!(auditable_type: "MemoryObservation", auditable_id: 1, action: "create", changed_fields: {},
                               actor: "mcp:graph_write", actor_claim: "client=synth-client-a · synth-agent/model-x", reason: "synthetic task")
        AuditLog.create!(auditable_type: "MemoryEntity", auditable_id: entity.id, action: "update", changed_fields: {}, actor: "operator:synth@127.0.0.1")

        get system_audit_log_path

        row = Nokogiri::HTML(response.body).at_css("#audit-log-#{log.id}")
        expect(row.text).to include("mcp:graph_write", "synthetic task")
        expect(row.at_css("[data-testid='audit-log-claim']").text).to eq("claimed: client=synth-client-a · synth-agent/model-x")

        get system_audit_log_path(actor: "mcp:graph_write")
        expect(response.body).to include("audit-log-#{log.id}")
        expect(response.body).not_to include("operator:synth@127.0.0.1")
        get system_audit_log_path(actor: "synth-agent/model-x")
        expect(response.body).not_to include("audit-log-#{log.id}")
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

        get system_audit_log_path(since_days: "all", log_action: "update")

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

        get system_audit_log_path(since_days: "all", page: 2)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("audit-log-")
      end
    end
  end

  describe "POST /system/audit_log/prune" do
    it "redirects unauthenticated users to login" do
      post system_prune_audit_log_path

      expect(response).to redirect_to(operator_login_path)
    end

    context "when signed in" do
      before { sign_in_operator }

      it "deletes only expired logs once their count is typed, and preserves filters in redirect" do
        expired = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "create", changed_fields: {},
          created_at: (AuditLog::MAX_AGE_DAYS + 1).days.ago
        )
        recent = AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "update", changed_fields: {}
        )

        post system_prune_audit_log_path(since_days: "all", log_action: "update"), params: { confirmation: "2" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('data-testid="typed-confirm-error-prune-audit-log"')
        expect(AuditLog.find_by(id: expired.id)).to be_present

        post system_prune_audit_log_path(since_days: "all", log_action: "update"), params: { confirmation: "1" }

        expect(response).to redirect_to(system_audit_log_path(since_days: "all", log_action: "update"))
        follow_redirect!
        expect(response.body).to include("Pruned 1 audit log")
        expect(AuditLog.find_by(id: expired.id)).to be_nil
        expect(AuditLog.find_by(id: recent.id)).to be_present
      end

      it "shows the prune button only when expired logs exist" do
        get system_audit_log_path

        expect(response.body).not_to include('data-testid="typed-confirm-prune-audit-log"')

        AuditLog.create!(
          auditable_type: "MemoryEntity", auditable_id: entity.id,
          action: "create", changed_fields: {},
          created_at: (AuditLog::MAX_AGE_DAYS + 1).days.ago
        )

        get system_audit_log_path

        expect(response.body).to include('data-testid="typed-confirm-prune-audit-log"', 'data-typed-confirm-expected-value="1"')
      end
    end
  end
end
