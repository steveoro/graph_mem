# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project scans", type: :request do
  before { sign_in_operator }

  def flash_text
    follow_redirect!
    response.body
  end

  describe "POST /project_scans" do
    it "queues a project scan for the resolved realpath and redirects to the dashboard" do
      with_scan_project do |project|
        expect {
          post project_scans_path, params: { project_root: project, mode: "initial", dry_run: "1" }
        }.to have_enqueued_job(ProjectScanJob).with(anything, project, any_args)
          .and change(OperationProgress, :count).by(1)

        operation = OperationProgress.order(created_at: :desc).first
        expect(operation).to have_attributes(status: "pending", operation_type: "project_scan")
        expect(operation.details["project_root"]).to eq(project)
        expect(response).to redirect_to(root_path)
        expect(flash_text).to include("Project scan queued for #{project}")
      end
    end

    it "rejects a missing project root" do
      post project_scans_path

      expect(flash_text).to include("Give the path of the project folder to scan")
    end

    it "rejects a path that doesn't exist, saying whether its parent does" do
      with_scan_home do |home|
        post project_scans_path, params: { project_root: File.join(home, "Projects", "missing") }

        expect(flash_text).to include("was not found", "its parent #{home}/Projects exists")
      end
    end

    it "rejects an invalid mode" do
      with_scan_project do |project|
        post project_scans_path, params: { project_root: project, mode: "bad" }

        expect(flash_text).to include("Mode must be one of")
      end
    end

    it "passes optional project name, aliases, and file globs" do
      with_scan_project do |project|
        post project_scans_path, params: {
          project_root: project, project_name: "graph-mem", aliases: "gm, graph-mem", mode: "rescan",
          file_globs: "README*, package.json"
        }

        expect(response).to redirect_to(root_path)
        expect(ProjectScanJob).to have_been_enqueued.with(anything, project, "graph-mem", "gm, graph-mem", "rescan",
                                                          false, %w[README* package.json])
      end
    end

    {
      "/etc" => "visible to graph_mem: only",
      "%{home}/.ssh" => "inside a hidden or protected folder",
      "%{home}/Other/x" => "outside the scan filter (Projects)",
      "%{home}/Projects/../.." => "Use a path without"
    }.each do |template, message|
      it "rejects #{template} and queues nothing" do
        with_scan_home do |home|
          path = format(template, home: home)
          FileUtils.mkdir_p(path) unless path.include?("..") || path == "/etc"

          expect {
            post project_scans_path, params: { project_root: path, mode: "initial" }
          }.not_to have_enqueued_job(ProjectScanJob)
          expect(flash_text).to include(message)
        end
      end
    end
  end
end
