# frozen_string_literal: true

require "rails_helper"

# UI-6 security checklist: every Projects & Data write keeps the CSRF check. Test env disables
# forgery protection globally; it's turned on after sign-in, so a 422 can only come from it.
RSpec.describe "Projects & Data CSRF protection", type: :request do
  let(:operation_id) { SecureRandom.uuid }

  before do
    sign_in_operator
    ActionController::Base.allow_forgery_protection = true
  end

  after { ActionController::Base.allow_forgery_protection = false }

  {
    "POST /projects/scans" => [ :post, -> { projects_scans_path }, { project_root: "/scan/alpha" } ],
    "PATCH /projects/scan_skills/:id" => [ :patch, -> { projects_scan_skill_path(operation_id) }, { skill_action: "continue" } ],
    "POST /projects/imports" => [ :post, -> { projects_imports_path }, {} ],
    "POST /projects/imports/:id/execute" => [ :post, -> { execute_projects_import_path(operation_id) }, {} ],
    "DELETE /projects/imports/:id" => [ :delete, -> { projects_import_path(operation_id) }, {} ],
    "POST /projects/exports" => [ :post, -> { projects_exports_path }, { ids: [ 1 ] } ]
  }.each do |label, (verb, path, params)|
    it "refuses #{label} without a CSRF token (422) and writes nothing" do
      expect { send(verb, instance_exec(&path), params: params) }.not_to(change { [ OperationProgress.count, enqueued_jobs.size ] })

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
