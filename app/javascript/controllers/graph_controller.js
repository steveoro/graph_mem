import { Controller } from "@hotwired/stimulus"
import cytoscape from 'cytoscape'

import { GraphApiClient } from "graph/api_client"
import { GRAPH_STYLES, LAYOUT_OPTIONS } from "graph/cytoscape_config"
import { ModalManager } from "graph/modal_manager"
import { Tooltip } from "graph/tooltip"
import { ContextMenuManager } from "graph/context_menu"
import { DragDropManager } from "graph/drag_drop_manager"
import { DataManageManager } from "graph/data_manage"

// Connects to data-controller="graph"
export default class extends Controller {
  static targets = ["container"]

  connect() {
    this.currentView = 'root';
    this.currentEntityId = null;
    this.scopedEntityId = null;

    this.api = new GraphApiClient();
    this.modal = new ModalManager();
    this.tooltip = new Tooltip();

    const refreshCallback = { onRefreshGraph: () => this.refreshGraph() };
    this.contextMenu = new ContextMenuManager(this.api, this.modal, refreshCallback);
    this.dragDrop = new DragDropManager(this.api, this.modal, refreshCallback);
    this.dataManage = new DataManageManager(this.api, this.modal, refreshCallback);

    this.containerTarget.style.position = 'relative';
    this.#addNavigationOverlay();

    const urlParams = new URLSearchParams(window.location.search);
    const scopedId = urlParams.get('scoped_entity_id');
    if (scopedId) {
      this.scopedEntityId = scopedId;
      this.currentView = 'scoped';
      this.#updateNavigationButtons();
      this.fetchDataAndRenderGraph(false, null, { scopedEntityId: scopedId });
    } else {
      this.fetchDataAndRenderGraph(true);
    }
  }

  refreshGraph() {
    if (this.currentView === 'scoped') {
      this.fetchDataAndRenderGraph(false, null, { scopedEntityId: this.scopedEntityId });
    } else {
      this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
    }
  }

  // --- Navigation ---

  #addNavigationOverlay() {
    const existingNav = this.containerTarget.querySelector('.graph-navigation');
    if (existingNav) existingNav.remove();

    const navDiv = document.createElement('div');
    navDiv.className = 'graph-navigation';

    const rootBtn = document.createElement('button');
    rootBtn.textContent = 'Root View';
    rootBtn.className = 'graph-nav-btn graph-nav-btn--active';
    rootBtn.onclick = () => this.#switchView('root');

    const fullBtn = document.createElement('button');
    fullBtn.textContent = 'Full Graph';
    fullBtn.className = 'graph-nav-btn';
    fullBtn.onclick = () => this.#switchView('full');

    const backBtn = document.createElement('button');
    backBtn.textContent = '\u2190 Back to Root';
    backBtn.className = 'graph-nav-btn graph-nav-btn--back graph-hidden';
    backBtn.onclick = () => this.#switchView('root');

    const dataManageBtn = document.createElement('button');
    dataManageBtn.textContent = 'Data Manage';
    dataManageBtn.className = 'graph-nav-btn graph-nav-btn--data-manage';
    dataManageBtn.onclick = () => this.dataManage.show();

    navDiv.appendChild(rootBtn);
    navDiv.appendChild(fullBtn);
    navDiv.appendChild(backBtn);
    navDiv.appendChild(dataManageBtn);
    this.containerTarget.appendChild(navDiv);

    this.navControls = { rootBtn, fullBtn, backBtn };
    this.#updateNavigationButtons();
  }

  #switchView(view, entityId = null) {
    this.currentView = view;
    this.currentEntityId = entityId;
    this.scopedEntityId = null;
    this.#updateNavigationButtons();

    if (view === 'root') {
      this.fetchDataAndRenderGraph(true);
    } else if (view === 'full') {
      this.fetchDataAndRenderGraph(false);
    } else {
      this.fetchDataAndRenderGraph(false, entityId);
    }
  }

  #updateNavigationButtons() {
    const { rootBtn, fullBtn, backBtn } = this.navControls;

    rootBtn.className = 'graph-nav-btn';
    fullBtn.className = 'graph-nav-btn';

    if (this.currentView === 'root') {
      rootBtn.classList.add('graph-nav-btn--active');
      backBtn.classList.add('graph-hidden');
    } else if (this.currentView === 'full') {
      fullBtn.classList.add('graph-nav-btn--active');
      backBtn.classList.add('graph-hidden');
    } else if (this.currentView === 'scoped' || this.currentView === 'subgraph') {
      backBtn.className = 'graph-nav-btn graph-nav-btn--back';
    }
  }

  // --- Data fetching & rendering ---

  async fetchDataAndRenderGraph(rootOnly = false, entityId = null, options = {}) {
    try {
      const graphData = await this.api.fetchGraphData(rootOnly, entityId, options);
      this.#renderGraph(graphData.elements);
    } catch (error) {
      console.error("Could not fetch or render graph data:", error);
      this.containerTarget.innerHTML = "<p class='text-red-500'>Error loading graph. See console for details.</p>";
    }
  }

  #renderGraph(elements) {
    if (!this.containerTarget) return;

    this.tooltip.hide();

    const cy = cytoscape({
      container: this.containerTarget,
      elements: elements,
      style: GRAPH_STYLES,
      layout: LAYOUT_OPTIONS
    });

    this.cy = cy;
    this.#addGraphEventHandlers();

    try {
      const layoutOptions = cy.options().layout;
      if (layoutOptions?.name) {
        cy.layout(layoutOptions).run();
      }
      cy.fit();
      cy.center();
    } catch (e) {
      console.error("Error during graph layout:", e);
      this.containerTarget.innerHTML = "<p class='text-red-500'>Critical error during graph setup. See console.</p>";
    }

    this.dragDrop.initialize(cy, this.containerTarget);
    this.#addNavigationOverlay();
  }

  #addGraphEventHandlers() {
    this.cy.on('mouseover', 'node', (event) => {
      const position = event.renderedPosition || event.position;
      const containerRect = this.containerTarget.getBoundingClientRect();
      this.tooltip.show(event.target, position, containerRect);
    });

    this.cy.on('mouseout', 'node', () => this.tooltip.hide());

    this.cy.on('dblclick', 'node', (event) => {
      if (this.currentView !== 'subgraph') {
        this.#switchView('subgraph', event.target.id());
      }
    });

    this.cy.on('cxttap', 'node', (event) => {
      event.preventDefault();
      this.contextMenu.showNodeMenu(event, this.cy);
    });

    this.cy.on('cxttap', 'edge', (event) => {
      event.preventDefault();
      this.contextMenu.showEdgeMenu(event, this.cy);
    });

    this.cy.on('tap', (event) => {
      if (event.target === this.cy) {
        this.contextMenu.hide();
      }
    });
  }
}
