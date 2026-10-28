# frozen_string_literal: true

require "rails_helper"

# UI-4b: Explore in a browser (synthetic data). Cytoscape is driven through the controller's `cy`.
RSpec.describe "Explore", type: :system do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component") }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }

  before do
    MemoryRelation.create!(from_entity: widget, to_entity: alpha, relation_type: "part_of")
    MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on")
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
  end

  def node_ids = evaluate_script(explore_js("ctrl && ctrl.cy ? ctrl.cy.nodes().map(n => n.id()).sort() : null"))

  context "as the operator" do
    before do
      sign_in_through_form
      expect(page).to have_current_path(root_path, wait: 5)
    end

    it "opens a scope, writes it to the URL, and opens a node's panel" do
      visit explore_path(scope: "full")
      expect(page).to have_css("[data-explore-target='canvas'] canvas", wait: 10)
      page.document.synchronize { node_ids&.size == 3 || raise(Capybara::ExpectationNotMet, "graph not rendered") }

      select "Alpha Service", from: "explore-scope"
      expect(page).to have_current_path(explore_path(project_id: alpha.id))
      select "Full graph", from: "explore-scope"
      expect(page).to have_current_path(explore_path(scope: "full"))

      execute_script(explore_js("ctrl.select(#{widget.id.to_s.to_json})"))
      within("turbo-frame#entity-panel") { expect(page).to have_css("h2", text: "SynthWidget") }

      execute_script(explore_js("ctrl.openNeighbourhood(#{router.id})"))
      expect(page).to have_current_path(explore_path(entity_id: router.id))
      page.document.synchronize { node_ids == [ widget.id, router.id ].map(&:to_s).sort || raise(Capybara::ExpectationNotMet, "not yet") }
      expect(csp_console_errors).to be_empty
    end

    it "filters by type locally and shows read items in the context menu" do
      visit explore_path(scope: "full")
      expect(page).to have_css("[data-explore-target='canvas'] canvas", wait: 10)

      expect(node_menu_items("SynthWidget")).to include("Show in panel", "Open neighbourhood", "Toggle relations")
      find("body").send_keys(:escape)

      select "Service", from: "explore-type-filter"
      shown = evaluate_script(explore_js("ctrl.cy.nodes().filter(n => n.style('display') !== 'none').map(n => n.data('label'))"))
      expect(shown).to eq([ "Synth Router" ])
    end
  end

  context "as a guest" do
    before do
      enable_guest!
      sign_in_through_form(username: "guest", password: OperatorAuthHelpers::TEST_GUEST_PASSWORD)
      expect(page).to have_current_path(search_path, wait: 5)
    end

    it "shows the canvas and the panel, read-only" do
      visit explore_path(scope: "full")
      expect(page).to have_css("[data-explore-target='canvas'] canvas", wait: 10)

      items = node_menu_items("SynthWidget")
      expect(items).to include("Show in panel", "Toggle relations")
      expect(items).not_to include("Edit in panel", "Merge into…", "Propose deletion")
      expect(evaluate_script(explore_js("ctrl.readOnlyValue"))).to be(true)
      expect(csp_console_errors).to be_empty
    end
  end
end
