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

    it "lists an outdated_by link the merge dropped, as a note and as a row, on the preview and the report" do
      gear = fs_member!(project, "SynthGear", "Component")
      source_fact = fs_fact!(gear, "SynthGear replaces the old renderer.")
      fs_observe!(widget, "SynthWidget used the old renderer.").mark_obsolete!(reason: "synthetic retire", outdated_by: source_fact)
      source_fact.update!(tags: []) # after it outdated the observation
      script = sql_export(project)
      sql_delete_tree!(project)

      upload(script)
      session_id = session_id_from_redirect
      get projects_import_path(session_id, rows_action: "dropped_link")

      note = "SynthWidget: outdated_by -> #"
      reason = "the observation it names is not a source fact of the same project"
      expect(html.at_css("[data-testid='sql-import-dropped-links']").text).to include(note, "SynthGear replaces the old renderer.", reason)
      expect(html.css("[data-testid='sql-import-row']").map(&:text)).to contain_exactly(include("link dropped", "SynthWidget", reason))
      expect(html.at_css("select#rows_action option[selected]").text).to eq("link dropped")

      post execute_projects_import_path(session_id)
      follow_redirect!

      expect(html.at_css("[data-testid='sql-import-dropped-links']").text).to include(note, reason)
      expect(html.css("[data-testid='sql-import-row']").map(&:text)).to include(include("link dropped", reason))
      expect(MemoryObservation.find_by!(content: "SynthWidget used the old renderer.")).to have_attributes(status: "obsolete", outdated_by_id: nil)
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

    it "refuses a value MariaDB rejects after the grammar passed it, with the database's message, writing and keeping nothing" do
      script = sql_export(project)
      sql_delete_tree!(project)
      rejected = resign(script.sub("'part_of', NULL,", "'part_of', 1e999,"))
      expect(SqlImport::Validator.validate(rejected)).to be_a(SqlImport::Validator::Script)

      expect { upload(rejected) }.not_to(change { [ MemoryEntity.count, OperationProgress.count, AuditLog.count, stored_scripts.size ] })
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='import-form-error']").text).to include("refused and nothing was written", "Illegal double '1e999' value")
    end

    it "validates the stored script again on execute: a changed one doesn't run and the preview says why" do
      script = sql_export(project)
      sql_delete_tree!(project)
      upload(script)
      session_id = session_id_from_redirect
      File.write(ImportSession.sql_path(session_id), script.sub("'SynthWidget'", "'SynthWidgeT'"))

      expect { post execute_projects_import_path(session_id) }.not_to(change { [ MemoryEntity.count, OperationProgress.count ] })
      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='sql-import-error']").text).to include("did not run and nothing was written", "does not match its sha256")
      expect(ImportSession.exists?(session_id)).to be(true)
      expect(enqueued_jobs).to be_empty
    end

    # Uploads the script with the project deleted, so Execute writes its two entities; returns the session id.
    def upload_fresh_import
      script = sql_export(project)
      sql_delete_tree!(project)
      upload(script)
      session_id_from_redirect
    end

    it "reports a follow-up that couldn't be queued as failed on a written import, which a second Execute doesn't run again" do
      allow(SqlImportFollowUpJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid, "queue down")
      session_id = upload_fresh_import

      post execute_projects_import_path(session_id), params: { full_maintenance: "1" }

      operation = OperationProgress.find_by!(operation_type: "import")
      expect(response).to redirect_to(report_projects_import_path(operation.operation_id))
      expect(operation.details).to include("full_maintenance" => true, "follow_up" => { "status" => "failed", "error" => "ActiveRecord::StatementInvalid: queue down" })
      expect(MemoryEntity.where(name: %w[SynthPrj SynthWidget]).count).to eq(2)
      expect(ImportSession.exists?(session_id)).to be(false)

      follow_redirect!
      expect(html.at_css("[data-testid='sql-import-follow-up-status']").text).to eq("failed")
      expect(html.at_css("[data-testid='sql-import-follow-up']").text).to include("The follow-up failed: ActiveRecord::StatementInvalid: queue down")
      expect(html.at_css("[data-testid='sql-import-follow-up-recover']").text)
        .to include("The imported rows are written", "Run full maintenance now runs those jobs at once", "SqlImportFollowUpJob.perform_later(\"#{operation.operation_id}\")")
      expect(html.at_css("[data-testid='sql-import-full-maintenance']")).to be_nil # asked for, but a failed follow-up never starts it
      expect(html.at_css("[data-testid='sql-import-maintenance-form']")).to be_present

      expect { post execute_projects_import_path(session_id) }.not_to(change { [ OperationProgress.count, MemoryEntity.count, AuditLog.count ] })
      expect(response).to have_http_status(:not_found)
    end

    it "says the import was written when completing its record fails after the commit, never that nothing was written" do
      allow(SqlImport::Flow).to receive(:finish).and_raise(ActiveRecord::StatementInvalid, "details lost")
      session_id = upload_fresh_import

      post execute_projects_import_path(session_id)

      operation = OperationProgress.find_by!(operation_type: "import")
      expect(response).to redirect_to(report_projects_import_path(operation.operation_id))
      expect(flash[:alert]).to include("The import was written (operation #{operation.operation_id})",
                                       "its follow-up was not queued: ActiveRecord::StatementInvalid: details lost", "Run full maintenance now")
      expect(flash[:alert]).not_to include("nothing was written")
      expect(MemoryEntity.where(name: %w[SynthPrj SynthWidget]).count).to eq(2)
      expect(ImportSession.exists?(session_id)).to be(false)

      expect { post execute_projects_import_path(session_id) }.not_to(change { [ OperationProgress.count, MemoryEntity.count ] })
      expect(response).to have_http_status(:not_found)
    end

    it "says the import was written when leaving the run fails after the commit, and doesn't keep the upload" do
      session_id = upload_fresh_import
      fail_sql_import_after_commit!("lock release lost")

      post execute_projects_import_path(session_id)

      operation = OperationProgress.find_by!(operation_type: "import")
      expect(response).to redirect_to(report_projects_import_path(operation.operation_id))
      expect(flash[:alert]).to include("The import was written (operation #{operation.operation_id})", "ActiveRecord::StatementInvalid: lock release lost")
      expect(MemoryEntity.where(name: %w[SynthPrj SynthWidget]).count).to eq(2)
      expect(ImportSession.exists?(session_id)).to be(false)
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

    it "starts full maintenance at once after a follow-up that couldn't be queued, though Execute asked for it" do
      allow(SqlImportFollowUpJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid, "queue down")
      operation = run_import(sql_export(project), full_maintenance: "1")
      expect(operation.details.dig("follow_up", "status")).to eq("failed")

      post maintenance_projects_import_path(operation.operation_id), params: { full_maintenance: "1" }

      expect(flash[:notice]).to eq("Full maintenance started (System › Background jobs).")
      expect(OperationProgress.where(operation_type: "scheduled_run").sole.details["trigger"]).to eq("sql_import")
      expect(operation.reload.details["full_maintenance_outcome"]).to eq("started")
    end

    # A new fact next to a reworded one the target had; returns the follow-up's report page.
    def report_with_reworded_fact
      fs_observe!(widget, "Restated: SynthWidget renders tiles.")
      script = sql_export(project)
      MemoryObservation.where(memory_entity_id: widget.id).delete_all
      fs_observe!(widget, "SynthWidget renders tiles.")
      operation = run_import(script)
      SqlImportFollowUpJob.perform_now(operation.operation_id)
      get report_projects_import_path(operation.operation_id)
      html.at_css("[data-testid='sql-import-near-duplicates-unchecked']")
    end

    it "warns when the near-duplicate check couldn't run because the embedding service is down", :with_test_embeddings do
      unchecked = report_with_reworded_fact

      expect(html.at_css("[data-testid='sql-import-follow-up-status']").text).to eq("done")
      expect(html.at_css("[data-testid='sql-import-follow-up']").text).to include("the embedding service did not answer")
      expect(unchecked.text).to include("could not run for 1 new observations (the embedding service is down)")
      expect(unchecked["class"]).to eq("projects-error")
    end

    it "only hints that the near-duplicate check needs vector columns on an install without them" do
      unchecked = report_with_reworded_fact

      expect(unchecked.text).to include("needs vector columns, which this install doesn't have", "1 new observations")
      expect(unchecked["class"]).to eq("projects-hint")
      expect(unchecked["role"]).to be_nil
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
