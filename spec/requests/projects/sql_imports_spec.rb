# frozen_string_literal: true

require "rails_helper"

# The SQL import under /projects/imports: upload → validate → dry run → preview → execute → report,
# a file the validator or a guard refuses, a script changed between preview and execute, the
# follow-up on the report and its "Run full maintenance now".
RSpec.describe "Projects › Imports (graph_mem-sql)", type: :request do
  let!(:project) { fs_project!("SynthPrj") }
  let!(:widget) { fs_member!(project, "SynthWidget", "Component", aliases: "Widget One") }
  let(:uploaded) { [] }

  after { uploaded.each { |id| ImportSession.cleanup(id) } }

  def upload(text, name: "synth_prj.sql")
    post projects_imports_path, params: { file: Rack::Test::UploadedFile.new(StringIO.new(text), "application/sql", original_filename: name) }
  end

  def session_id_from_redirect
    response.location[%r{/projects/imports/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}, 1].tap { |id| uploaded << id }
  end

  def html = Nokogiri::HTML(response.body)

  def stored_scripts = Dir.glob(ImportSession::TEMP_DIR.join("*_script.sql"))

  # Uploads and executes the script; returns the import's operation.
  def run_import(script, **params)
    upload(script)
    post execute_projects_import_path(session_id_from_redirect), params: params
    OperationProgress.find_by!(operation_type: "import")
  end

  it "answers 403 to a guest on the full-maintenance route" do
    enable_guest!
    sign_in_guest

    post maintenance_projects_import_path(SecureRandom.uuid), params: { full_maintenance: "1" }

    expect(response).to have_http_status(:forbidden)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "previews a dry run, then executes it with full maintenance and reports it" do
      outside = fs_member!(fs_project!("OtherPrj"), "SynthOutside", "Service")
      MemoryRelation.create!(from_entity: widget, to_entity: outside, relation_type: "depends_on")
      fs_observe!(widget, "SynthWidget renders tiles.")
      script = sql_export(project)
      outside.destroy!
      widget.update_columns(name: "Widget One", aliases: nil)
      MemoryObservation.where(memory_entity_id: widget.id).delete_all

      expect { upload(script) }.not_to(change { [ MemoryObservation.count, OperationProgress.count, AuditLog.count ] })
      session_id = session_id_from_redirect
      get projects_import_path(session_id)

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='sql-import-summary-memory_observations'] td").text).to eq("1")
      expect(html.at_css("[data-testid='sql-import-matches']").text).to include("Widget One: Component, matched by alias: SynthWidget")
      expect(html.at_css("[data-testid='sql-import-skipped-links']").text).to include("depends_on -> (missing) SynthOutside")
      expect(html.at_css("[data-testid='sql-import-backup'] a")["href"]).to eq(system_backups_path)
      get projects_import_path(session_id, rows_table: "memory_observations")
      expect(html.css("[data-testid='sql-import-row']").map(&:text)).to contain_exactly(include("SynthWidget renders tiles."))

      post execute_projects_import_path(session_id), params: { full_maintenance: "1" }

      operation = OperationProgress.find_by!(operation_type: "import")
      expect(response).to redirect_to(report_projects_import_path(operation.operation_id))
      expect(operation.details).to include("format" => "sql", "file_name" => "synth_prj.sql", "producer" => "graph_mem-sql",
                                           "project_name" => "SynthPrj", "project_entity_id" => project.id, "full_maintenance" => true,
                                           "follow_up" => { "status" => "queued" })
      expect(SqlImportFollowUpJob).to have_been_enqueued.with(operation.operation_id)
      expect(widget.memory_observations.pluck(:content)).to eq([ "SynthWidget renders tiles." ])
      expect(ImportSession.exists?(session_id)).to be(false)

      follow_redirect!
      expect(html.at_css("[data-testid='sql-import-follow-up-status']").text).to eq("queued")
      expect(html.at_css("[data-testid='sql-import-full-maintenance']").text).to include("starts when the follow-up ends")
      expect(html.at_css("[data-testid='sql-import-skipped-links']").text).to include("SynthOutside")
      get projects_imports_path
      expect(html.at_css("[data-testid='import-row-#{operation.operation_id}']").text).to include("synth_prj.sql", "1 new, 1 updated, 0 kept local")
    end

    it "refuses a file the validator rejects, with its reason, writing and keeping nothing" do
      edited = sql_export(project).sub("'SynthWidget'", "'SynthWidgeT'")

      expect { upload(edited) }.not_to(change { [ MemoryEntity.count, OperationProgress.count, stored_scripts.size ] })
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='import-form-error']").text).to include("refused before anything ran", "does not match its sha256")

      upload("-- a dump from another tool\nDROP TABLE memory_entities;\n", name: "dump.sql")
      expect(html.at_css("[data-testid='import-form-error']").text).to include("not a graph_mem-sql script")
      expect(MemoryEntity.count).to eq(2)
    end

    it "shows a guard's refusal of the dry run, writing and keeping nothing" do
      script = sql_export(project)
      sql_delete_tree!(project)
      MemoryEntity.create!(name: "SynthPrj", entity_type: "Component")

      expect { upload(script) }.not_to(change { [ MemoryEntity.count, OperationProgress.count, stored_scripts.size ] })
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='import-form-error']").text).to include("refused and nothing was written", "is a Project on one side")
    end

    it "validates the stored script again on execute: a changed one doesn't run and the preview says why" do
      script = sql_export(project)
      sql_delete_tree!(project)
      upload(script)
      session_id = session_id_from_redirect
      File.write(ImportSession.sql_path(session_id), script.sub("'SynthWidget'", "'SynthWidgeT'"))

      expect { post execute_projects_import_path(session_id) }.not_to(change { [ MemoryEntity.count, OperationProgress.count ] })
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='sql-import-error']").text).to include("did not run", "does not match its sha256")
      expect(ImportSession.exists?(session_id)).to be(true)
      expect(enqueued_jobs).to be_empty
    end

    it "starts full maintenance from the report: when the follow-up ends, or at once once it ended" do
      operation = run_import(sql_export(project))
      expect(operation.details["full_maintenance"]).to be(false)

      post maintenance_projects_import_path(operation.operation_id)
      expect(operation.reload.details["full_maintenance"]).to be(false)
      post maintenance_projects_import_path(operation.operation_id), params: { full_maintenance: "1" }
      expect(flash[:notice]).to eq("Full maintenance will start when the follow-up ends.")
      expect(OperationProgress.where(operation_type: "scheduled_run")).to be_empty

      SqlImportFollowUpJob.perform_now(operation.operation_id)
      expect(OperationProgress.where(operation_type: "scheduled_run").sole.details["trigger"]).to eq("sql_import")
      get report_projects_import_path(operation.operation_id)
      expect(html.at_css("[data-testid='sql-import-full-maintenance']").text).to include("Full maintenance started")

      ScheduledRunJob.current.update!(status: "completed")
      second = sql_import(sql_export(project)).operation_id
      post maintenance_projects_import_path(second), params: { full_maintenance: "1" }
      expect(flash[:notice]).to eq("Full maintenance started (System › Background jobs).")
    end

    it "shows the follow-up's outcome, saying when the near-duplicate check couldn't run", :with_test_embeddings do
      fs_observe!(widget, "Restated: SynthWidget renders tiles.")
      script = sql_export(project)
      MemoryObservation.where(memory_entity_id: widget.id).delete_all
      fs_observe!(widget, "SynthWidget renders tiles.")
      operation = run_import(script)

      SqlImportFollowUpJob.perform_now(operation.operation_id)
      get report_projects_import_path(operation.operation_id)

      expect(html.at_css("[data-testid='sql-import-follow-up-status']").text).to eq("done")
      expect(html.at_css("[data-testid='sql-import-follow-up']").text).to include("the embedding service did not answer")
      expect(html.at_css("[data-testid='sql-import-near-duplicates-unchecked']").text)
        .to include("could not run for 1 new observations (the embedding service is down)")
    end

    it "refuses the full-maintenance route without a CSRF token" do
      operation = run_import(sql_export(project))
      ActionController::Base.allow_forgery_protection = true

      post maintenance_projects_import_path(operation.operation_id), params: { full_maintenance: "1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(operation.reload.details["full_maintenance"]).to be(false)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end
  end
end
