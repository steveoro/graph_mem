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

    it "adds an observation from the panel, shows the toast, and undoes it" do
      visit explore_path(entity_id: widget.id)
      wait_for_nodes(3)
      execute_script(explore_js("ctrl.select(#{widget.id.to_s.to_json})"))

      within("turbo-frame#entity-panel") do
        find("[data-testid='entity-panel-add-observation'] summary").click
        fill_in "Text", with: "SynthWidget caches synthetic tiles."
        click_button "Add"
      end

      expect(page).to have_css("#toasts .ui-toast--undo", text: "Observation added")
      within("turbo-frame#entity-panel") { expect(page).to have_text("SynthWidget caches synthetic tiles.") }
      expect(ChangeSet.sole.kind).to eq("explore.observation_add")

      within("#toasts") { click_button "Undo" }
      expect(page).to have_css("#toasts .ui-toast--notice", text: "Undone")
      expect(page).to have_current_path(explore_path(entity_id: widget.id))
      expect(MemoryObservation.where(content: "SynthWidget caches synthetic tiles.").pluck(:status)).not_to include("active")
      expect(csp_console_errors).to be_empty
    end

    it "drops the Undo button once ten minutes have passed" do
      visit explore_path(entity_id: widget.id)
      wait_for_nodes(3)
      execute_script(explore_js("ctrl.select(#{widget.id.to_s.to_json})"))
      within("turbo-frame#entity-panel") { find("[data-testid='entity-panel-add-observation'] summary").click }
      # The toast reads the clock when it appears: move the page's clock past the 10 minutes.
      execute_script("const realNow = Date.now; Date.now = () => realNow() + 601000;")

      within("turbo-frame#entity-panel") do
        fill_in "Text", with: "SynthWidget renders late tiles."
        click_button "Add"
      end

      expect(page).to have_css("#toasts [data-testid='toast-undo-later']", text: "Undo it later from Home › Recent activity.")
      expect(page).to have_no_css("#toasts [data-testid='toast-undo-button']")
    end

    it "drops a node on another, adds a relation from the type picker, and the canvas shows it" do
      record_fetches!
      visit explore_path(scope: "full")
      wait_for_nodes(3)

      execute_script(explore_js("ctrl.dragDrop.showMenu(ctrl.cy.$id(#{router.id.to_s.to_json}), ctrl.cy.$id(#{alpha.id.to_s.to_json}))"))
      expect(page).to have_css("[data-testid='explore-drop-menu']")
      expect(page).to have_no_css("[data-testid='drop-merge']") # different types
      find("[data-testid='drop-add-relation']").click

      within("dialog[open] [data-testid='explore-relation-dialog']") do
        expect(page).to have_text("Synth Router")
        select "relates_to", from: "Relation type"
        click_button "Add relation"
      end

      expect(page).to have_css("#toasts .ui-toast--undo", text: "Added 'Synth Router relates_to Alpha Service'.")
      expect(page).to have_no_css("dialog[open]")
      expect(MemoryRelation.where(from_entity_id: router.id, to_entity_id: alpha.id, relation_type: "relates_to")).to exist
      page.document.synchronize do
        edges = evaluate_script(explore_js("ctrl.cy.edges().length"))
        raise Capybara::ExpectationNotMet, "edge not drawn yet" unless edges == 3
      end
      writes = recorded_fetches.grep(%r{\A(?!GET )\S+ /api/v1/|/data_exchange/(update_relation|delete_relation|delete_duplicate_relations)})
      expect(writes).to be_empty
      expect(recorded_fetches).to include("POST /explore/relations")
      expect(csp_console_errors).to be_empty
    end

    it "merges from the context menu through the dialog, then undoes the merge" do
      twin = MemoryEntity.create!(name: "SynthWidget Twin", entity_type: "Component")
      MemoryObservation.create!(memory_entity: twin, content: "SynthWidget Twin is a synthetic duplicate.")
      visit explore_path(scope: "full")
      wait_for_nodes(4)

      items = node_menu_items("SynthWidget Twin")
      expect(items).to include("Edit in panel", "Merge into…", "Propose deletion")
      expect(items).not_to include("Delete", "Delete duplicates")
      find(".contextual-menu [data-testid='ctx-merge']").click

      within("dialog[open]") do
        fill_in "explore-merge-q", with: "SynthWidget"
        click_button "Search"
        click_link "SynthWidget"
        expect(page).to have_css("[data-testid='explore-merge-dialog']", text: "Merge SynthWidget Twin (source, will be removed) into SynthWidget (survivor)")
        expect(page).to have_css("[data-testid='explore-merge-observations']", text: "1 observation moves")
      end
      expect(csp_console_errors).to be_empty
      within("dialog[open]") { click_button "Merge" }

      expect(page).to have_css("#toasts .ui-toast--undo", text: "Merged 'SynthWidget Twin' into 'SynthWidget'.")
      wait_for_nodes(3)
      expect(MemoryEntity.exists?(twin.id)).to be(false)

      within("#toasts") { click_button "Undo" }
      expect(page).to have_css("#toasts .ui-toast--notice", text: "Undone")
      expect(MemoryEntity.find(twin.id).memory_observations.count).to eq(1)
    end

    it "works the context menu from the keyboard" do
      visit explore_path(scope: "full")
      wait_for_nodes(3)

      node_menu_items("SynthWidget")
      expect(evaluate_script("document.activeElement.textContent")).to eq("Show in panel")
      page.driver.browser.action.send_keys(:arrow_down).perform
      expect(evaluate_script("document.activeElement.textContent")).to eq("Open neighbourhood")
      page.driver.browser.action.send_keys(:arrow_up, :enter).perform

      within("turbo-frame#entity-panel") { expect(page).to have_css("h2", text: "SynthWidget") }
      expect(page).to have_no_css(".contextual-menu")

      node_menu_items("SynthWidget")
      page.driver.browser.action.send_keys(:escape).perform
      expect(page).to have_no_css(".contextual-menu")
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
      expect(items).not_to include("Edit in panel", "Merge into…", "Propose deletion", "Remove relation")
      expect(evaluate_script(explore_js("ctrl.readOnlyValue"))).to be(true)
      expect(evaluate_script(explore_js("ctrl.dragDrop"))).to be_nil
      expect(page).to have_no_css("dialog[data-controller='explore-dialog']", visible: :all)

      # Dragging only moves the node locally: no menu, no request.
      execute_script(explore_js("(() => { const n = ctrl.cy.$id(#{widget.id.to_s.to_json}); n.position({ x: 5, y: 5 }); n.emit('free'); })()"))
      expect(page).to have_no_css("[data-testid='explore-drop-menu']")

      find("body").send_keys(:escape)
      execute_script(explore_js("ctrl.select(#{widget.id.to_s.to_json})"))
      within("turbo-frame#entity-panel") do
        expect(page).to have_css("h2", text: "SynthWidget")
        expect(page).to have_no_css("form, details, button")
      end
      expect(csp_console_errors).to be_empty
    end
  end
end
