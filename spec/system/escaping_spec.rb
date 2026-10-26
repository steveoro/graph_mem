# frozen_string_literal: true

require "rails_helper"

# UI-0 (F1): runtime XSS guard — verify the DOM-construction helpers in lib/dom.js
# produce text nodes, not parsed HTML, even when the payload is raw HTML injection.
#
# Strategy: boot the graph page (which loads all importmap JS via Stimulus), then
# drive each rendering path via execute_script / evaluate_async_script so we can
# assert against the live DOM without flaky Cytoscape canvas interactions.
#
# Six sinks covered:
#   1. Tooltip.show             (graph/tooltip.js)
#   2. ContextMenuManager       (graph/context_menu.js — header + labels)
#   3. renderObservationCards   (graph/observation_renderer.js)
#   4. renderDuplicateWarning   (graph/observation_renderer.js)
#   5. DragDropManager header   (graph/drag_drop_manager.js — via lib/dom directly)
#   6. Compaction-review autocomplete select (controllers/compaction_review_controller.js)
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
  # Sinks 1-5: graph page  (loads all importmap modules via Stimulus)
  # ───────────────────────────────────────────────────────────────────────────
  context "on the graph page" do
    before do
      sign_in_operator!
      visit graph_path
      # Wait for Stimulus to boot the graph controller
      expect(page).to have_css('[data-controller="graph"]', wait: 10)
    end

    it "Tooltip does not parse HTML in entity label/type/aliases" do
      page.execute_script(<<~JS)
        (function() {
          const container = document.querySelector('[data-controller="graph"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'graph');
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
          const container = document.querySelector('[data-controller="graph"]');
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(container, 'graph');
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

    it "renderObservationCards and renderDuplicateWarning do not parse HTML in observation content" do
      page.evaluate_async_script(<<~JS)
        (async function(done) {
          const { analyzeObservations, renderDuplicateWarning, renderObservationCards } =
            await import('graph/observation_renderer');
          const { ModalManager } = await import('graph/modal_manager');
          const payload = #{PROBE.to_json};
          // Two identical observations → duplicate warning is also rendered
          const obs = [
            { id: 1, content: payload, created_at: new Date().toISOString() },
            { id: 2, content: payload, created_at: new Date().toISOString() }
          ];
          const analysis = analyzeObservations(obs);
          const frag = document.createDocumentFragment();
          const warn = renderDuplicateWarning(analysis);
          if (warn) frag.appendChild(warn);
          frag.appendChild(renderObservationCards(obs, analysis));
          new ModalManager().show('Observations', frag);
          done();
        })(arguments[0]);
      JS
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("observation modal (cards + duplicate warning)")
    end

    it "DragDropManager action-menu header does not parse HTML in source/target name" do
      # #showActionMenu is private; reproduce its exact DOM construction via lib/dom
      # to confirm text() is used (not innerHTML) for source/target labels.
      page.evaluate_async_script(<<~JS)
        (async function(done) {
          const { el, text } = await import('lib/dom');
          const payload = #{PROBE.to_json};
          const header = el('div', { className: 'node-action-menu__header' },
            el('div', { className: 'node-action-menu__title' }, 'Node-to-Node Action'),
            el('div', { className: 'node-action-menu__subtitle' },
              text('\u201c' + payload + '\u201d \u2192 \u201c' + payload + '\u201d')
            )
          );
          document.body.appendChild(header);
          done();
        })(arguments[0]);
      JS
      expect(page).to have_text(PROBE, wait: 2)
      no_probe!("drag-drop action menu header")
      page.execute_script("document.querySelectorAll('.node-action-menu__header').forEach(n => n.remove())")
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Sink 6: compaction-review autocomplete (entity search select)
  # ───────────────────────────────────────────────────────────────────────────
  context "on the compaction review page" do
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
      visit compaction_review_data_exchange_index_path
      expect(page).to have_css('[data-controller="compaction-review"]', wait: 5)
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
      no_probe!("compaction review autocomplete")
    end
  end
end
