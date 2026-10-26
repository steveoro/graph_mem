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

  def graph_controller_js(expression)
    "(() => { const el = document.querySelector('[data-controller=\"graph\"]'); " \
      "const ctrl = window.Stimulus.getControllerForElementAndIdentifier(el, 'graph'); return #{expression}; })()"
  end

  def node_position_js(label)
    graph_controller_js(<<~JS.squish)
      (() => { if (!ctrl || !ctrl.cy) return null;
        const node = ctrl.cy.nodes().filter(n => n.data('label') === #{label.to_json})[0];
        if (!node) return null;
        const box = ctrl.containerTarget.getBoundingClientRect(); const p = node.renderedPosition();
        return [Math.round(box.left + p.x), Math.round(box.top + p.y)]; })()
    JS
  end

  # Right-clicks the node labelled `label` on the full graph; returns the menu item texts.
  def node_menu_items(label)
    visit graph_path
    expect(page).to have_css("[data-graph-target='container'] canvas", wait: 10)
    click_button "Full Graph"
    # The layout animates: wait until the node has stayed put for half a second.
    position = nil
    deadline = Time.current + 10
    loop do
      previous = position
      sleep 0.5
      position = evaluate_script(node_position_js(label))
      break if position && position == previous
      raise "node #{label} never settled" if Time.current > deadline
    end
    page.driver.browser.action.move_to_location(*position).context_click.perform
    all(".contextual-menu .ctx-item", minimum: 1).map(&:text)
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

    it "offers the edit items in the graph context menu" do
      expect(node_menu_items("SynthWidget")).to include("Edit data", "Delete", "Toggle relations")
      expect(evaluate_script(graph_controller_js("ctrl.dragDrop !== null"))).to be true
    end

    it "shows attention groups (not rows) in the Review badge, and links the Review pages" do
      2.times do |i|
        MaintenanceReportRow.create!(report_type: "compaction_review", row_uuid: "synth-badge-#{i}", kind: "relationship_proposal",
                                     status: "active", priority: 90, group_key: "relationship_proposal|1-2",
                                     signature: "badge|#{i}", payload: {})
      end
      Rails.cache.delete(UiHelper::REVIEW_BACKLOG_CACHE_KEY)

      visit root_path
      expect(page).to have_css("[data-testid='nav-review-badge']", text: "1", visible: :all)
      expect(page).to have_css("a[data-testid='nav-review'][href='/review']", visible: :all)
      expect(page).to have_css("a[data-testid='nav-scan-review'][href='/review?view=scan']", visible: :all)
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
      visit review_path(view: "kind")
      find(".ui-toast__dismiss", match: :first).click if page.has_css?(".ui-toast", wait: 0)
      click_link "Review", match: :first, exact: true
      expect(page).to have_css("[data-row-uuid='synth-merge-1']")

      # A marker on window survives only if the toast arrives without a page load.
      page.execute_script("window.__noReload = true")
      within("[data-row-uuid='synth-merge-1']") { click_button "Snooze" }

      expect(page).to have_css("#toasts .ui-toast--undo", text: "Suggestion snoozed")
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

    it "shows the graph without edit items or drag-and-drop" do
      items = node_menu_items("SynthWidget")

      expect(items).to include("Toggle relations", "Toggle observations")
      expect(items).not_to include("Edit data", "Delete")
      expect(evaluate_script(graph_controller_js("ctrl.dragDrop"))).to be_nil
      expect(page).to have_no_link("Back to dashboard")
    end

    it "shows the 403 page for an operator-only URL" do
      visit maintenance_path

      expect(page).to have_css("[data-testid='guest-forbidden']")
      expect(page).to have_css("h1", text: "Operator only")
    end
  end
end
