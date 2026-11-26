# frozen_string_literal: true

require "rails_helper"

# UI-6 P4 under /projects/imports: the upload form, its errors (422, never a redirect Home), the history
# and the reports. Since 1.94.0 the page takes graph_mem-sql scripts only (their preview, execute and
# report are in sql_imports_spec.rb); a JSON file is refused. Past JSON and rake imports still list and
# open their report.
RSpec.describe "Projects › Imports", type: :request do
  let(:export_json) do
    { version: "1.0", exported_at: "2026-10-29T00:00:00Z",
      root_nodes: [ { name: "Alpha Service", entity_type: "Project", aliases: nil,
                      observations: [ { content: "Alpha Service renders synthetic tiles." } ],
                      children: [ { name: "SynthWidget", entity_type: "Component", observations: [], children: [] } ] } ] }.to_json
  end
  let(:graphify_json) do
    { nodes: [ { id: "synth_widget", label: "SynthWidget", file_type: "code", source_file: "app/models/synth_widget.rb" } ],
      links: [] }.to_json
  end

  def upload(text, name: "export.json", type: "application/json")
    post projects_imports_path, params: { file: Rack::Test::UploadedFile.new(StringIO.new(text), type, original_filename: name) }
  end

  def html = Nokogiri::HTML(response.body)

  def stored_files = ImportSession::TEMP_DIR.glob("*")

  let(:uploaded) { [] }

  after { uploaded.each { |id| ImportSession.cleanup(id) } }

  it "answers 403 to a guest on every import route and writes nothing" do
    enable_guest!
    sign_in_guest

    upload(export_json)
    expect(response).to have_http_status(:forbidden)
    [ projects_imports_path, new_projects_import_path, report_projects_import_path(SecureRandom.uuid) ].each do |path|
      get path
      expect(response).to have_http_status(:forbidden)
    end
    expect([ MemoryEntity.count, OperationProgress.count ]).to eq([ 0, 0 ])
  end

  context "as the operator" do
    before { sign_in_operator }

    it "offers a graph_mem-sql script upload only" do
      get new_projects_import_path

      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='import-file']")["accept"]).to eq(".sql,application/sql")
      expect(html.at_css("[data-testid='import-form']").text).to include("graph_mem-sql script")
      expect(html.css("[data-testid='import-project-name'], input[name='project_name']")).to be_empty
    end

    it "refuses a JSON file, a GraphMem export or a Graphify graph.json, saying JSON imports were retired, and writes nothing" do
      files_before = stored_files
      [ [ export_json, "alpha-export.json" ], [ graphify_json, "graph.json" ], [ "  #{export_json}", "alpha-export.txt" ],
        [ "[]", "nodes" ], [ "\uFEFF#{export_json}", "alpha-export.txt" ], [ "\uFEFF\n[]", "nodes" ] ].each do |text, name|
        expect { upload(text, name: name) }.not_to(change { [ MemoryEntity.count, OperationProgress.count, AuditLog.count ] })

        expect(response).to have_http_status(:unprocessable_content)
        error = html.at_css("[data-testid='import-form-error']").text
        expect(error).to include("JSON imports were retired in 1.94.0", "export the project as an SQL script", "graphify:import")
      end
      expect(stored_files).to eq(files_before)
    end

    it "sends any other file to the validator, which refuses what isn't a graph_mem-sql script" do
      upload("SynthWidget renders tiles.\n", name: "notes.txt", type: "text/plain")

      expect(response).to have_http_status(:unprocessable_content)
      expect(html.at_css("[data-testid='import-form-error']").text).to include("This file was refused before anything ran")
    end

    it "re-renders the upload form (422) for every upload error, never redirecting Home" do
      post projects_imports_path
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Please select a file to import")

      stub_const("ImportFlow::MAX_UPLOAD_BYTES", 10)
      expect { upload("-- graph_mem-sql v1\n-- a long synthetic script\n", name: "synth_prj.sql", type: "application/sql") }
        .not_to(change { stored_files.size })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("File too large")
    end

    it "cancels a script's preview" do
      upload(sql_export(fs_project!("SynthPrj")), name: "synth_prj.sql", type: "application/sql")
      session_id = response.location[%r{/projects/imports/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}, 1].tap { |id| uploaded << id }
      expect(ImportSession.exists?(session_id)).to be(true)

      delete projects_import_path(session_id)

      expect(response).to redirect_to(projects_imports_path)
      expect(ImportSession.exists?(session_id)).to be(false)
    end

    it "answers 404 for an unknown or malformed preview or report id" do
      [ projects_import_path(SecureRandom.uuid), projects_import_path("not-a-uuid"), report_projects_import_path(SecureRandom.uuid) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
      post execute_projects_import_path(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
    end

    it "answers 404 for a review a JSON upload left before 1.94.0" do
      session_id = SecureRandom.uuid
      FileUtils.mkdir_p(ImportSession::TEMP_DIR)
      leftovers = %w[data matches meta].map { |suffix| ImportSession::TEMP_DIR.join("#{session_id}_#{suffix}.json") }
      leftovers.each { |path| File.write(path, "{}") }

      get projects_import_path(session_id)
      expect(response).to have_http_status(:not_found)
      post execute_projects_import_path(session_id), params: { decisions: {} }
      expect(response).to have_http_status(:not_found)
    ensure
      FileUtils.rm_f(leftovers)
    end

    it "lists command-line imports (no details) in the history and opens their report" do
      rake_import = OperationProgress.start!(operation_type: "import", total_count: 3, message: "Graphify import of Alpha Service")
      rake_import.complete!(message: "Graphify import of Alpha Service")

      get projects_imports_path
      expect(response.body).to include("import-row-#{rake_import.operation_id}", "imported from the command line")

      get report_projects_import_path(rake_import.operation_id)
      expect(response.body).to include('data-testid="import-report-command-line"', "Graphify import of Alpha Service")
    end

    it "lists a JSON import made before 1.94.0 with its counts and opens its report" do
      project = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
      json_import = OperationProgress.start!(operation_type: "import", total_count: 0, message: "Starting import")
      json_import.complete!(message: "Import complete")
      json_import.update!(details: { "file_name" => "alpha-export.json", "producer" => "graph_mem", "project_name" => "Alpha Service",
                                     "project_entity_id" => project.id, "success" => true,
                                     "summary" => { "entities_created" => 2, "entities_merged" => 0, "entities_skipped" => 0,
                                                    "observations_created" => 1, "relations_created" => 1, "errors" => 0 },
                                     "error_messages" => [] })

      get projects_imports_path
      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='import-row-#{json_import.operation_id}']").text).to include("alpha-export.json", "2 created, 0 merged")

      get report_projects_import_path(json_import.operation_id)
      expect(response).to have_http_status(:ok)
      expect(html.at_css("[data-testid='import-report-summary']").text).to include("Entities created")
      expect(response.body).to include("alpha-export.json", explore_path(project_id: project.id))
    end
  end
end
