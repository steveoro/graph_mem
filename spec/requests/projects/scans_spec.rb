# frozen_string_literal: true

require "rails_helper"

# UI-6 P3: one scan form (normal or guided) with a live path check, the scan history and a
# detail page. Scan roots are Dir.mktmpdir trees (spec/support/scan_root_helpers.rb).
RSpec.describe "Projects › Scans", type: :request do
  describe "as a guest or signed out" do
    it "answers 403 to a guest and queues nothing" do
      enable_guest!
      sign_in_guest

      with_scan_project do |project|
        expect { post projects_scans_path, params: { project_root: project } }.not_to change(OperationProgress, :count)
        expect(response).to have_http_status(:forbidden)
      end
      [ projects_scans_path, new_projects_scan_path, check_path_projects_scans_path(path: "/tmp") ].each do |path|
        get path
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "sends a signed-out visitor to the login page" do
      get new_projects_scan_path

      expect(response).to redirect_to(operator_login_path)
    end
  end

  describe "as the operator" do
    before { sign_in_operator }

    it "checks a path live, with the same partial as Settings" do
      with_scan_home do |home|
        FileUtils.mkdir_p(File.join(home, "Projects", "alpha"))
        FileUtils.mkdir_p(File.join(home, "Other", "beta"))
        FileUtils.mkdir_p(File.join(home, ".ssh"))
        {
          File.join(home, "Projects", "alpha") => "ok",
          File.join(home, "Other", "beta") => "outside_filter",
          File.join(home, ".ssh") => "denied",
          "/etc" => "not_mounted"
        }.each do |path, code|
          get check_path_projects_scans_path(path: path)

          expect(response.body).to include('id="scan-path-check"', %(data-code="#{code}"))
          get check_path_projects_scans_path(path: path)
          expect(response.body).to include(%(data-code="#{code}"))
        end
      end
    end

    it "renders the form with the scannable folders as chips" do
      with_scan_home do |home|
        get new_projects_scan_path

        expect(response).to have_http_status(:ok)
        chips = Nokogiri::HTML(response.body).css("[data-testid='scan-folder-chip']")
        expect(chips.map { |chip| chip["data-path-check-path-param"] }).to eq([ File.join(home, "Projects") ])
        expect(response.body).to include('data-controller="path-check"', 'name="guided"', 'name="depths[]"')
      end
    end

    it "queues a normal scan and opens its detail page" do
      with_scan_project do |project|
        expect {
          post projects_scans_path, params: { project_root: project, project_name: "Alpha Service", mode: "initial", dry_run: "1",
                                              file_globs: "README*" }
        }.to have_enqueued_job(ProjectScanJob).with(anything, project, "Alpha Service", nil, "initial", true, %w[README*])

        operation = OperationProgress.sole
        expect(operation).to have_attributes(operation_type: "project_scan", status: "pending")
        expect(response).to redirect_to(projects_scan_path(operation.operation_id))
        follow_redirect!
        expect(response.body).to include("Project scan queued for #{project}", "Alpha Service", 'data-controller="operation-progress"')
      end
    end

    it "queues a guided scan with the chosen steps" do
      with_scan_project do |project|
        expect {
          post projects_scans_path, params: { project_root: project, guided: "1", depths: %w[birds_eye usage] }
        }.to have_enqueued_job(ProjectScanSkillJob)

        operation = OperationProgress.sole
        expect(operation).to have_attributes(operation_type: "project_scan_skill", status: "pending", total_count: 2)
        expect(operation.details).to include("project_root" => project, "depths" => %w[birds_eye usage], "dry_run" => false)
        expect(response).to redirect_to(projects_scan_path(operation.operation_id))
      end
    end

    it "re-renders a refused path with the policy's message (422) and queues nothing" do
      with_scan_home do |home|
        FileUtils.mkdir_p(File.join(home, ".ssh"))

        expect { post projects_scans_path, params: { project_root: File.join(home, ".ssh"), project_name: "Gadget Project" } }
          .not_to have_enqueued_job

        expect(response).to have_http_status(:unprocessable_content)
        page = Nokogiri::HTML(response.body)
        expect(page.at_css("[data-testid='scan-form-error']").text).to be_present
        expect(page.at_css("[data-testid='scan-check-result']")["data-code"]).to eq("denied")
        expect(page.at_css("#project_name")["value"]).to eq("Gadget Project")
        expect(OperationProgress.count).to eq(0)
      end
    end

    # Ported from the removed /project_scans and /project_scan_skills specs (1.65.0).
    it "passes the aliases through, and refuses a missing or nonexistent root with its message" do
      with_scan_home do |home|
        post projects_scans_path
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Give the path of the project folder to scan")

        post projects_scans_path, params: { project_root: File.join(home, "Projects", "missing") }
        expect(response.body).to include("was not found", "its parent #{home}/Projects exists")
      end

      with_scan_project do |project|
        post projects_scans_path, params: { project_root: project, project_name: "Alpha Service", aliases: "alpha, synth-alpha", mode: "rescan" }
        expect(ProjectScanJob).to have_been_enqueued.with(anything, project, "Alpha Service", "alpha, synth-alpha", "rescan", false, nil)
      end
    end

    {
      "/etc" => "visible to graph_mem: only",
      "%{home}/.ssh" => "inside a hidden or protected folder",
      "%{home}/Other/x" => "outside the scan filter (Projects)",
      "%{home}/Projects/../.." => "Use a path without"
    }.each do |template, message|
      it "refuses #{template} for a normal and a guided scan, and queues nothing" do
        with_scan_home do |home|
          path = format(template, home: home)
          FileUtils.mkdir_p(path) unless path.include?("..") || path == "/etc"

          [ {}, { guided: "1", depths: %w[birds_eye] } ].each do |extra|
            expect { post projects_scans_path, params: { project_root: path, mode: "initial", **extra } }.not_to have_enqueued_job
            expect(response).to have_http_status(:unprocessable_content)
            expect(response.body).to include(message)
          end
        end
      end
    end

    it "re-renders an unknown mode or step (422)" do
      with_scan_project do |project|
        post projects_scans_path, params: { project_root: project, mode: "bad" }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Mode must be one of")

        post projects_scans_path, params: { project_root: project, guided: "1", depths: %w[bogus] }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Invalid depths: bogus")
      end
    end

    it "shows a scan's counters, fallback, error and its project's scan-review groups" do
      project = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
      scan = OperationProgress.create!(
        operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "completed", phase: "completed",
        counters: { "entities_created" => 3, "skipped_outside_root" => 2, "skipped_denylisted" => 1 },
        details: { "project_root" => "/scan/alpha", "mode" => "initial", "project_entity_id" => project.id,
                   "fallback" => true, "fallback_reason" => "no model configured" }, error_message: "SynthWidget.rb unreadable"
      )
      2.times do |i|
        MaintenanceReportRow.create!(report_type: "scan_review", row_uuid: SecureRandom.uuid, kind: "relationship_proposal",
                                     signature: "sig-#{i}", payload: {}, project_id: project.id, group_key: "group-#{i}")
      end

      get projects_scan_path(scan.operation_id)

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-testid='scan-counter-skipped_outside_root']").text).to include("2")
      expect(page.at_css("[data-testid='scan-counter-skipped_denylisted']").text).to include("1")
      expect(page.at_css("[data-testid='scan-fallback']").text).to include("no model configured")
      expect(page.at_css("[data-testid='scan-error']").text).to include("SynthWidget.rb unreadable")
      link = page.at_css("[data-testid='scan-review-link']")
      expect(link.text).to include("2 scan-review groups")
      expect(link["href"]).to eq(review_path(view: "scan", project_id: project.id))
    end

    it "continues and stops a guided scan from its detail page" do
      scan = OperationProgress.create!(operation_type: "project_scan_skill", operation_id: SecureRandom.uuid, status: "paused",
                                       details: { "project_root" => "/scan/alpha", "depths" => %w[birds_eye] })
      get projects_scan_path(scan.operation_id)
      expect(response.body).to include('data-testid="scan-continue"', 'data-testid="scan-stop"')

      expect { patch projects_scan_skill_path(scan.operation_id, skill_action: "continue") }.to have_enqueued_job(ProjectScanSkillJob)
      expect(response).to redirect_to(projects_scan_path(scan.operation_id))
      expect(scan.reload.status).to eq("running")
    end

    it "answers 404 for an unknown or malformed id" do
      [ SecureRandom.uuid, "not-a-uuid", "1" ].each do |id|
        get projects_scan_path(id)
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include('data-testid="projects-not-found"')
      end
    end

    it "lists scans newest first" do
      older = OperationProgress.create!(operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "completed",
                                        details: { "project_name" => "Gadget Project", "mode" => "rescan" }, created_at: 2.days.ago)
      newer = OperationProgress.create!(operation_type: "project_scan_skill", operation_id: SecureRandom.uuid, status: "running",
                                        details: { "project_root" => "/scan/alpha" })

      get projects_scans_path

      rows = Nokogiri::HTML(response.body).css("[data-testid^='scan-row-']").map { |row| row["data-testid"] }
      expect(rows).to eq([ "scan-row-#{newer.operation_id}", "scan-row-#{older.operation_id}" ])
      expect(response.body).to include("Gadget Project", "normal (rescan)", "guided", "alpha")
    end
  end
end
