# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe "Project scans", type: :request do
  before { sign_in_operator }

  describe "POST /project_scans" do
    it "queues a project scan and redirects to the dashboard" do
      Dir.mktmpdir do |dir|
        expect {
          post project_scans_path, params: { project_root: dir, mode: "initial", dry_run: "1" }
        }.to have_enqueued_job(ProjectScanJob)

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("Project scan queued")
      end
    end

    it "rejects a missing project root" do
      post project_scans_path

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Project root is required")
    end

    it "rejects a project root that is not a directory" do
      post project_scans_path, params: { project_root: "/nonexistent/path" }

      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response.body).to include("Project root is not a directory")
    end

    it "rejects an invalid mode" do
      Dir.mktmpdir do |dir|
        post project_scans_path, params: { project_root: dir, mode: "bad" }

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("Mode must be one of")
      end
    end

    it "passes optional project name, aliases, and file globs" do
      Dir.mktmpdir do |dir|
        post project_scans_path, params: {
          project_root: dir,
          project_name: "graph-mem",
          aliases: "gm, graph-mem",
          mode: "rescan",
          file_globs: "README*, package.json"
        }

        expect(response).to redirect_to(root_path)
        expect(ProjectScanJob).to have_been_enqueued
      end
    end

    it "rejects a project root outside the allowed directories" do
      Dir.mktmpdir do |dir|
        allow(AppSettings).to receive(:project_scan_root_paths).and_return([ "/nonexistent/allowed" ])

        post project_scans_path, params: { project_root: dir, mode: "initial" }

        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect(response.body).to include("outside the allowed scan directories")
      end
    end
  end
end
