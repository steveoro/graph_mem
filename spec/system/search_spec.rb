# frozen_string_literal: true

require "rails_helper"

# UI-3: Search in a browser (synthetic data): query, a chip, a result, its panel, Open in Explore,
# and Show as graph on /graph?ids=. Enforced CSP, no violations.
RSpec.describe "Search", type: :system do
  let!(:alpha) { MemoryEntity.create!(name: "Alpha Service", entity_type: "Project") }
  let!(:widget) { MemoryEntity.create!(name: "SynthWidget", entity_type: "Component", project_id: alpha.id) }
  let!(:router) { MemoryEntity.create!(name: "Synth Router", entity_type: "Service") }
  let!(:stray) { MemoryEntity.create!(name: "Stray Node", entity_type: "Component") }

  before do
    MemoryObservation.create!(memory_entity: widget, content: "SynthWidget renders synthetic tiles.")
    MemoryRelation.create!(from_entity: widget, to_entity: router, relation_type: "depends_on")
    MemoryRelation.create!(from_entity: widget, to_entity: stray, relation_type: "depends_on")
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    sign_in_through_form
    expect(page).to have_css("nav.ui-sidebar")
  end

  it "goes from a query and a chip to a result's panel and on to Explore" do
    visit search_path
    wait_for_stimulus
    fill_in "search-q", with: "synth"
    click_button "Search"
    expect(page).to have_css("[data-testid='search-result']", count: 2)

    # A chip submits the form on its own (search_controller.js).
    find("details", text: "Types").find("summary").click
    find("label.search-chip", text: "Service").click
    expect(page).to have_current_path(/types%5B%5D=Service/)
    expect(page).to have_css("[data-testid='search-result']", count: 1, text: "Synth Router")

    click_link "Synth Router"
    within("turbo-frame#entity-panel") do
      expect(page).to have_css("h2", text: "Synth Router")
      expect(page).to have_link("SynthWidget", href: entity_panel_path(widget))
      click_link "SynthWidget" # a relation opens its own panel in the frame
      expect(page).to have_css("h2", text: "SynthWidget")
    end
    expect(page).to have_current_path(/types%5B%5D=Service/) # the frame navigated, not the page
    expect(page).to have_css("[data-testid='search-result'].search-result--selected", text: "Synth Router")

    within("turbo-frame#entity-panel") { click_link "Open in Explore" }
    expect(page).to have_current_path(graph_path(scoped_entity_id: widget.id))
    expect(csp_console_errors).to be_empty
  end

  it "shows the page's results and the relations among them as a graph" do
    visit search_path(q: "synth")
    click_link "Show as graph"

    expect(page).to have_current_path(%r{\A/graph\?ids=})
    shown_ids = Rack::Utils.parse_query(URI(page.current_url).query)["ids"].split(",")
    expect(shown_ids).to contain_exactly(widget.id.to_s, router.id.to_s)
    expect(page).to have_css("[data-testid='graph-from-search']:not(.graph-hidden)")
    graph = lambda do
      page.evaluate_script(<<~'JS')
        (() => {
          const el = document.querySelector('[data-controller="graph"]');
          const ctrl = el && window.Stimulus.getControllerForElementAndIdentifier(el, 'graph');
          if (!ctrl || !ctrl.cy) return null;
          return { nodes: ctrl.cy.nodes().map((n) => n.id()).sort(), edges: ctrl.cy.edges().length };
        })()
      JS
    end
    page.document.synchronize { graph.call || raise(Capybara::ExpectationNotMet, "graph not rendered yet") }

    expect(graph.call).to eq("nodes" => [ widget.id, router.id ].map(&:to_s).sort, "edges" => 1)
    expect(csp_console_errors).to be_empty
  end
end
