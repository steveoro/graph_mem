# frozen_string_literal: true

require "rails_helper"

# UI-6 P2: the Projects list. One row per Project root with its last scan, last import and
# pending scan-review groups, in a fixed number of queries.
RSpec.describe "Projects", type: :request do
  def scan(project, at:, **attributes)
    OperationProgress.create!(operation_type: "project_scan", operation_id: SecureRandom.uuid, status: "completed", created_at: at,
                              details: { "mode" => "initial", "project_entity_id" => project.id }, **attributes)
  end

  def review_row(project, group_key)
    MaintenanceReportRow.create!(report_type: "scan_review", row_uuid: SecureRandom.uuid, kind: "relationship_proposal",
                                 signature: SecureRandom.hex(8), payload: {}, project_id: project.id, group_key: group_key)
  end

  it "answers 403 to a guest and sends a signed-out visitor to the login page" do
    get projects_path
    expect(response).to redirect_to(operator_login_path)

    enable_guest!
    sign_in_guest
    get projects_path
    expect(response).to have_http_status(:forbidden)
  end

  context "as the operator" do
    before { sign_in_operator }

    it "shows an empty state that links to a new scan and an import" do
      get projects_path

      page = Nokogiri::HTML(response.body)
      expect(page.at_css("[data-testid='projects-empty']")).to be_present
      expect(page.at_css("[data-testid='projects-new-scan']")["href"]).to eq(new_projects_scan_path)
      expect(page.at_css("[data-testid='projects-import']")["href"]).to eq(new_projects_import_path)
    end

    it "lists each Project root with its newest scan and import, its review groups and Explore" do
      alpha = MemoryEntity.create!(name: "Alpha Service", entity_type: "Project")
      gadget = MemoryEntity.create!(name: "Gadget Project", entity_type: "Project")
      MemoryEntity.create!(name: "SynthWidget", entity_type: "Component")
      scan(alpha, at: 2.days.ago)
      newest = scan(alpha, at: 1.hour.ago, status: "failed")
      # Before a scan records project_entity_id, its project_name is the link.
      pending = OperationProgress.create!(operation_type: "project_scan_skill", operation_id: SecureRandom.uuid, status: "pending",
                                          details: { "project_name" => "Gadget Project", "project_root" => "/scan/gadget" })
      import = OperationProgress.create!(operation_type: "import", operation_id: SecureRandom.uuid, status: "completed",
                                         details: { "project_entity_id" => gadget.id, "producer" => "graphify" })
      review_row(alpha, "group-a")
      review_row(alpha, "group-a")
      review_row(alpha, "group-b")

      get projects_path

      page = Nokogiri::HTML(response.body)
      alpha_row = page.at_css("[data-testid='project-row-#{alpha.id}']")
      gadget_row = page.at_css("[data-testid='project-row-#{gadget.id}']")
      expect(page.css("[data-testid^='project-row-']").size).to eq(2)
      expect(alpha_row.at_css("a[href='#{projects_scan_path(newest.operation_id)}']").text).to include("Failed")
      expect(alpha_row.at_css("[data-testid='project-review-#{alpha.id}']").text).to eq("2 groups")
      expect(alpha_row.at_css("[data-testid='project-review-#{alpha.id}']")["href"]).to eq(review_path(view: "scan", project_id: alpha.id))
      expect(alpha_row.text).to include("never") # no import yet
      expect(alpha_row.at_css("a[href='#{explore_path(project_id: alpha.id)}']")).to be_present
      expect(gadget_row.at_css("a[href='#{projects_scan_path(pending.operation_id)}']").text).to include("guided")
      expect(gadget_row.at_css("a[href='#{report_projects_import_path(import.operation_id)}']")).to be_present
    end

    it "runs a fixed number of queries however many projects the page holds" do
      counts = [ 2, 6 ].map do |size|
        size.times do |i|
          project = MemoryEntity.create!(name: "Alpha Service #{size}-#{i}", entity_type: "Project")
          scan(project, at: i.hours.ago)
          review_row(project, "group-#{size}-#{i}")
        end
        queries = 0
        callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get projects_path }
        queries
      end

      expect(counts.first).to eq(counts.last)
    end
  end
end
