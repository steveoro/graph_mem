# frozen_string_literal: true

require "rails_helper"

# The UI-1 shell in a browser: the sidebar, aria-current, the small-screen toggle and toasts.
RSpec.describe "Navigation", type: :system do
  let(:operator_nav) do
    %w[nav-home nav-search nav-explore nav-review nav-scan-review nav-maintenance
       nav-embeddings nav-telemetry nav-audit-logs nav-settings nav-jobs nav-api-docs]
  end
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:gadget) { MemoryEntity.create!(name: "SynthGadget", entity_type: "Component") }

  before do
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
  end

  def nav_testids
    all("nav.ui-sidebar a[data-testid^='nav-']", visible: :all).map { |link| link["data-testid"] }
  end

  context "as the operator" do
    before do
      sign_in_through_form
      expect(page).to have_current_path(root_path, wait: 5)
    end

    it "shows every section and marks the current page on every shell page" do
      expect(nav_testids).to eq(operator_nav)
      %w[Review\ &\ Fix Projects\ &\ Data System].each do |heading|
        expect(page).to have_css(".ui-sidebar__heading", text: heading, visible: :all)
      end

      (operator_nav - %w[nav-jobs nav-api-docs]).each do |testid|
        visit find("a[data-testid='#{testid}']", visible: :all)[:href]
        expect(page).to have_css("main#main")
        expect(find("a[data-testid='#{testid}']", visible: :all)["aria-current"]).to eq("page")
      end
    end

    it "shows a notice toast after sign-in that can be dismissed" do
      find(".ui-toast--notice", text: "Signed in successfully.").find(".ui-toast__dismiss").click

      expect(page).to have_no_css(".ui-toast")
    end

    it "lets a notice toast dismiss itself" do
      expect(page).to have_css(".ui-toast--notice")
      expect(page).to have_no_css(".ui-toast--notice", wait: 9)
    end

    it "toggles the menu on a small screen, and Escape closes it" do
      page.current_window.resize_to(800, 800)
      toggle = find("[data-testid='nav-toggle']")

      expect(toggle["aria-expanded"]).to eq("false")
      toggle.click
      expect(toggle["aria-expanded"]).to eq("true")
      # The class, not visibility: CI doesn't build the Tailwind stylesheet.
      expect(page).to have_css("nav.ui-sidebar.ui-sidebar--open")
      find("body").send_keys(:escape)
      expect(toggle["aria-expanded"]).to eq("false")
      expect(page).to have_no_css("nav.ui-sidebar.ui-sidebar--open")
      toggle.click
      toggle.click
      expect(toggle["aria-expanded"]).to eq("false")
    ensure
      page.current_window.resize_to(1280, 800)
    end

    it "shows a toast delivered by a Turbo Stream" do
      MaintenanceReportRow.create!(
        report_type: "compaction_review", row_uuid: "synth-merge-1", kind: "entity_merge", status: "active",
        signature: CompactionReviewService.signature_for("entity_merge", {
          "entity_a" => { "entity_id" => widget.id }, "entity_b" => { "entity_id" => gadget.id }
        }),
        payload: { "entity_a" => { "entity_id" => widget.id, "name" => widget.name, "entity_type" => "Component" },
                   "entity_b" => { "entity_id" => gadget.id, "name" => gadget.name, "entity_type" => "Component" } }
      )
      visit compaction_review_data_exchange_index_path
      find(".ui-toast__dismiss", match: :first).click if page.has_css?(".ui-toast", wait: 0)

      # A marker on window survives only if the toast arrives without a page load.
      page.execute_script("window.__noReload = true")
      click_button "Ignore"

      expect(page).to have_css("#toasts .ui-toast--notice", text: "Suggestion ignored")
      expect(page.evaluate_script("window.__noReload")).to be(true)
    end
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_through_form(username: "guest", password: OperatorAuthHelpers::TEST_GUEST_PASSWORD)
      expect(page).to have_current_path(search_path, wait: 5)
    end

    it "shows only Search, Explore, the read-only badge and Sign out" do
      expect(nav_testids).to eq(%w[nav-search nav-explore])
      expect(page).to have_css("[data-testid='nav-guest-badge']", text: "Read-only guest", visible: :all)
      expect(page).to have_css("#btn-operator-logout", visible: :all)
    end

    it "shows the 403 page for an operator-only URL" do
      visit maintenance_path

      expect(page).to have_css("[data-testid='guest-forbidden']")
      expect(page).to have_css("h1", text: "Operator only")
    end
  end
end
