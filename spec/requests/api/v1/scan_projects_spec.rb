# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scan Projects API", type: :request do
  describe "POST /api/v1/scan" do
    it "enqueues a project scan and returns a scan id" do
      Dir.mktmpdir("api_scan_test") do |dir|
        File.write(File.join(dir, "README.md"), "# API Test")

        expect {
          post "/api/v1/scan", params: {
            project_root: dir,
            project_name: "APITestProject",
            mode: "initial"
          }
        }.to have_enqueued_job(ProjectScanJob)

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("queued")
        expect(json["scan_id"]).to be_present
      end
    end

    it "returns 422 for missing project_root" do
      post "/api/v1/scan", params: {}
      expect(response).to have_http_status(:unprocessable_content)
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
