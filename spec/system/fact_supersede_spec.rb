# frozen_string_literal: true

require "rails_helper"

# Fact supersede (T): mark a fact in Explore → the job runs → Review › By kind shows the row →
# Supersede → the panel shows "Outdated by". Then Find & supersede retires a row. Synthetic data;
# the LLM is off, so rows are unjudged.
RSpec.describe "Fact supersede", type: :system do
  let!(:gadget) { fs_project!("Gadget Project") }
  let!(:widget) { fs_member!(gadget, "SynthWidget") }
  let!(:old) { fs_observe!(widget, "The MCP server runs on fast-mcp.") }
  let!(:fact) { fs_observe!(gadget, "The MCP server uses the official mcp gem.", tags: [ "replaces:fast-mcp" ]) }

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_css("nav.ui-sidebar")
  end

  it "marks a fact in Explore, reviews the proposal, supersedes it, and the panel says Outdated by" do
    visit explore_path(entity_id: gadget.id)
    wait_for_nodes(2)
    execute_script(explore_js("ctrl.select(#{gadget.id.to_s.to_json})"))
    perform_enqueued_jobs(only: FactSupersedeJob) do
      within("turbo-frame#entity-panel ##{"observation-#{fact.id}"}") { click_button "Mark as source fact" }
      within("turbo-frame#entity-panel") { expect(page).to have_css("[data-testid='entity-panel-source-fact']") }
    end
    row = MaintenanceReportRow.find_by!(kind: "fact_supersede")

    visit review_path(view: "kind", kind: "fact_supersede")
    wait_for_stimulus
    expect(page).to have_css(".ui-badge", text: /outdated by a fact/i)
    click_link "Review", match: :first, exact: true
    within("##{ActionView::RecordIdentifier.dom_id(row)}") { click_link "Supersede or retire…" }
    within("[data-testid='review-detail-card']") { click_link "Supersede…" }
    within("[data-testid='review-preview-card']") do
      fill_in "Replacement text", with: "The MCP server runs on the mcp gem."
      click_button "Supersede"
    end
    expect(page).to have_css("[data-testid='toast-undo']")
    expect(old.reload).to have_attributes(status: "superseded", outdated_by_id: fact.id)

    visit explore_path(entity_id: widget.id)
    wait_for_nodes(2)
    execute_script(explore_js("ctrl.select(#{widget.id.to_s.to_json})"))
    within("turbo-frame#entity-panel") do
      expect(page).to have_text("The MCP server runs on the mcp gem.")
      click_link "Show 1 obsolete"
      expect(page).to have_css("[data-testid='entity-panel-outdated-by']", text: "The MCP server uses the official mcp gem.")
    end
    expect(csp_console_errors).to be_empty
  end

  it "retires a selection on Find & supersede, then undoes it from the toast" do
    fact.update_active!(tags: [ "source-fact", "replaces:fast-mcp" ])
    second = fs_observe!(widget, "SynthWidget talks to fast-mcp.")

    visit review_supersede_path(project_id: gadget.id, fact_id: fact.id)
    expect(page).to have_css("[data-testid='supersede-vector-off']")
    check "observation-#{old.id}"
    check "observation-#{second.id}"
    choose "Retire"
    click_button "Apply to the selection"

    expect(page).to have_css("[data-testid='toast-undo']", text: "Retired 2 observations.")
    expect([ old, second ].map { |row| row.reload.status }).to all(eq("obsolete"))
    within("[data-testid='toast-undo']") { click_button "Undo" }
    expect(page).to have_css(".ui-toast--notice", text: "Undone")
    expect([ old, second ].map { |row| row.reload.status }).to all(eq("active"))
    expect(csp_console_errors).to be_empty
  end
end
