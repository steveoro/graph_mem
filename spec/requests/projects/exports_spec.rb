# frozen_string_literal: true

require "rails_helper"

# UI-6 P5: exports run in ExportJob with a progress page; the download is a 410 once the file
# is gone.
RSpec.describe "Projects › Exports", type: :request do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  def completed_export(file: true)
    OperationProgress.create!(operation_type: "export", operation_id: SecureRandom.uuid, status: "completed", percentage: 100,
                              details: { "entity_ids" => [ alpha.id ], "root_names" => [ "Alpha Service" ] }).tap do |export|
      if file
        FileUtils.mkdir_p(ExportJob::TEMP_DIR)
        File.write(ExportJob.download_path(export.operation_id), { root_nodes: [ { name: "Alpha Service" } ] }.to_json)
        written << export.operation_id
      end
    end
  end

  let(:written) { [] }

  after { written.each { |id| FileUtils.rm_f(ExportJob.download_path(id)) } }

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

    it "queues ExportJob under a pending operation and opens its progress page" do
      expect { post projects_exports_path, params: { ids: [ alpha.id.to_s, "bogus", widget.id ] } }
        .to have_enqueued_job(ExportJob).with(anything, [ alpha.id, widget.id ])

      export = OperationProgress.sole
      expect(export).to have_attributes(operation_type: "export", status: "pending")
      expect(export.details).to eq("entity_ids" => [ alpha.id, widget.id ], "root_names" => [ "Alpha Service", "SynthWidget" ])
      expect(response).to redirect_to(projects_export_path(export.operation_id))

      follow_redirect!
      expect(response.body).to include('data-controller="operation-progress"', "Alpha Service, SynthWidget")
    end

    it "re-renders the picker (422) when nothing is picked" do
      expect { post projects_exports_path, params: { ids: [ "0" ] } }.not_to have_enqueued_job

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Pick at least one root")
    end

    it "downloads a finished export and answers 410 once the file has expired" do
      export = completed_export

      get projects_export_path(export.operation_id)
      expect(response.body).to include('data-testid="export-download"')
      get download_projects_export_path(export.operation_id)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("attachment", "graph_mem_export_")
      expect(JSON.parse(response.body)["root_nodes"].first["name"]).to eq("Alpha Service")

      FileUtils.rm_f(ExportJob.download_path(export.operation_id))
      get download_projects_export_path(export.operation_id)
      expect(response).to have_http_status(:gone)
      expect(response.body).to include("This export has expired")
      get projects_export_path(export.operation_id)
      expect(response.body).to include('data-testid="export-expired"')
    end

    it "answers 404 for an unknown export, and never reads a path from params" do
      get download_projects_export_path(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
      get download_projects_export_path("not-a-uuid")
      expect(response).to have_http_status(:not_found)
    end

    it "lists past exports newest first" do
      export = completed_export(file: false)

      get projects_exports_path

      expect(response.body).to include("export-row-#{export.operation_id}", "Alpha Service")
    end
  end
end
