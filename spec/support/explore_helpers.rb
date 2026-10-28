# frozen_string_literal: true

# Explore system specs (UI-4b) drive Cytoscape through the controller's public `cy`, because
# canvas drags are flaky headless; a right-click goes to the node's settled screen position.
module ExploreHelpers
  # @param expression [String] JavaScript evaluated with `ctrl` bound to the explore controller
  def explore_js(expression)
    "(() => { const el = document.querySelector('[data-controller=\"explore\"]'); " \
      "const ctrl = el && window.Stimulus.getControllerForElementAndIdentifier(el, 'explore'); return #{expression}; })()"
  end

  # Waits until the canvas shows the node labelled `label` and the layout has stopped moving it.
  # @return [Array(Integer, Integer)] the node's position on screen
  def settled_node_position(label)
    execute_script(explore_js("ctrl && ctrl.canvasTarget.scrollIntoView({ block: 'center' })"))
    script = explore_js(<<~JS.squish)
      (() => { if (!ctrl || !ctrl.cy) return null;
        const node = ctrl.cy.nodes().filter(n => n.data('label') === #{label.to_json})[0];
        if (!node) return null;
        const box = ctrl.canvasTarget.getBoundingClientRect(); const p = node.renderedPosition();
        return [Math.round(box.left + p.x), Math.round(box.top + p.y)]; })()
    JS
    position = nil
    deadline = Time.current + 10
    loop do
      previous = position
      sleep 0.5
      position = evaluate_script(script)
      return position if position && position == previous
      raise "node #{label} never settled" if Time.current > deadline
    end
  end

  # Records every fetch() the page makes (method and URL) in window.__fetches, from the next
  # navigation on. Injected through DevTools, so the page's CSP is untouched.
  def record_fetches!
    page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~'JS')
      window.__fetches = [];
      const original = window.fetch;
      window.fetch = function (input, init) {
        const url = typeof input === "string" ? input : (input && input.url) || String(input);
        const method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
        window.__fetches.push(method + " " + new URL(url, location.href).pathname);
        return original.apply(this, arguments);
      };
    JS
  end

  # @return [Array<String>] "METHOD /path" for each fetch since the page loaded
  def recorded_fetches = evaluate_script("window.__fetches || []")

  # Waits for the canvas to show `count` nodes.
  def wait_for_nodes(count)
    page.document.synchronize do
      shown = evaluate_script(explore_js("ctrl && ctrl.cy ? ctrl.cy.nodes().length : -1"))
      raise Capybara::ExpectationNotMet, "canvas shows #{shown} nodes, not #{count}" unless shown == count
    end
  end

  # Right-clicks the node labelled `label`; returns the menu item texts.
  def node_menu_items(label)
    page.driver.browser.action.move_to_location(*settled_node_position(label)).context_click.perform
    all(".contextual-menu .ctx-item", minimum: 1).map(&:text)
  end
end

RSpec.configure { |config| config.include ExploreHelpers, type: :system }
