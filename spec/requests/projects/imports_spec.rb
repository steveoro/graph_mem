# frozen_string_literal: true

require "rails_helper"

# UI-6 P4: upload → review → execute → report under /projects/imports, a Graphify graph.json
# through the same review, upload errors re-rendering the form (422), and the history.
RSpec.describe "Projects › Imports", type: :request do
  let(:export_json) do
    { version: "1.0", exported_at: "2026-10-29T00:00:00Z",
      root_nodes: [ { name: "Alpha Service", entity_type: "Project", aliases: nil,
                      observations: [ { content: "Alpha Service renders synthetic tiles." } ],
                      children: [ { name: "SynthWidget", entity_type: "Component", observations: [], children: [] } ] } ] }.to_json
  end
  let(:graphify_json) do
    { nodes: [ { id: "synth_widget", label: "SynthWidget", file_type: "code", source_file: "app/models/synth_widget.rb" },
               { id: "synth_gear", label: "SynthGear", file_type: "code", source_file: "app/models/synth_gear.rb" } ],
      links: [ { source: "synth_widget", target: "synth_gear", relation: "calls", confidence: "EXTRACTED" } ] }.to_json
  end

  def upload(json, name: "export.json", **params)
    post projects_imports_path, params: { file: Rack::Test::UploadedFile.new(StringIO.new(json), "application/json", original_filename: name), **params }
  end

  # The review's ImportSession id; its temp files are removed after each example.
  def session_id_from_redirect
    response.location[%r{/projects/imports/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z}, 1].tap { |id| uploaded << id }
  end

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

    it "uploads, reviews, executes and reports a GraphMem export, recording it in the history" do
      upload(export_json, name: "alpha-export.json")
      session_id = session_id_from_redirect
      expect(session_id).to be_present

      get projects_import_path(session_id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alpha-export.json", "Alpha Service", "SynthWidget", 'data-controller="import-decision"')

      post execute_projects_import_path(session_id), params: { decisions: { "0" => { node_path: "0", action: "create" } } }

      operation = OperationProgress.find_by!(operation_type: "import")
      expect(response).to redirect_to(report_projects_import_path(operation.operation_id))
      expect(MemoryEntity.where(name: [ "Alpha Service", "SynthWidget" ]).count).to eq(2)
      expect(operation.details).to include("file_name" => "alpha-export.json", "producer" => "graph_mem", "project_name" => "Alpha Service",
                                           "success" => true, "project_entity_id" => MemoryEntity.find_by!(name: "Alpha Service").id)
      expect(operation.details["summary"]).to include("entities_created" => 2, "errors" => 0)
      expect(ImportSession.exists?(session_id)).to be(false)

      follow_redirect!
      expect(response.body).to include("alpha-export.json", "Entities created")
      get projects_imports_path
      expect(response.body).to include("import-row-#{operation.operation_id}", "2 created, 0 merged")
    end

    it "translates a Graphify graph.json and sends it through the same review" do
      upload(graphify_json, name: "graph.json")
      expect(response).to have_http_status(:unprocessable_content)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-testid='import-form-error']").text).to include("Name the project")
      expect(page.at_css("[data-testid='import-project-name']")["value"]).to eq("graph")

      upload(graphify_json, name: "graph.json", project_name: "Gadget Project")
      session_id = session_id_from_redirect
      expect(ImportSession.load_meta(session_id)).to include(producer: "graphify", project_name: "Gadget Project")
      get projects_import_path(session_id)
      expect(response.body).to include("Gadget Project", "SynthWidget", "graphify")
    end

    it "re-renders the upload form (422) for every upload error, never redirecting Home" do
      post projects_imports_path
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Please select a file to import")

      upload("not valid json {")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Invalid JSON file")

      upload({ nodes: "x", links: [] }.to_json)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Invalid import format")

      stub_const("ImportFlow::MAX_UPLOAD_BYTES", 10)
      expect { upload(export_json) }.not_to(change { ImportSession::TEMP_DIR.glob("*.json").size })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("File too large")
    end

    it "says when the review's parent choice is capped" do
      stub_const("ExportStrategy::ROOT_NODES_LIMIT", 1)
      MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
      upload(export_json)

      get projects_import_path(session_id_from_redirect)

      expect(response.body).to include('data-testid="import-parents-capped"', "Only the first 1 roots")
    end

    it "cancels a review" do
      upload(export_json)
      session_id = session_id_from_redirect

      delete projects_import_path(session_id)

      expect(response).to redirect_to(projects_imports_path)
      expect(ImportSession.exists?(session_id)).to be(false)
    end

    it "answers 404 for an unknown or malformed review or report id" do
      [ projects_import_path(SecureRandom.uuid), projects_import_path("not-a-uuid"), report_projects_import_path(SecureRandom.uuid) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
    end

    it "lists command-line imports (no details) in the history and opens their report" do
      rake_import = OperationProgress.start!(operation_type: "import", total_count: 3, message: "Graphify import of Alpha Service")
      rake_import.complete!(message: "Graphify import of Alpha Service")

      get projects_imports_path
      expect(response.body).to include("import-row-#{rake_import.operation_id}", "imported from the command line")

      get report_projects_import_path(rake_import.operation_id)
      expect(response.body).to include('data-testid="import-report-command-line"', "Graphify import of Alpha Service")
    end
  end
end
