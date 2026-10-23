# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project scan skills", type: :request do
  before { sign_in_operator }

  def flash_text
    follow_redirect!
    response.body
  end

  describe "POST /project_scan_skills" do
    it "queues a guided project scan for the resolved realpath and redirects to the dashboard" do
      with_scan_project do |project|
        expect {
          post project_scan_skills_path, params: { project_root: project, dry_run: "1" }
        }.to have_enqueued_job(ProjectScanSkillJob).and change(OperationProgress, :count).by(1)

        operation = OperationProgress.order(created_at: :desc).first
        expect(operation).to have_attributes(status: "pending", operation_type: "project_scan_skill")
        expect(operation.details).to include("depths" => ProjectScanSkill::DEPTH_ORDER, "project_root" => project)
        expect(response).to redirect_to(root_path)
        expect(flash_text).to include("Guided project scan queued for #{project}")
      end
    end

    it "rejects a missing project root" do
      post project_scan_skills_path

      expect(flash_text).to include("Give the path of the project folder to scan")
    end

    it "rejects invalid depths" do
      with_scan_project do |project|
        post project_scan_skills_path, params: { project_root: project, depths: %w[birds_eye invalid_depth] }

        expect(flash_text).to include("Invalid depths")
      end
    end

    {
      "/etc" => "visible to graph_mem: only",
      "%{home}/.ssh" => "inside a hidden or protected folder",
      "%{home}/Other/x" => "outside the scan filter (Projects)"
    }.each do |template, message|
      it "rejects #{template} and queues nothing" do
        with_scan_home do |home|
          path = format(template, home: home)
          FileUtils.mkdir_p(path) unless path == "/etc"

          expect {
            post project_scan_skills_path, params: { project_root: path }
          }.not_to have_enqueued_job(ProjectScanSkillJob)
          expect(flash_text).to include(message)
        end
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
