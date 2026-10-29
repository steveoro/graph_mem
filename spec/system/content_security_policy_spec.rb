# frozen_string_literal: true

require "rails_helper"

# CSP is enforced since UI-1 (1.56.0). Visit every shell page in a real browser and fail
# on any Content Security Policy console message.
RSpec.describe "Content Security Policy in the browser", type: :system do
  let!(:project) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: project, relation_type: "part_of")
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
  end

  def expect_no_csp_errors(label)
    expect(csp_console_errors).to be_empty, "CSP console errors on #{label}"
  end

  it "shows no CSP violations on any operator page" do
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)
    wait_for_stimulus
    expect_no_csp_errors("sign-in and Home")

    {
      "Search" => "/search?q=SynthWidget",
      "Projects" => "/projects",
      "New scan" => "/projects/scans/new",
      "Import" => "/projects/imports/new",
      "Exports" => "/projects/exports",
      "Background jobs" => "/projects/jobs",
      "Review & Fix" => "/review",
      "Scan review" => "/review?view=scan",
      "Embeddings" => "/operator/embeddings",
      "Telemetry" => "/operator/telemetry",
      "Audit log" => "/operator/audit_logs",
      "Settings" => "/operator/settings"
    }.each do |label, path|
      visit path
      wait_for_stimulus
      expect_no_csp_errors(label)
    end

    # Mission Control has its own layout and Stimulus instance: wait for its tabs instead.
    visit "/operator/jobs"
    expect(page).to have_link("Failed jobs")
    expect_no_csp_errors("Jobs")

    visit explore_path
    expect(page).to have_css("[data-explore-target='canvas'] canvas", wait: 10)
    expect_no_csp_errors("Explore")

    twin = MemoryEntity.create!(name: "SynthWidget Twin", entity_type: "Component")
    execute_script("document.getElementById('explore-dialog').src = #{new_explore_merge_path(source_id: twin.id, target_id: widget.id).to_json}")
    expect(page).to have_css("dialog[open] [data-testid='explore-merge-dialog']", wait: 10)
    expect_no_csp_errors("Explore with the merge dialog open")
  end

  it "shows no CSP violations on the guest pages" do
    enable_guest!
    sign_in_through_form(username: "guest", password: OperatorAuthHelpers::TEST_GUEST_PASSWORD)
    expect(page).to have_current_path(search_path, wait: 5)

    visit "/search?q=SynthWidget"
    wait_for_stimulus
    expect_no_csp_errors("guest Search")

    visit explore_path
    expect(page).to have_css("[data-explore-target='canvas'] canvas", wait: 10)
    expect_no_csp_errors("guest Explore")
  end

  it "loads Swagger UI under rswag's own policy" do
    sign_in_through_form
    expect(page).to have_current_path(root_path, wait: 5)

    visit "/api-docs/index.html"

    expect(page).to have_css("#swagger-ui .swagger-ui", wait: 10)
    expect_no_csp_errors("API docs")
  end
end
