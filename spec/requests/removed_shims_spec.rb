# frozen_string_literal: true

require "rails_helper"

# 1.65.0: the transition redirects and old endpoints are gone. Signed in as the operator,
# every removed path answers 404; the live routes next to them still work. A session holding only
# the legacy operator_signed_in key signs nobody in.
RSpec.describe "Removed transition routes", type: :request do
  removed = [
    [ :get, "/graph" ], [ :get, "/graph?ids=1" ], [ :get, "/maintenance" ],
    [ :get, "/data_exchange/compaction_review" ], [ :get, "/data_exchange/import_review" ],
    [ :get, "/data_exchange/import_report" ], [ :get, "/data_exchange/download_export?export_id=x" ],
    [ :post, "/data_exchange/import_upload" ], [ :post, "/data_exchange/import_execute" ],
    [ :post, "/data_exchange/export_async" ], [ :delete, "/data_exchange/import_cancel" ],
    [ :post, "/project_scans" ], [ :post, "/project_scan_skills" ], [ :patch, "/project_scan_skills/x" ],
    [ :get, "/operator/settings" ], [ :get, "/operator/settings?tab=database_backup" ], [ :get, "/operator/settings?tab=mcp_access" ],
    [ :get, "/operator/settings/project_scans/check_path" ], [ :get, "/operator/embeddings" ], [ :get, "/operator/telemetry" ],
    [ :get, "/operator/audit_logs" ], [ :get, "/projects/jobs" ], [ :get, "/operator/jobs" ], [ :get, "/operator/jobs/queues" ],
    [ :post, "/operator/maintenance/compaction/start" ], [ :post, "/operator/maintenance/compaction/pause" ],
    [ :post, "/operator/maintenance/garbage_collection/run" ], [ :post, "/operator/maintenance/relations/repair" ],
    [ :post, "/operator/audit_logs/prune" ], [ :post, "/operator/telemetry/prune" ],
    [ :post, "/operator/embeddings/test_connection" ], [ :post, "/operator/embeddings/backfill" ],
    [ :post, "/operator/embeddings/regenerate" ], [ :post, "/operator/embeddings/add_indexes" ],
    [ :post, "/operator/embeddings/drop_indexes" ], [ :patch, "/operator/settings" ],
    [ :post, "/operator/settings/backup/run" ], [ :post, "/operator/settings/backup/restore" ],
    [ :delete, "/operator/settings/backup" ], [ :delete, "/operator/settings/project_scans/legacy_roots" ]
  ]

  context "as the operator" do
    before { sign_in_operator }

    removed.each do |verb, path|
      it "answers 404 to #{verb.upcase} #{path}" do
        public_send(verb, path)

        expect(response).to have_http_status(:not_found)
      end
    end

    it "keeps the live routes next to them" do
      get "/operator/login"
      expect(response).to redirect_to(root_path)

      get "/system"
      expect(response).to redirect_to("/system/health")

      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
      get "/data_exchange/entity_search", params: { q: "Synth" }
      expect(response.parsed_body["entities"].map { |entity| entity["name"] }).to eq([ "SynthWidget" ])

      get "/data_exchange/root_nodes"
      expect(response).to have_http_status(:ok)
      get "/projects"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "a session holding only the legacy operator_signed_in key" do
    let(:session_key) { Rails.application.config.session_options[:key] }

    # A session cookie, encrypted with the app's own cookie jar.
    def session_cookie(data)
      request = ActionDispatch::Request.new(Rails.application.env_config.deep_dup)
      request.cookie_jar.encrypted[session_key] = { value: { "session_id" => SecureRandom.hex(16) }.merge(data) }
      cookies[session_key] = request.cookie_jar[session_key]
    end

    it "is not signed in (the same cookie with the role key is)" do
      now = Time.current.to_i
      session_cookie("role" => "operator", "user" => OperatorAuthHelpers::TEST_OPERATOR_USERNAME, "signed_in_at" => now, "last_seen_at" => now)
      get root_path
      expect(response).to have_http_status(:ok)

      session_cookie("operator_signed_in" => true, "signed_in_at" => now, "last_seen_at" => now)
      get root_path
      expect(response).to redirect_to(operator_login_path)

      get "/system/health"
      expect(response).to redirect_to(operator_login_path)
    end
  end
end
