# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scan Projects API", type: :request do
  describe "POST /api/v1/scan" do
    it "enqueues a scan of the resolved realpath and returns a scan id" do
      with_scan_project do |project|
        expect {
          post "/api/v1/scan", params: { project_root: project, project_name: "APITestProject", mode: "initial" }
        }.to have_enqueued_job(ProjectScanJob).with(anything, project, any_args)

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json).to include("status" => "queued", "project_root" => project, "warnings" => [])
        expect(json["scan_id"]).to be_present

        get "/api/v1/scan/#{json['scan_id']}"
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to include("status" => "pending", "phase" => "queued")
      end
    end

    it "returns 422 for missing project_root" do
      post "/api/v1/scan", params: {}
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body).dig("details", "code")).to eq("blank")
    end

    it "returns 422 with code outside_filter for a folder outside the filter" do
      with_scan_home do |home|
        other = File.join(home, "Other", "x").tap { |dir| FileUtils.mkdir_p(dir) }

        expect { post "/api/v1/scan", params: { project_root: other } }.not_to have_enqueued_job(ProjectScanJob)
        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["details"]).to eq("code" => "outside_filter")
      end
    end

    it "returns 403 with code denied for a hidden folder" do
      with_scan_home do |home|
        post "/api/v1/scan", params: { project_root: File.join(home, ".ssh").tap { |dir| FileUtils.mkdir_p(dir) } }

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["details"]).to eq("code" => "denied")
      end
    end

    it "returns 422 for file_globs that leave the project root" do
      with_scan_project do |project|
        expect {
          post "/api/v1/scan", params: { project_root: project, file_globs: [ "../outside/*" ] }
        }.not_to have_enqueued_job(ProjectScanJob)
        expect(JSON.parse(response.body)["details"]).to eq("code" => "invalid_file_globs")
      end
    end
  end

  describe "GET /api/v1/scan/:id" do
    it "returns the scan operation status" do
      operation = OperationProgress.start!(
        operation_type: "project_scan",
        operation_id: SecureRandom.uuid,
        total_count: 5,
        message: "Running"
      )

      get "/api/v1/scan/#{operation.operation_id}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["scan_id"]).to eq(operation.operation_id)
      expect(json["status"]).to eq("running")
    end

    it "returns 404 for an unknown scan" do
      get "/api/v1/scan/unknown-id"
      expect(response).to have_http_status(:not_found)
    end
  end
end
