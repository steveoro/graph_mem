# frozen_string_literal: true

require "rails_helper"

# UI-0 (F1): runtime XSS guard — verify the DOM-construction helpers in lib/dom.js
# produce text nodes, not parsed HTML, even when the payload is raw HTML injection.
#
# Strategy: boot Explore (which loads all importmap JS via Stimulus), then
# drive each rendering path via execute_script / evaluate_async_script so we can
# assert against the live DOM without flaky Cytoscape canvas interactions.
#
# Sinks covered:
#   1. Tooltip.show             (graph/tooltip.js)
#   2. ContextMenuManager       (graph/context_menu.js — node header and labels, edge labels)
#   3. DragDropManager menu     (graph/drag_drop_manager.js — labels)
#   4. Explore dialogs and panel (merge dialog and picker, type picker, move card, Recent changes)
#   5. Review page entity autocomplete select (controllers/review_entity_picker_controller.js)
RSpec.describe "XSS escaping in graph UI", type: :system do
  # A payload that, if injected via innerHTML, would create <img data-probe> in the DOM.
  PROBE = "<img src=x data-probe=1>"

  def sign_in_operator!
    ENV["OPERATOR_USERNAME"] = OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    ENV["OPERATOR_PASSWORD"] = OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    visit operator_login_path
    fill_in "username", with: OperatorAuthHelpers::TEST_OPERATOR_USERNAME
    fill_in "password", with: OperatorAuthHelpers::TEST_OPERATOR_PASSWORD
    click_button "Sign in"
    expect(page).to have_current_path(root_path, wait: 5)
  end

  def no_probe!(description)
    probes = page.all("img[data-probe]", visible: :all)
    expect(probes).to be_empty,
      "#{description}: found img[data-probe] in the DOM — payload parsed as HTML (XSS)"
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Sinks 1-3: Explore  (loads all importmap modules via Stimulus)
  # ───────────────────────────────────────────────────────────────────────────
  context "on Explore" do
    before do
      sign_in_operator!
      visit explore_path
      # Wait for Stimulus to boot the explore controller
      expect(page).to have_css('[data-explore-target="canvas"] canvas', wait: 10)
    end

    it "Tooltip does not parse HTML in entity label/type/aliases" do
      page.execute_script(<<~JS)
        (function() {
          const container = document.querySelector('[data-controller="explore"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'explore');
          if (!ctrl || !ctrl.tooltip) return;
          ctrl.tooltip.show(
            { data: function() {
                return {
                  label:                    #{PROBE.to_json},
                  id:                       '1',
                  type:                     #{PROBE.to_json},
                  aliases:                  #{PROBE.to_json},
                  memory_observations_count: 3
                };
              }
            },
            { x: 50, y: 50 },
            { left: 0, top: 0 }
          );
        })();
      JS
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("tooltip")
    end

    it "ContextMenuManager does not parse HTML in node header and labels" do
      page.execute_script(<<~JS)
        (function() {
          const container = document.querySelector('[data-controller="explore"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'explore');
          if (!ctrl || !ctrl.contextMenu) return;
          ctrl.contextMenu.showNodeMenu({
            target: { data: function() {
                return {
                  label:                    #{PROBE.to_json},
                  id:                       '1',
                  type:                     #{PROBE.to_json},
                  aliases:                  #{PROBE.to_json},
                  memory_observations_count: 2
                };
              }
            },
            renderedPosition: { x: 100, y: 100 },
            position:         { x: 100, y: 100 }
          }, {
            container: function() { return document.createElement('div'); }
          });
        })();
      JS
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("context menu")
    end

    it "ContextMenuManager does not parse HTML in edge endpoints and type" do
      page.execute_script(<<~JS)
        (function() {
          const container = document.querySelector('[data-controller="explore"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'explore');
          ctrl.contextMenu.showEdgeMenu({
            target: { data: function() {
                return { from_entity_name: #{PROBE.to_json}, to_entity_name: #{PROBE.to_json}, label: #{PROBE.to_json}, relation_id: 1 };
              }
            },
            renderedPosition: { x: 100, y: 100 }
          }, { container: function() { return document.createElement('div'); } });
        })();
      JS
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("edge menu")
    end

    it "DragDropManager's drop menu does not parse HTML in node labels" do
      page.execute_script(<<~JS)
        (function() {
          const container = document.querySelector('[data-controller="explore"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'explore');
          const fake = (id) => ({
            data: function() { return { id: id, label: #{PROBE.to_json}, type: 'Component' }; },
            renderedPosition: function() { return { x: 50, y: 50 }; },
            scratch: function() { return null; }
          });
          ctrl.dragDrop.showMenu(fake('1'), fake('2'));
        })();
      JS
      expect(page).to have_css("[data-testid='explore-drop-menu']", text: PROBE, wait: 2)
      no_probe!("drop menu")
      page.execute_script("document.querySelectorAll('.node-action-menu').forEach(n => n.remove())")
    end
  end

  # Explore's server-rendered dialogs and the panel's Recent changes (Haml escapes; no html_safe).
  context "in Explore's dialogs and panel" do
    let!(:probe_a) { MemoryEntity.create!(name: "#{PROBE} A", entity_type: "Component", aliases: PROBE) }
    let!(:probe_b) { MemoryEntity.create!(name: "#{PROBE} B", entity_type: "Component") }

    before do
      MemoryObservation.create!(memory_entity: probe_a, content: PROBE)
      MemoryRelation.create!(from_entity: probe_a, to_entity: probe_b, relation_type: "relates_to")
      ChangeSet.record(kind: "explore.entity_edit", subject: probe_a, summary: "edited '#{PROBE}'") { probe_a.update!(description: PROBE) }
      sign_in_operator!
    end

    {
      "the merge dialog" => -> { new_explore_merge_path(source_id: probe_a.id, target_id: probe_b.id) },
      "the merge picker" => -> { new_explore_merge_path(source_id: probe_a.id, q: "img") },
      "the type picker" => -> { new_explore_relation_path(from_id: probe_a.id, to_id: probe_b.id) },
      "the move card" => -> { new_explore_move_path(node_id: probe_a.id, parent_id: probe_b.id) },
      "the panel and its Recent changes" => -> { entity_panel_path(probe_a) }
    }.each do |label, path|
      it "renders names, aliases, observations and summaries as text in #{label}" do
        visit instance_exec(&path)

        expect(page).to have_text(PROBE)
        no_probe!(label)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Sink 5: Review page autocomplete (entity search select)
  # ───────────────────────────────────────────────────────────────────────────
  context "on the review page" do
    let!(:review_row) do
      MaintenanceReportRow.create!(
        report_type: "compaction_review",
        row_uuid:    SecureRandom.uuid,
        kind:        "entity_merge",
        status:      "active",
        signature:   "probe-sig-#{SecureRandom.hex(4)}",
        payload:     {
          "entity_a" => { "entity_id" => 0, "name" => "Alpha" },
          "entity_b" => { "entity_id" => 0, "name" => "Beta" }
        }
      )
    end

    before do
      sign_in_operator!
      # Intercept the entity-search fetch BEFORE visiting the page so the mock
      # is in place when the search fires.
      # The edit fields live in the row's detail pane: open its group, then the row.
      visit review_path(view: "kind")
      click_link "Review", match: :first, exact: true
      find("##{ActionView::RecordIdentifier.dom_id(review_row)} .review-row__open", wait: 5).click
      expect(page).to have_css('[data-controller="review-entity-picker"]', wait: 5)
      # Install a fetch spy that returns a probe entity name
      page.execute_script(<<~JS)
        window._origFetch = window.fetch;
        window.fetch = function(url, opts) {
          if (url && url.includes('entity_search')) {
            return Promise.resolve({
              ok: true,
              json: function() {
                return Promise.resolve({
                  entities: [{
                    id:          999,
                    name:        #{PROBE.to_json},
                    entity_type: #{PROBE.to_json}
                  }]
                });
              }
            });
          }
          return window._origFetch.apply(this, arguments);
        };
      JS
    end

    after do
      page.execute_script("window.fetch = window._origFetch;")
    end

    it "search autocomplete does not parse HTML in entity name returned by the API" do
      # Find the first search input rendered for our review row
      search_input = first("input[data-action*='searchEntity']", wait: 5)
      search_input.fill_in with: "prob"
      # Wait for debounce (200 ms) + promise resolution
      sleep 0.5
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("review autocomplete")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Sink 7: Search results, snippets and the entity panel (UI-3)
  # ───────────────────────────────────────────────────────────────────────────
  context "on the search page" do
    let!(:probe_entity) { MemoryEntity.create!(name: "Synth #{PROBE}", entity_type: "Component", aliases: PROBE, description: PROBE) }

    before do
      MemoryObservation.create!(memory_entity: probe_entity, content: "synth #{PROBE} tiles")
      sign_in_operator!
    end

    it "shows names, snippets and the panel as text, with only <mark> added" do
      visit search_path(q: "synth tiles")
      expect(page).to have_css("[data-testid='search-snippet'] mark", text: "synth")
      expect(page).to have_text(PROBE)
      no_probe!("search results")

      click_link "Synth #{PROBE}"
      expect(page).to have_css("turbo-frame#entity-panel h2", text: "Synth #{PROBE}")
      no_probe!("entity panel")
    end
  end
end
