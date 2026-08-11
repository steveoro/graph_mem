# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe "Project scan skills", type: :request do
  before { sign_in_operator }

  describe "POST /project_scan_skills" do
    it "queues a guided project scan and redirects to the dashboard" do
      Dir.mktmpdir do |dir|
        expect {
          post project_scan_skills_path, params: { project_root: dir, dry_run: "1" }
        }.to have_enqueued_job(ProjectScanSkillJob).and change(OperationProgress, :count).by(1)

        operation = OperationProgress.order(created_at: :desc).first
        expect(operation.status).to eq("pending")
        expect(operation.operation_type).to eq("project_scan_skill")
        expect(operation.details["depths"]).to eq(ProjectScanSkill::DEPTH_ORDER)

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("Guided project scan queued")
      end
    end

    it "rejects a missing project root" do
      post project_scan_skills_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Project root is required")
    end

    it "rejects a project root that is not a directory" do
      post project_scan_skills_path, params: { project_root: "/nonexistent/path" }

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Project root is not a directory")
    end

    it "rejects invalid depths" do
      Dir.mktmpdir do |dir|
        post project_scan_skills_path, params: { project_root: dir, depths: %w[birds_eye invalid_depth] }

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("Invalid depths")
      end
    end

    it "rejects a project root outside the allowed directories" do
      Dir.mktmpdir do |dir|
        allow(AppSettings).to receive(:project_scan_root_paths).and_return([ "/nonexistent/allowed" ])

        post project_scan_skills_path, params: { project_root: dir }

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("outside the allowed scan directories")
      end
    end
  end

  describe "PATCH /project_scan_skills/:id" do
    it "continues a paused guided scan" do
      operation = OperationProgress.create!(
        operation_type: "project_scan_skill",
        operation_id: SecureRandom.uuid,
        status: "paused",
        total_count: ProjectScanSkill::DEPTH_ORDER.size,
        current_count: 0,
        percentage: 0,
        phase: "birds_eye",
        message: "Paused",
        details: {
          project_root: Dir.tmpdir,
          project_name: "test",
          depths: ProjectScanSkill::DEPTH_ORDER,
          current_depth_index: 0
        }
      )

      expect {
        patch project_scan_skill_path(operation.operation_id), params: { skill_action: "continue" }
      }.to have_enqueued_job(ProjectScanSkillJob)

      expect(operation.reload.status).to eq("running")
      expect(response).to redirect_to(root_path)
    end

    it "stops a guided scan" do
      operation = OperationProgress.create!(
        operation_type: "project_scan_skill",
        operation_id: SecureRandom.uuid,
        status: "paused",
        total_count: ProjectScanSkill::DEPTH_ORDER.size,
        current_count: 1,
        percentage: 20.0,
        phase: "architecture",
        message: "Paused after Birds-eye view. Next: Architecture",
        details: {
          project_root: Dir.tmpdir,
          depths: ProjectScanSkill::DEPTH_ORDER,
          current_depth_index: 1
        }
      )

      patch project_scan_skill_path(operation.operation_id), params: { skill_action: "stop" }

      expect(operation.reload.status).to eq("completed")
      expect(response).to redirect_to(root_path)
    end
  end
end
