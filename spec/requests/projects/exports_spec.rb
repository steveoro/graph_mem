# frozen_string_literal: true

require "rails_helper"

# UI-6 P5: exports run in ExportJob with a progress page; the download is a 410 once the file
# is gone. Since 1.94.0 an export is a graph_mem-sql script; a JSON export row from before then (its
# details say json, or name no format) shows as retired and its download answers 410.
RSpec.describe "Projects › Exports", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  # A finished export. `format: "json"` is a row of the retired JSON export, `format: nil` one from before
  # the format choice existed (no "format" key, a JSON export too); `file:` writes the file such a row had.
  def completed_export(file: true, format: "sql", roots: [ alpha ])
    details = { "entity_ids" => roots.map(&:id), "root_names" => roots.map(&:name) }
    details["format"] = format if format
    OperationProgress.create!(operation_type: "export", operation_id: SecureRandom.uuid, status: "completed", percentage: 100,
                              details: details).tap do |export|
      if file
        FileUtils.mkdir_p(ExportJob::TEMP_DIR)
        path = format == "sql" ? ExportJob.download_path(export.operation_id) : File.join(ExportJob::TEMP_DIR, "export_#{export.operation_id}.json")
        File.write(path, format == "sql" ? "-- graph_mem-sql v1\n" : { root_nodes: [ { name: "Alpha Service" } ] }.to_json)
        written << path
      end
    end
  end

  let(:written) { [] }

  def html = Nokogiri::HTML(response.body)

  after { FileUtils.rm_f(written) }

  it "answers 403 to a guest and starts nothing" do
    enable_guest!
    sign_in_guest
    export = completed_export

    expect { post projects_exports_path, params: { ids: [ alpha.id ] } }.not_to have_enqueued_job
    expect(response).to have_http_status(:forbidden)
    [ projects_exports_path, projects_export_path(export.operation_id), download_projects_export_path(export.operation_id) ].each do |path|
      get path
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "as the operator" do
    before { sign_in_operator }

    it "lists Project roots first, filtered by name" do
      get projects_exports_path
      roots = Nokogiri::HTML(response.body).css("[data-testid^='export-root-']").map { |label| label["data-testid"] }
      expect(roots).to eq([ "export-root-#{alpha.id}", "export-root-#{widget.id}" ])

      get projects_exports_path(q: "widget")
      expect(response.body).to include("export-root-#{widget.id}")
      expect(response.body).not_to include("export-root-#{alpha.id}")
    end

    it "says the list is capped only when a root was cut" do
      stub_const("SqlExport::Roots::LIMIT", 3)
      root_ids = -> { Nokogiri::HTML(response.body).css("[data-testid^='export-root-']").size }
      MemoryEntity.delete_all

      get projects_exports_path
      expect(response.body).not_to include('data-testid="export-roots-capped"')

      [ "Alpha Service", "Gadget Project", "SynthWidget" ].each { |name| MemoryEntity.create!(name: name, entity_type: "Project") }
      get projects_exports_path
      expect(root_ids.call).to eq(3)
      expect(response.body).not_to include('data-testid="export-roots-capped"')

      MemoryEntity.create!(name: "SynthWidget Two", entity_type: "Component")
      get projects_exports_path
      expect(root_ids.call).to eq(3)
      expect(response.body).to include('data-testid="export-roots-capped"', "Only the first 3 roots")
    end

    it "queues ExportJob under a pending operation and opens its progress page" do
      expect { post projects_exports_path, params: { ids: [ alpha.id.to_s, "bogus", widget.id ] } }
        .to have_enqueued_job(ExportJob).with(anything, [ alpha.id, widget.id ])

      export = OperationProgress.sole
      expect(export).to have_attributes(operation_type: "export", status: "pending")
      expect(export.details).to eq("entity_ids" => [ alpha.id, widget.id ], "root_names" => [ "Alpha Service", "SynthWidget" ], "format" => "sql")
      expect(response).to redirect_to(projects_export_path(export.operation_id))

      follow_redirect!
      expect(response.body).to include('data-controller="operation-progress"', "Alpha Service, SynthWidget")
      expect(html.at_css("[data-testid='export-format-name']").text).to eq("Format: SQL script")
    end

    it "offers the SQL script only: no format choice, a hint saying what the export writes" do
      get projects_exports_path

      form = html.at_css("[data-testid='export-form']")
      expect(form.css("input[type=radio], [data-testid='export-format']")).to be_empty
      expect(form.at_css("[data-testid='export-format-hint']").text).to include("graph_mem-sql script")
      expect(form.text).not_to include("JSON")
    end

    it "queues a script whatever export_format a stale form sends" do
      expect { post projects_exports_path, params: { ids: [ alpha.id ], export_format: "json" } }.to have_enqueued_job(ExportJob).with(anything, [ alpha.id ])

      expect(OperationProgress.sole.details).to include("format" => "sql")
    end

    it "re-renders the picker (422) when nothing is picked" do
      expect { post projects_exports_path, params: { ids: [ "0" ] } }.not_to have_enqueued_job

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Pick at least one root")
    end

    it "downloads a script as application/sql, an attachment named after its root, and answers 410 once the file has expired" do
      export = completed_export

      get projects_export_path(export.operation_id)
      expect(response.body).to include('data-testid="export-download"')
      expect(html.at_css("[data-testid='export-format-name']").text).to eq("Format: SQL script")
      get download_projects_export_path(export.operation_id)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/sql")
      expect(response.headers["Content-Disposition"]).to eq('attachment; filename="alpha_service.sql"; filename*=UTF-8\'\'alpha_service.sql')
      expect(response.body).to eq("-- graph_mem-sql v1\n")

      FileUtils.rm_f(ExportJob.download_path(export.operation_id))
      get download_projects_export_path(export.operation_id)
      expect(response).to have_http_status(:gone)
      expect(response.body).to include("This export has expired")
      get projects_export_path(export.operation_id)
      expect(response.body).to include('data-testid="export-expired"')
    end

    it "shows an old JSON export as retired, with no download, and answers 410 to its download even with its file still there" do
      [ completed_export(format: "json"), completed_export(format: nil) ].each do |export|
        get projects_export_path(export.operation_id)
        expect(response).to have_http_status(:ok)
        expect(html.at_css("[data-testid='export-format-name']").text).to eq("Format: JSON (retired)")
        expect(html.at_css("[data-testid='export-retired']").text).to include("retired in 1.94.0")
        expect(response.body).not_to include('data-testid="export-download"')

        get download_projects_export_path(export.operation_id)
        expect(response).to have_http_status(:gone)
        expect(html.at_css("[data-testid='export-retired-page']").text).to include("The JSON export was retired in 1.94.0")
        expect(response.body).not_to include("root_nodes")
      end
    end

    it "names a script of several roots after the first and the rest, and one with no usable root name by its time" do
      several = completed_export(format: "sql", roots: [ alpha, widget, MemoryEntity.create!(name: "SynthThird", entity_type: "Project") ])
      get download_projects_export_path(several.operation_id)
      expect(response.headers["Content-Disposition"]).to include('filename="alpha_service_plus_2.sql"')

      unnamed = completed_export(format: "sql")
      unnamed.update!(details: unnamed.details.merge("root_names" => [ "???" ]))
      get download_projects_export_path(unnamed.operation_id)
      expect(response.headers["Content-Disposition"]).to match(/filename="graph_mem_export_\d{8}_\d{6}\.sql"/)
    end

    it "answers 410 for a script whose file is gone, even when a JSON file with the same id exists" do
      export = completed_export
      FileUtils.rm_f(ExportJob.download_path(export.operation_id))
      File.write(File.join(ExportJob::TEMP_DIR, "export_#{export.operation_id}.json"), "{}")
      written << File.join(ExportJob::TEMP_DIR, "export_#{export.operation_id}.json")

      get download_projects_export_path(export.operation_id)

      expect(response).to have_http_status(:gone)
    end

    it "answers 404 for an unknown export, and never reads a path from params" do
      get download_projects_export_path(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
      get download_projects_export_path("not-a-uuid")
      expect(response).to have_http_status(:not_found)
    end

    it "lists past exports newest first, each with its format (an old JSON one, or one without a format, as retired)" do
      json = completed_export(file: false, format: "json")
      old = completed_export(file: false, format: nil)
      sql = completed_export(file: false)

      get projects_exports_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("export-row-#{old.operation_id}", "Alpha Service")
      expect(html.css("[data-testid^='export-row-']").map { |row| row["data-testid"] })
        .to eq([ sql, old, json ].map { |export| "export-row-#{export.operation_id}" })
      [ json, old ].each { |export| expect(html.at_css("[data-testid='export-row-#{export.operation_id}']").text).to include("JSON (retired)") }
      expect(html.at_css("[data-testid='export-row-#{sql.operation_id}']").text).to include("SQL script")
    end

    # The file the job writes goes into the import flow as is: first-line detection, validation, dry run.
    it "exports a project as a script and imports that file on Projects › Imports, dry run counts as expected" do
      project = fs_project!("SynthPrj")
      member = fs_member!(project, "SynthGear", "Component")
      fs_observe!(member, "SynthGear renders tiles.")
      fs_observe!(project, "SynthPrj keeps its widgets in one folder.")
      expected = { "memory_entities" => 2, "memory_observations" => 2, "memory_relations" => 1 }

      post projects_exports_path, params: { ids: [ project.id ] }
      export = OperationProgress.find_by!(operation_type: "export")
      ExportJob.new.perform(export.operation_id, [ project.id ])
      written << ExportJob.download_path(export.operation_id)
      get download_projects_export_path(export.operation_id)
      script = response.body
      filename = response.headers["Content-Disposition"][/filename="([^"]+)"/, 1]
      expect(filename).to eq("synthprj.sql")
      sql_delete_tree!(project)

      imported = nil
      expect do
        post projects_imports_path, params: { file: Rack::Test::UploadedFile.new(StringIO.new(script), "application/sql", original_filename: filename) }
        imported = response.location[%r{/projects/imports/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}, 1]
      end.not_to(change { [ MemoryEntity.count, MemoryObservation.count, MemoryRelation.count ] })
      expect(response).to have_http_status(:found)
      get projects_import_path(imported)

      expect(response).to have_http_status(:ok)
      rows = expected.keys.to_h { |table| [ table, html.at_css("[data-testid='sql-import-summary-#{table}'] td")&.text&.to_i ] }
      expect(rows).to eq(expected)
      post execute_projects_import_path(imported)
      expect(MemoryEntity.where(name: %w[SynthPrj SynthGear]).count).to eq(2)
      expect(MemoryObservation.pluck(:content)).to contain_exactly("SynthGear renders tiles.", "SynthPrj keeps its widgets in one folder.")
    ensure
      ImportSession.cleanup(imported) if imported
    end
  end
end
