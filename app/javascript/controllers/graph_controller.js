import { Controller } from "@hotwired/stimulus"
import cytoscape from 'cytoscape';
import { createConsumer } from "@rails/actioncable"

// Connects to data-controller="graph"
export default class extends Controller {
  static targets = [ "container" ]

  connect() {
    console.log("Graph controller connected");
    this.currentView = 'root'; // 'root', 'full', or 'subgraph'
    this.cable = null; // ActionCable consumer
    this.currentEntityId = null;
    this.addNavigationControls();
    this.fetchDataAndRenderGraph(true); // Start with root view
  }

  addNavigationControls() {
    // Make the graph container relative positioned to contain the absolute navigation
    this.containerTarget.style.position = 'relative';

    // Add the initial navigation controls
    this.addNavigationControlsOverlay();
  }

  addNavigationControlsOverlay() {
    // Remove existing navigation if present
    const existingNav = this.containerTarget.querySelector('.graph-navigation');
    if (existingNav) {
      existingNav.remove();
    }

    // Add navigation controls as floating overlay over the graph container
    const navDiv = document.createElement('div');
    navDiv.className = 'graph-navigation';
    navDiv.style.cssText = `
      position: absolute;
      top: 10px;
      left: 10px;
      z-index: 1000;
      padding: 10px;
      background: rgba(245, 245, 245, 0.95);
      border-radius: 5px;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
      backdrop-filter: blur(4px);
    `;

    const rootBtn = document.createElement('button');
    rootBtn.textContent = 'Root View';
    rootBtn.style.cssText = 'margin-right: 10px; padding: 5px 10px; background: #007bff; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 12px;';
    rootBtn.onclick = () => this.switchToRootView();

    const fullBtn = document.createElement('button');
    fullBtn.textContent = 'Full Graph';
    fullBtn.style.cssText = 'margin-right: 10px; padding: 5px 10px; background: #6c757d; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 12px;';
    fullBtn.onclick = () => this.switchToFullView();

    const backBtn = document.createElement('button');
    backBtn.textContent = '← Back to Root';
    backBtn.style.cssText = 'padding: 5px 10px; background: #28a745; color: white; border: none; border-radius: 3px; cursor: pointer; display: none; font-size: 12px;';
    backBtn.onclick = () => this.switchToRootView();

    const dataManageBtn = document.createElement('button');
    dataManageBtn.textContent = 'Data Manage';
    dataManageBtn.style.cssText = 'margin-left: 20px; padding: 5px 10px; background: #17a2b8; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 12px;';
    dataManageBtn.onclick = () => this.showDataManageModal();

    navDiv.appendChild(rootBtn);
    navDiv.appendChild(fullBtn);
    navDiv.appendChild(backBtn);
    navDiv.appendChild(dataManageBtn);

    // Add the navigation as a child of the graph container
    this.containerTarget.appendChild(navDiv);
    this.navControls = { rootBtn, fullBtn, backBtn, dataManageBtn };

    // Update button states based on current view
    this.updateNavigationButtons();
  }

  switchToRootView() {
    this.currentView = 'root';
    this.currentEntityId = null;
    this.updateNavigationButtons();
    this.fetchDataAndRenderGraph(true);
  }

  switchToFullView() {
    this.currentView = 'full';
    this.currentEntityId = null;
    this.updateNavigationButtons();
    this.fetchDataAndRenderGraph(false);
  }

  switchToSubgraphView(entityId) {
    this.currentView = 'subgraph';
    this.currentEntityId = entityId;
    this.updateNavigationButtons();
    this.fetchDataAndRenderGraph(false, entityId);
  }

  updateNavigationButtons() {
    const { rootBtn, fullBtn, backBtn } = this.navControls;

    // Reset all buttons
    [rootBtn, fullBtn].forEach(btn => {
      btn.style.background = '#6c757d';
    });

    // Highlight current view
    if (this.currentView === 'root') {
      rootBtn.style.background = '#007bff';
      backBtn.style.display = 'none';
    } else if (this.currentView === 'full') {
      fullBtn.style.background = '#007bff';
      backBtn.style.display = 'none';
    } else if (this.currentView === 'subgraph') {
      backBtn.style.display = 'inline-block';
    }
  }

  async fetchDataAndRenderGraph(rootOnly = false, entityId = null) {
    try {
      let url = '/api/v1/graph_data';
      const params = new URLSearchParams();

      if (entityId) {
        params.append('entity_id', entityId);
      } else if (rootOnly) {
        params.append('root_only', 'true');
      }

      if (params.toString()) {
        url += '?' + params.toString();
      }

      const response = await fetch(url);
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      const graphData = await response.json();
      console.log("Graph data fetched:", graphData);

      this.renderGraph(graphData.elements);
    } catch (error) {
      console.error("Could not fetch or render graph data:", error);
      this.containerTarget.innerHTML = "<p class='text-red-500'>Error loading graph. See console for details.</p>";
    }
  }

  getCSRFToken() {
    const token = document.querySelector('meta[name="csrf-token"]');
    return token ? token.content : null;
  }

  renderGraph(elements) {
    if (!this.containerTarget) {
      console.error("Graph container target not found!");
      return;
    }

    // Remove existing tooltip if any
    this.removeTooltip();

    const cy = cytoscape({
      container: this.containerTarget,
      elements: elements,
      style: [
        {
          selector: 'node',
          style: {
            'background-color': '#666',
            'label': 'data(label)',
            'padding': '10px',
            'shape': 'round-rectangle',
            'text-valign': 'center',
            'text-halign': 'center',
            'font-size': '10px',
            'color': '#fff',
            'text-outline-width': 2,
            'text-outline-color': '#666'
          }
        },
        {
          selector: 'node:hover',
          style: {
            'border-width': 3,
            'border-color': '#fff',
            'border-opacity': 0.8
          }
        },
        {
          selector: 'edge',
          style: {
            'width': 2,
            'line-color': '#ccc',
            'target-arrow-color': '#ccc',
            'target-arrow-shape': 'triangle',
            'curve-style': 'bezier',
            'label': 'data(label)',
            'font-size': '8px',
            'color': '#555',
            'text-rotation': 'autorotate',
            'text-margin-y': -10
          }
        },
        {
          selector: 'node[type="Project"]',
          style: {
            'background-color': '#f96',
            'text-outline-color': '#f96'
          }
        },
        {
          selector: 'node[type="Task"]',
          style: {
            'background-color': '#9cf',
            'text-outline-color': '#9cf'
          }
        },
        {
          selector: 'node[type="Issue"]',
          style: {
            'background-color': '#f66',
            'text-outline-color': '#f66'
          }
        },
        {
          selector: 'node[is_focus="true"]',
          style: {
            'border-width': 4,
            'border-color': '#ffff00',
            'border-opacity': 1
          }
        },
        {
          selector: 'node.potential-drop-target',
          style: {
            'border-width': 3,
            'border-color': '#28a745',
            'border-opacity': 0.8,
            'background-opacity': 0.8
          }
        }
      ],
      layout: {
        name: 'cose', // cose (Compound Spring Embedder) is good for general purpose layout
        idealEdgeLength: 100,
        nodeOverlap: 20,
        refresh: 20,
        fit: true,
        padding: 30,
        randomize: false,
        componentSpacing: 100,
        nodeRepulsion: 400000,
        edgeElasticity: 100,
        nestingFactor: 5,
        gravity: 80,
        numIter: 1000,
        initialTemp: 200,
        coolingFactor: 0.95,
        minTemp: 1.0,
        animateFilter: function ( node, i ){ return true; },
        animationDuration: 500,
        animationEasing: undefined,
        animate: true,
        fit: true,
        selectionType: 'single',
        wheelSensitivity: 0.1,
        padding: 30
      }
    });
    console.log("Cytoscape instance created:", cy);
    this.cy = cy; // Store instance for later use
    console.log("this.cy assigned.");

    // Add event handlers
    this.addGraphEventHandlers();

    try {
      // DEBUG
      // console.log("Attempting to access cy.nodes() and cy.edges()...");
      // console.log(`Cytoscape processed ${this.cy.nodes().length} nodes and ${this.cy.edges().length} edges.`);
      console.log("Successfully accessed node and edge counts.");

      // Ensure layout is applied and graph is visible
      console.log("Attempting to apply layout...");
      const layoutOptions = this.cy.options().layout;
      if (layoutOptions && layoutOptions.name) {
        const layout = this.cy.layout(layoutOptions);
        layout.run();
        this.cy.fit();
        this.cy.center();
        console.log("Layout run, graph fitted and centered.");
      } else {
        console.warn("Layout options not found or layout name missing, skipping explicit layout run.");
        // Fallback or default fit/center if layout is problematic
        this.cy.fit();
        this.cy.center();
        console.log("Fallback fit and center applied.");
      }
    } catch (e) {
      console.error("Error after assigning this.cy and before initializing listeners:", e);
      this.containerTarget.innerHTML = "<p class='text-red-500'>Critical error during graph setup after instance creation. See console.</p>";
    }

    this.initializeDragAndDropListeners();

    // Re-add navigation controls after graph render (they get removed when container is replaced)
    this.addNavigationControlsOverlay();
  }

  addGraphEventHandlers() {
    // Mouse hover for tooltips
    this.cy.on('mouseover', 'node', (event) => {
      this.showNodeTooltip(event);
    });

    this.cy.on('mouseout', 'node', (event) => {
      this.hideNodeTooltip();
    });

    // Double-click for zoom-in (subgraph view)
    this.cy.on('dblclick', 'node', (event) => {
      const nodeId = event.target.id();
      if (this.currentView !== 'subgraph') {
        this.switchToSubgraphView(nodeId);
      }
    });

    // Right-click for contextual menu
    this.cy.on('cxttap', 'node', (event) => {
      event.preventDefault();
      this.showContextualMenu(event);
    });

    // Click elsewhere to hide contextual menu
    this.cy.on('tap', (event) => {
      if (event.target === this.cy) {
        this.hideContextualMenu();
      }
    });
  }

  showNodeTooltip(event) {
    const node = event.target;
    const data = node.data();
    const position = event.renderedPosition || event.position;

    this.removeTooltip();

    const tooltip = document.createElement('div');
    tooltip.className = 'node-tooltip';
    tooltip.style.cssText = `
      position: absolute;
      background: rgba(0,0,0,0.8);
      color: white;
      padding: 8px 12px;
      border-radius: 4px;
      font-size: 12px;
      pointer-events: none;
      z-index: 1000;
      max-width: 200px;
      word-wrap: break-word;
    `;

    const aliases = data.aliases ? data.aliases.trim() : '';
    tooltip.innerHTML = `
      <strong>${data.label}</strong><br>
      ID: ${data.id}<br>
      Type: ${data.type || 'N/A'}<br>
      ${aliases ? `Aliases: ${aliases}<br>` : ''}
      Observations: ${data.memory_observations_count || 0}
    `;

    // Position tooltip near the mouse
    const containerRect = this.containerTarget.getBoundingClientRect();
    tooltip.style.left = (containerRect.left + position.x + 10) + 'px';
    tooltip.style.top = (containerRect.top + position.y - 10) + 'px';

    document.body.appendChild(tooltip);
    this.currentTooltip = tooltip;
  }

  hideNodeTooltip() {
    this.removeTooltip();
  }

  removeTooltip() {
    if (this.currentTooltip) {
      this.currentTooltip.remove();
      this.currentTooltip = null;
    }
  }

  showContextualMenu(event) {
    const node = event.target;
    const data = node.data();
    const position = event.renderedPosition || event.position;

    this.hideContextualMenu();

    const menu = document.createElement('div');
    menu.className = 'contextual-menu';
    menu.style.cssText = `
      position: absolute;
      background: white;
      border: 1px solid #ccc;
      border-radius: 4px;
      box-shadow: 0 2px 10px rgba(0,0,0,0.1);
      z-index: 1001;
      min-width: 180px;
      font-size: 12px;
    `;

    const aliases = data.aliases ? data.aliases.trim() : '';
    const menuItems = [
      { text: `<strong>${data.label}</strong>`, divider: true },
      { text: `ID: ${data.id}` },
      { text: `Type: ${data.type || 'N/A'}` },
      ...(aliases ? [{ text: `Aliases: ${aliases}` }] : []),
      { text: `Observations: ${data.memory_observations_count || 0}`, clickable: true, action: 'show-observations' },
      { divider: true },
      { text: 'Edit data', action: 'edit' },
      { text: 'Toggle relations', action: 'toggle-relations' },
      { text: 'Toggle observations', action: 'toggle-observations' },
      { text: 'Delete', action: 'delete', danger: true }
    ];

    menuItems.forEach(item => {
      const menuItem = document.createElement('div');
      if (item.divider) {
        menuItem.style.cssText = 'border-top: 1px solid #eee; margin: 4px 0;';
        if (item.text) {
          menuItem.innerHTML = item.text;
          menuItem.style.cssText += 'padding: 6px 12px; font-weight: bold;';
        }
      } else {
        menuItem.innerHTML = item.text;
        menuItem.style.cssText = `
          padding: 6px 12px;
          cursor: ${item.clickable || item.action ? 'pointer' : 'default'};
          ${item.danger ? 'color: #dc3545;' : ''}
        `;

        if (item.clickable || item.action) {
          menuItem.style.cssText += 'hover: background-color: #f8f9fa;';
          menuItem.onmouseover = () => menuItem.style.backgroundColor = '#f8f9fa';
          menuItem.onmouseout = () => menuItem.style.backgroundColor = 'transparent';

          menuItem.onclick = (e) => {
            e.stopPropagation();
            this.handleContextualMenuAction(item.action, data);
            this.hideContextualMenu();
          };
        }
      }
      menu.appendChild(menuItem);
    });

    // Position menu near the click
    const containerRect = this.containerTarget.getBoundingClientRect();
    menu.style.left = (containerRect.left + position.x) + 'px';
    menu.style.top = (containerRect.top + position.y) + 'px';

    document.body.appendChild(menu);
    this.currentContextualMenu = menu;
  }

  hideContextualMenu() {
    if (this.currentContextualMenu) {
      this.currentContextualMenu.remove();
      this.currentContextualMenu = null;
    }
  }

  async handleContextualMenuAction(action, nodeData) {
    switch (action) {
      case 'show-observations':
        this.showObservationsModal(nodeData);
        break;
      case 'edit':
        this.showEditModal(nodeData);
        break;
      case 'toggle-relations':
        this.toggleNodeRelations(nodeData.id);
        break;
      case 'toggle-observations':
        this.toggleNodeObservations(nodeData);
        break;
      case 'delete':
        this.deleteNode(nodeData);
        break;
    }
  }

  async showObservationsModal(nodeData) {
    try {
      const response = await fetch(`/api/v1/memory_entities/${nodeData.id}/memory_observations`);
      if (!response.ok) throw new Error('Failed to fetch observations');

      const observations = await response.json();
      
      // Check if there are duplicates (same content)
      const contentCounts = {};
      observations.forEach(obs => {
        contentCounts[obs.content] = (contentCounts[obs.content] || 0) + 1;
      });
      const hasDuplicates = Object.values(contentCounts).some(count => count > 1);
      const duplicateCount = Object.values(contentCounts).reduce((sum, count) => sum + (count > 1 ? count - 1 : 0), 0);

      this.showModal('Entity Observations', `
        <h3>${nodeData.label} (ID: ${nodeData.id})</h3>
        <p><strong>Type:</strong> ${nodeData.type || 'N/A'}</p>
        <p><strong>Total Observations:</strong> ${observations.length}</p>
        ${hasDuplicates ? `
          <div style="margin: 10px 0; padding: 10px; background: #fff3cd; border: 1px solid #ffeaa7; border-radius: 4px;">
            <p style="margin: 0 0 10px 0; color: #856404;"><strong>⚠️ Found ${duplicateCount} duplicate observation(s)</strong></p>
            <button onclick="window.graphController.deleteDuplicateObservations(${nodeData.id})" 
                    style="padding: 6px 12px; background: #dc3545; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 12px;">
              🗑️ Delete All Duplicates
            </button>
          </div>
        ` : ''}
        <hr>
        ${observations.length > 0 ?
          observations
            .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
            .map(obs => {
              const isDuplicate = contentCounts[obs.content] > 1;
              return `
                <div style="margin-bottom: 10px; padding: 8px; background: ${isDuplicate ? '#ffe6e6' : '#f8f9fa'}; border-radius: 4px; ${isDuplicate ? 'border-left: 3px solid #dc3545;' : ''}">
                  <div style="font-size: 11px; color: #666; margin-bottom: 4px;">
                    ${new Date(obs.created_at).toLocaleString()}
                    ${isDuplicate ? '<span style="color: #dc3545; font-weight: bold; margin-left: 8px;">[DUPLICATE]</span>' : ''}
                  </div>
                  <div>${obs.content}</div>
                </div>
              `;
            }).join('')
          : '<p>No observations found.</p>'
        }
      `);
    } catch (error) {
      console.error('Error fetching observations:', error);
      alert('Failed to load observations.');
    }
  }

  showEditModal(nodeData) {
    const aliases = nodeData.aliases ? nodeData.aliases.trim() : '';
    const content = `
      <h3>Edit Entity</h3>
      <form id="edit-entity-form">
        <div style="margin-bottom: 10px;">
          <label style="display: block; margin-bottom: 4px;">Name:</label>
          <input type="text" id="entity-name" value="${nodeData.label}"
                 style="width: 100%; padding: 6px; border: 1px solid #ccc; border-radius: 3px;">
        </div>
        <div style="margin-bottom: 10px;">
          <label style="display: block; margin-bottom: 4px;">Type:</label>
          <input type="text" id="entity-type" value="${nodeData.type || ''}"
                 style="width: 100%; padding: 6px; border: 1px solid #ccc; border-radius: 3px;">
        </div>
        <div style="margin-bottom: 15px;">
          <label style="display: block; margin-bottom: 4px;">Aliases:</label>
          <input type="text" id="entity-aliases" value="${aliases}"
                 placeholder="Comma-separated alternative names"
                 style="width: 100%; padding: 6px; border: 1px solid #ccc; border-radius: 3px;">
          <small style="color: #666; font-size: 11px;">Enter alternative names separated by commas</small>
        </div>
        <div style="text-align: right;">
          <button type="button" onclick="window.graphController.closeModal()"
                  style="margin-right: 10px; padding: 6px 12px; background: #6c757d; color: white; border: none; border-radius: 3px; cursor: pointer;">Cancel</button>
          <button type="submit"
                  style="padding: 6px 12px; background: #007bff; color: white; border: none; border-radius: 3px; cursor: pointer;">Save</button>
        </div>
      </form>
    `;

    this.showModal('Edit Entity', content);

    // Handle form submission
    document.getElementById('edit-entity-form').onsubmit = async (e) => {
      e.preventDefault();
      const name = document.getElementById('entity-name').value.trim();
      const type = document.getElementById('entity-type').value.trim();
      const aliases = document.getElementById('entity-aliases').value.trim();

      if (!name) {
        alert('Name is required.');
        return;
      }

      await this.updateEntity(nodeData.id, { name, entity_type: type, aliases });
    };
  }

  async updateEntity(entityId, data) {
    try {
      const csrfToken = this.getCSRFToken();
      const response = await fetch(`/api/v1/memory_entities/${entityId}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify({ memory_entity: data })
      });

      if (response.ok) {
        this.closeModal();
        // Refresh the graph
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
        alert('Entity updated successfully.');
      } else {
        const error = await response.json();
        alert(`Failed to update entity: ${error.message || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Error updating entity:', error);
      alert('An error occurred while updating the entity.');
    }
  }

  toggleNodeRelations(nodeId) {
    const node = this.cy.$id(nodeId);
    const connectedEdges = node.connectedEdges();
    const connectedNodes = node.neighborhood().nodes();

    if (connectedEdges.hasClass('hidden-relation')) {
      // Show relations
      connectedEdges.removeClass('hidden-relation').show();
      connectedNodes.removeClass('hidden-relation').show();
    } else {
      // Hide relations
      connectedEdges.addClass('hidden-relation').hide();
      connectedNodes.addClass('hidden-relation').hide();
    }
  }

  async toggleNodeObservations(nodeData) {
    if (nodeData.memory_observations_count > 10) {
      if (!confirm(`This entity has ${nodeData.memory_observations_count} observations. Show them all?`)) {
        return;
      }
    }

    // For now, just show the observations modal
    // In a full implementation, you might add observation nodes to the graph
    this.showObservationsModal(nodeData);
  }

  async deleteNode(nodeData) {
    if (!confirm(`Are you sure you want to delete "${nodeData.label}"? This action cannot be undone.`)) {
      return;
    }

    try {
      const csrfToken = this.getCSRFToken();
      const response = await fetch(`/api/v1/memory_entities/${nodeData.id}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': csrfToken
        }
      });

      if (response.ok) {
        // Remove from graph
        this.cy.$id(nodeData.id).remove();
        alert('Entity deleted successfully.');
      } else {
        const error = await response.json();
        alert(`Failed to delete entity: ${error.message || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Error deleting entity:', error);
      alert('An error occurred while deleting the entity.');
    }
  }

  showModal(title, content) {
    // Remove existing modal
    this.closeModal();

    const overlay = document.createElement('div');
    overlay.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: rgba(0,0,0,0.5);
      z-index: 2000;
      display: flex;
      align-items: center;
      justify-content: center;
    `;

    const modal = document.createElement('div');
    modal.style.cssText = `
      background: white;
      border-radius: 8px;
      padding: 20px;
      max-width: '80%';
      max-height: 80vh;
      overflow-y: auto;
      position: relative;
    `;

    const closeBtn = document.createElement('button');
    closeBtn.innerHTML = '×';
    closeBtn.style.cssText = `
      position: absolute;
      top: 10px;
      right: 15px;
      background: none;
      border: none;
      font-size: 24px;
      cursor: pointer;
      color: #666;
    `;
    closeBtn.onclick = () => this.closeModal();

    modal.innerHTML = `<h2>${title}</h2>${content}`;
    modal.appendChild(closeBtn);
    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    this.currentModal = overlay;
    window.graphController = this; // For form callbacks
  }

  closeModal() {
    if (this.currentModal) {
      this.currentModal.remove();
      this.currentModal = null;
    }
  }

  initializeDragAndDropListeners() {
    if (!this.cy) return;

    // Listen for when a node starts being dragged
    this.cy.on('grab', 'node', (event) => {
      const node = event.target;
      // Store original position for potential reset
      node.data('originalPosition', {
        x: node.position('x'),
        y: node.position('y')
      });
      console.log('Node grab started:', node.id());
    });

    // Listen for when a node stops being dragged
    this.cy.on('free', 'node', (event) => {
      this.handleNodeDrop(event);
    });

    // Listen for when a node is being dragged over another node
    this.cy.on('dragover', 'node', (event) => {
      const nodeOver = event.target;
      // Add visual feedback for potential drop target
      nodeOver.addClass('potential-drop-target');
    });

    // Listen for when a node is no longer being dragged over another node
    this.cy.on('dragout', 'node', (event) => {
      const nodeOut = event.target;
      // Remove visual feedback
      nodeOut.removeClass('potential-drop-target');
    });
  }

  handleNodeDrop(event) {
    const draggedNode = event.target;
    const draggedNodePosition = draggedNode.position();
    let targetFound = null;

    console.log("handleNodeDrop:", event);
    console.debug("Dragged node:", draggedNode.id(), draggedNode.data('label'));

    this.cy.nodes().not(draggedNode).forEach((potentialTargetNode) => {
      if (targetFound) return; // Already found a target

      const targetBB = potentialTargetNode.renderedBoundingBox();
      const draggedBB = draggedNode.renderedBoundingBox();

      console.debug(`Checking overlap with ${potentialTargetNode.id()}:`);
      console.debug(`  Dragged BB:`, draggedBB);
      console.debug(`  Target BB:`, targetBB);

      // Check for overlap using bounding boxes
      const isOverlapping = (
        draggedBB.x1 < targetBB.x2 &&
        draggedBB.x2 > targetBB.x1 &&
        draggedBB.y1 < targetBB.y2 &&
        draggedBB.y2 > targetBB.y1
      );

      console.debug(`  Is overlapping:`, isOverlapping);

      if (isOverlapping) {
        console.debug(`  TARGET FOUND:`, potentialTargetNode.id());
        targetFound = potentialTargetNode;
      }
    });

    console.debug("Final targetFound:", targetFound ? targetFound.id() : 'null');

    if (targetFound) {
      // Show node-to-node action popup when a node is dropped onto another
      const sourceId = draggedNode.id();
      const targetId = targetFound.id();
      const sourceName = draggedNode.data('label') || sourceId;
      const targetName = targetFound.data('label') || targetId;
      const sourceType = draggedNode.data('type');
      const targetType = targetFound.data('type');

      // Show popup menu for node-to-node actions
      // Get position from event or fallback to target node position
      const dropPosition = event.renderedPosition || event.position || targetFound.renderedPosition() || {
        x: window.innerWidth / 2,
        y: window.innerHeight / 2
      };

      this.showNodeToNodeActionMenu({
        sourceId,
        targetId,
        sourceName,
        targetName,
        sourceType,
        targetType,
        draggedNode,
        targetNode: targetFound,
        dropPosition
      });
    } else {
      // If not dropped on another node, allow normal positioning
      console.log("Node dropped in empty space. Normal repositioning.");
    }
  }

  async mergeEntities(sourceId, targetId, targetName = null) {
    console.log(`Attempting to merge ${sourceId} into ${targetId}`);
    const csrfToken = this.getCSRFToken();
    if (!csrfToken) {
      console.error("CSRF token not found. Merge aborted.");
      alert("Error: CSRF token not found. Cannot perform merge.");
      return;
    }

    try {
      // First, add target name as alias to source entity if provided
      if (targetName) {
        await this.addTargetNameAsAlias(sourceId, targetName);
      }

      const response = await fetch(`/api/v1/memory_entities/${sourceId}/merge_into/${targetId}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        // No body needed as IDs are in the URL
      });

      if (response.status === 204) { // No Content - Success
        console.log(`Successfully merged ${sourceId} into ${targetId}.`);
        if (this.cy) {
          const sourceNode = this.cy.$id(sourceId);
          if (sourceNode.length > 0) {
            this.cy.remove(sourceNode);
            console.log(`Node ${sourceId} removed from graph.`);
          } else {
            console.warn(`Node ${sourceId} not found in graph after merge for removal.`);
          }
          // For a more complete update, you might re-fetch all data:
          // this.fetchDataAndRenderGraph();
        }
        alert(`'${sourceId}' merged into '${targetId}'.`);
      } else {
        const errorData = await response.json().catch(() => ({ message: 'Unknown error during merge.' }));
        console.error(`Failed to merge entities: ${response.status}`, errorData);
        alert(`Failed to merge: ${errorData.error || errorData.message || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Error during mergeEntities API call:', error);
      alert(`An error occurred while trying to merge: ${error.message}`);
    }
  }

  showNodeToNodeActionMenu(actionData) {
    const {
      sourceId, targetId, sourceName, targetName, sourceType, targetType,
      draggedNode, targetNode, dropPosition
    } = actionData;

    // Remove any existing node-to-node menu
    this.hideNodeToNodeActionMenu();

    const menu = document.createElement('div');
    menu.className = 'node-to-node-action-menu';
    menu.style.cssText = `
      position: absolute;
      background: white;
      border: 2px solid #007bff;
      border-radius: 8px;
      box-shadow: 0 4px 16px rgba(0,0,0,0.2);
      z-index: 1002;
      min-width: 220px;
      font-size: 13px;
      padding: 8px 0;
    `;

    // Header showing the action context
    const header = document.createElement('div');
    header.style.cssText = 'padding: 8px 12px; background: #f8f9fa; border-bottom: 1px solid #dee2e6; font-weight: bold; color: #495057;';
    header.innerHTML = `
      <div style="font-size: 12px; margin-bottom: 4px;">Node-to-Node Action</div>
      <div style="font-size: 11px; color: #6c757d;">
        "${sourceName}" → "${targetName}"
      </div>
    `;
    menu.appendChild(header);

    // Check if types match for merge operation
    const typesMatch = (sourceType === targetType) ||
                      (!sourceType && !targetType) ||
                      (sourceType === null && targetType === null);
    // DEBUG:
    console.debug("typesMatch:", typesMatch);
    console.debug("sourceType:", sourceType);
    console.debug("targetType:", targetType);

    const actions = [
      {
        text: 'Merge Nodes',
        description: 'Merge source into target (preserves target name as alias)',
        action: 'merge',
        enabled: typesMatch,
        icon: '🔗',
        disabledReason: typesMatch ? null : `Cannot merge different types: "${sourceType || 'N/A'}" ≠ "${targetType || 'N/A'}"`
      },
      {
        text: 'Create Relation',
        description: 'Create a relationship between the nodes',
        action: 'create-relation',
        enabled: true,
        icon: '→'
      },
      {
        text: 'Cancel',
        description: 'Return source node to original position',
        action: 'cancel',
        enabled: true,
        icon: '✕',
        cancel: true
      }
    ];

    actions.forEach((actionItem, index) => {
      console.debug(`Creating menu item ${index}:`, actionItem);
      const menuItem = document.createElement('div');
      const isEnabled = actionItem.enabled;
      const isCancel = actionItem.cancel;

      console.debug(`Menu item ${index} - enabled: ${isEnabled}, action: ${actionItem.action}`);

      menuItem.style.cssText = `
        padding: 8px 12px;
        cursor: ${isEnabled ? 'pointer' : 'not-allowed'};
        opacity: ${isEnabled ? '1' : '0.5'};
        ${isCancel ? 'border-top: 1px solid #dee2e6; margin-top: 4px;' : ''}
        ${isCancel ? 'background: #f8f9fa;' : ''}
      `;

      menuItem.innerHTML = `
        <div style="display: flex; align-items: center; margin-bottom: 2px;">
          <span style="margin-right: 8px; font-size: 14px;">${actionItem.icon}</span>
          <span style="font-weight: ${isCancel ? 'normal' : '500'};">${actionItem.text}</span>
        </div>
        <div style="font-size: 11px; color: #6c757d; margin-left: 22px;">
          ${actionItem.disabledReason || actionItem.description}
        </div>
      `;

      if (isEnabled) {
        console.debug(`Attaching event handlers to menu item ${index} (${actionItem.action})`);

        menuItem.onmouseover = () => {
          if (!isCancel) menuItem.style.backgroundColor = '#e3f2fd';
        };
        menuItem.onmouseout = () => {
          menuItem.style.backgroundColor = isCancel ? '#f8f9fa' : 'transparent';
        };

        menuItem.onclick = async (e) => {
          // Remove the close handler FIRST to prevent interference
          if (this.currentCloseHandler) {
            document.removeEventListener('click', this.currentCloseHandler);
            this.currentCloseHandler = null;
          }
          // DEBUG: Use console instead of alert to avoid interference
          // console.log("🔥 MENU CLICK DETECTED:", e, actionItem.action, actionData);

          // Prevent event bubbling
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          // Hide menu first
          this.hideNodeToNodeActionMenu();

          // Handle merge action directly in click context to avoid async issues with confirm()
          if (actionItem.action === 'merge') {
            // DEBUG:
            // console.log(`🔥 MERGE: Handling directly in click context`);
            const { sourceId, targetId, sourceName, targetName, sourceType, targetType, draggedNode } = actionData;
            const confirmMessage = `Do you really want to merge these two nodes and their subgraphs into a single one?\n\nSource: "${sourceName}" (type: ${sourceType || 'N/A'})\nTarget: "${targetName}" (type: ${targetType || 'N/A'})`;
            const userConfirmed = confirm(confirmMessage);
            // DEBUG:
            // console.log(`🔥 MERGE: User confirmation result:`, userConfirmed);

            if (userConfirmed) {
              // DEBUG:
              // console.log(`🔥 MERGE: User confirmed, calling mergeEntities`);
              // Call merge in async context after confirmation
              this.mergeEntities(sourceId, targetId, targetName).catch(error => {
                console.error('Error in mergeEntities:', error);
              });
            } else {
              // DEBUG:
              // console.log(`🔥 MERGE: User cancelled, resetting position`);
              draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
            }
          } else {
            // Handle other actions normally
            try {
              await this.handleNodeToNodeAction(actionItem.action, actionData);
              console.log(`✅ handleNodeToNodeAction completed successfully`);
            } catch (error) {
              console.error(`❌ Error in handleNodeToNodeAction:`, error);
            }
          }

          return false;
        };

        // Also try addEventListener as a backup
        menuItem.addEventListener('click', (e) => {
          console.debug("addEventListener click FIRED:", e, actionItem.action, actionData);
        });

        console.debug(`Event handlers attached to menu item ${index}`);
      } else {
        console.debug(`Menu item ${index} is DISABLED, no click handler attached`);
      }

      menu.appendChild(menuItem);
    });

    // Position menu near the drop location
    const containerRect = this.containerTarget.getBoundingClientRect();
    const menuX = Math.min(containerRect.left + dropPosition.x + 10, window.innerWidth - 240);
    const menuY = Math.min(containerRect.top + dropPosition.y - 10, window.innerHeight - 200);

    menu.style.left = menuX + 'px';
    menu.style.top = menuY + 'px';

    document.body.appendChild(menu);
    this.currentNodeToNodeMenu = menu;

    // Close menu when clicking elsewhere
    const closeHandler = (e) => {
      if (!menu.contains(e.target)) {
        this.hideNodeToNodeActionMenu();
        document.removeEventListener('click', closeHandler);
        this.currentCloseHandler = null;
      }
    };
    this.currentCloseHandler = closeHandler;
    setTimeout(() => document.addEventListener('click', closeHandler), 100);
  }

  hideNodeToNodeActionMenu() {
    if (this.currentNodeToNodeMenu) {
      this.currentNodeToNodeMenu.remove();
      this.currentNodeToNodeMenu = null;
    }
  }

  async handleNodeToNodeAction(action, actionData) {
    // DEBUG:
    // console.log(`🎯 handleNodeToNodeAction ENTRY: action='${action}'`);
    // console.log(`🎯 actionData:`, actionData);
    const {
      sourceId, targetId, sourceName, targetName, sourceType, targetType,
      draggedNode, targetNode
    } = actionData;
    // DEBUG:
    // console.debug("handleNodeToNodeAction:", action, actionData);

    switch (action) {
      case 'merge':
        // DEBUG:
        // console.log("Source:", sourceId, sourceName, sourceType);
        // console.log("Target:", targetId, targetName, targetType);
        const confirmMessage = `Do you really want to merge these two nodes and their subgraphs into a single one?\n\nSource: "${sourceName}" (type: ${sourceType || 'N/A'})\nTarget: "${targetName}" (type: ${targetType || 'N/A'})`;
        const userConfirmed = confirm(confirmMessage);

        if (userConfirmed) {
          await this.mergeEntities(sourceId, targetId, targetName);
        } else {
          // Reset position if user cancels
          draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
        }
        break;

      case 'create-relation':
        await this.showCreateRelationModal(sourceId, targetId, sourceName, targetName);
        break;

      case 'cancel':
        // Reset source node to original position
        draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
        break;

      default:
        console.warn('Unknown node-to-node action:', action);
    }
  }

  async showCreateRelationModal(sourceId, targetId, sourceName, targetName) {
    const content = `
      <h3>Create Relation</h3>
      <p>Create a relationship between:</p>
      <div style="margin: 15px 0; padding: 10px; background: #f8f9fa; border-radius: 4px;">
        <strong>"${sourceName}"</strong> → <strong>"${targetName}"</strong>
      </div>
      <form id="create-relation-form">
        <div style="margin-bottom: 15px;">
          <label style="display: block; margin-bottom: 4px;">Relation Type:</label>
          <input type="text" id="relation-type" placeholder="e.g., depends_on, relates_to, part_of"
                 style="width: 100%; padding: 6px; border: 1px solid #ccc; border-radius: 3px;">
          <small style="color: #666; font-size: 11px;">Describe how the first node relates to the second</small>
        </div>
        <div style="text-align: right;">
          <button type="button" onclick="window.graphController.closeModal()"
                  style="margin-right: 10px; padding: 6px 12px; background: #6c757d; color: white; border: none; border-radius: 3px; cursor: pointer;">Cancel</button>
          <button type="submit"
                  style="padding: 6px 12px; background: #007bff; color: white; border: none; border-radius: 3px; cursor: pointer;">Create Relation</button>
        </div>
      </form>
    `;

    this.showModal('Create Relation', content);

    // Handle form submission
    document.getElementById('create-relation-form').onsubmit = async (e) => {
      e.preventDefault();
      const relationType = document.getElementById('relation-type').value.trim();

      if (!relationType) {
        alert('Relation type is required.');
        return;
      }

      await this.createRelation(sourceId, targetId, relationType);
    };
  }

  async createRelation(fromEntityId, toEntityId, relationType) {
    try {
      const csrfToken = this.getCSRFToken();
      const response = await fetch('/api/v1/memory_relations', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify({
          memory_relation: {
            from_entity_id: fromEntityId,
            to_entity_id: toEntityId,
            relation_type: relationType
          }
        })
      });

      if (response.ok) {
        this.closeModal();
        // Refresh the graph to show the new relation
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
        alert('Relation created successfully.');
      } else {
        const error = await response.json();
        alert(`Failed to create relation: ${error.message || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Error creating relation:', error);
      alert('An error occurred while creating the relation.');
    }
  }

  async deleteDuplicateObservations(entityId) {
    // Show confirmation dialog
    const confirmed = confirm(
      'Are you sure you want to delete all duplicate observations? This action cannot be undone.\n\n' +
      'Duplicate observations (with identical content) will be removed, keeping only the oldest one of each.'
    );
    
    if (!confirmed) {
      return;
    }

    try {
      const csrfToken = this.getCSRFToken();
      const response = await fetch(`/api/v1/memory_entities/${entityId}/memory_observations/delete_duplicates`, {
        method: 'DELETE',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        }
      });

      if (response.ok) {
        const result = await response.json();
        alert(`Success! ${result.message}`);
        
        // Close the current modal
        this.closeModal();
        
        // Refresh the graph to update observation counts
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
        
        // Optionally, reopen the observations modal to show the updated list
        // Find the node data and reopen the modal
        const nodeData = this.cy.getElementById(entityId.toString()).data();
        if (nodeData) {
          setTimeout(() => {
            this.showObservationsModal(nodeData);
          }, 500); // Small delay to let the graph refresh
        }
      } else {
        const error = await response.json();
        alert(`Failed to delete duplicates: ${error.error || 'Unknown error'}`);
      }
    } catch (error) {
      console.error('Error deleting duplicate observations:', error);
      alert('An error occurred while deleting duplicate observations.');
    }
  }

  async addTargetNameAsAlias(sourceId, targetName) {
    try {
      // First, get the current source entity data
      const response = await fetch(`/api/v1/memory_entities/${sourceId}`);
      if (!response.ok) {
        console.warn(`Could not fetch source entity ${sourceId} to add alias`);
        return;
      }

      const entity = await response.json();
      const currentAliases = entity.aliases ? entity.aliases.trim() : '';

      // Check if target name is already in aliases or is the same as the entity name
      const aliasArray = currentAliases ? currentAliases.split(',').map(a => a.trim()) : [];
      const targetNameTrimmed = targetName.trim();

      if (entity.name === targetNameTrimmed || aliasArray.includes(targetNameTrimmed)) {
        console.log(`Target name "${targetNameTrimmed}" already exists as name or alias, skipping`);
        return;
      }

      // Add target name to aliases
      const updatedAliases = currentAliases ? `${currentAliases}, ${targetNameTrimmed}` : targetNameTrimmed;

      // Update the entity with the new aliases
      const csrfToken = this.getCSRFToken();
      const updateResponse = await fetch(`/api/v1/memory_entities/${sourceId}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify({
          memory_entity: {
            aliases: updatedAliases
          }
        })
      });

      if (updateResponse.ok) {
        console.log(`Successfully added "${targetNameTrimmed}" as alias to entity ${sourceId}`);
      } else {
        console.warn(`Failed to add alias to entity ${sourceId}`);
      }
    } catch (error) {
      console.error('Error adding target name as alias:', error);
    }
  }

  // ============================================
  // Data Manage (Export/Import/Cleanup) Methods
  // ============================================

  async showDataManageModal() {
    // Fetch root nodes for export selection and projects for cleanup
    let rootNodes = [];
    let orphanNodes = [];
    let projects = [];

    try {
      const [rootNodesRes, orphansRes] = await Promise.all([
        fetch('/data_exchange/root_nodes'),
        fetch('/data_exchange/orphan_nodes')
      ]);

      if (rootNodesRes.ok) {
        const data = await rootNodesRes.json();
        rootNodes = data.nodes || [];
        projects = rootNodes.filter(n => n.entity_type === 'Project');
      }

      if (orphansRes.ok) {
        const data = await orphansRes.json();
        orphanNodes = data.orphans || [];
      }
    } catch (error) {
      console.error('Error fetching data for Data Manage modal:', error);
    }

    const content = `
      <div style="min-width: 70%; max-width: 900px;">
        <!-- Tabs -->
        <div style="display: flex; border-bottom: 2px solid #dee2e6; margin-bottom: 20px;">
          <button id="export-tab" onclick="window.graphController.switchDataManageTab('export')"
                  style="padding: 10px 20px; border: none; background: #007bff; color: white; cursor: pointer; border-radius: 4px 4px 0 0; margin-right: 4px; font-weight: bold;">
            Export
          </button>
          <button id="import-tab" onclick="window.graphController.switchDataManageTab('import')"
                  style="padding: 10px 20px; border: none; background: #e9ecef; color: #495057; cursor: pointer; border-radius: 4px 4px 0 0; margin-right: 4px; font-weight: bold;">
            Import
          </button>
          <button id="cleanup-tab" onclick="window.graphController.switchDataManageTab('cleanup')"
                  style="padding: 10px 20px; border: none; background: #e9ecef; color: #495057; cursor: pointer; border-radius: 4px 4px 0 0; font-weight: bold;">
            Clean up
          </button>
        </div>

        <!-- Export Tab Content -->
        <div id="export-content">
          <p style="margin-bottom: 15px; color: #666;">
            Select root nodes to export. All linked children and observations will be included.
          </p>
          
          <!-- Progress bar (hidden initially) -->
          <div id="export-progress-container" style="display: none; margin-bottom: 15px;">
            <div style="display: flex; justify-content: space-between; margin-bottom: 5px;">
              <span id="export-progress-message">Starting export...</span>
              <span id="export-progress-percentage">0%</span>
            </div>
            <div style="background: #e9ecef; border-radius: 4px; height: 20px; overflow: hidden;">
              <div id="export-progress-bar" style="background: #007bff; height: 100%; width: 0%; transition: width 0.3s ease;"></div>
            </div>
          </div>
          
          <div id="export-node-list" style="max-height: 300px; overflow-y: auto; border: 1px solid #dee2e6; border-radius: 4px; padding: 10px; margin-bottom: 15px;">
            ${rootNodes.length > 0 ? `
              <div style="margin-bottom: 10px;">
                <label style="display: flex; align-items: center; cursor: pointer; padding: 5px; background: #f8f9fa; border-radius: 4px;">
                  <input type="checkbox" id="select-all-nodes" onchange="window.graphController.toggleSelectAllNodes(this.checked)"
                         style="margin-right: 10px; transform: scale(1.2);">
                  <strong>Select All</strong>
                </label>
              </div>
              <hr style="margin: 10px 0; border: none; border-top: 1px solid #dee2e6;">
              ${rootNodes.map(node => `
                <label style="display: flex; align-items: center; cursor: pointer; padding: 8px; border-radius: 4px; margin-bottom: 4px;"
                       onmouseover="this.style.backgroundColor='#f8f9fa'" onmouseout="this.style.backgroundColor='transparent'">
                  <input type="checkbox" class="export-node-checkbox" value="${node.id}"
                         style="margin-right: 10px; transform: scale(1.2);">
                  <span style="flex: 1;">
                    <strong>${this.escapeHtml(node.name)}</strong>
                    <span style="color: #666; font-size: 12px;">(${node.entity_type || 'N/A'})</span>
                  </span>
                  <span style="color: #888; font-size: 11px;">${node.observations_count || 0} obs</span>
                </label>
              `).join('')}
            ` : '<p style="color: #666; text-align: center; padding: 20px;">No root nodes found.</p>'}
          </div>

          <div id="export-buttons" style="text-align: right;">
            <button type="button" onclick="window.graphController.closeModal()"
                    style="margin-right: 10px; padding: 8px 16px; background: #6c757d; color: white; border: none; border-radius: 4px; cursor: pointer;">
              Cancel
            </button>
            <button type="button" id="export-btn" onclick="window.graphController.exportSelectedNodes()"
                    style="padding: 8px 16px; background: #28a745; color: white; border: none; border-radius: 4px; cursor: pointer;">
              Export Selected
            </button>
          </div>
        </div>

        <!-- Import Tab Content -->
        <div id="import-content" style="display: none;">
          <p style="margin-bottom: 15px; color: #666;">
            Select a JSON file to import. The file should be in the graph_mem export format.
          </p>
          
          <form id="import-form" action="/data_exchange/import_upload" method="post" enctype="multipart/form-data">
            <input type="hidden" name="authenticity_token" value="${this.getCSRFToken()}">
            
            <div style="border: 2px dashed #dee2e6; border-radius: 8px; padding: 30px; text-align: center; margin-bottom: 15px;">
              <input type="file" id="import-file" name="file" accept=".json"
                     style="display: none;"
                     onchange="window.graphController.handleImportFileSelect(this)">
              <label for="import-file" style="cursor: pointer;">
                <div style="font-size: 48px; color: #6c757d; margin-bottom: 10px;">📁</div>
                <div style="color: #495057; font-weight: bold;">Click to select a JSON file</div>
                <div style="color: #888; font-size: 12px; margin-top: 5px;">or drag and drop here</div>
              </label>
              <div id="selected-file-name" style="margin-top: 15px; color: #28a745; font-weight: bold; display: none;"></div>
            </div>

            <div style="text-align: right;">
              <button type="button" onclick="window.graphController.closeModal()"
                      style="margin-right: 10px; padding: 8px 16px; background: #6c757d; color: white; border: none; border-radius: 4px; cursor: pointer;">
                Cancel
              </button>
              <button type="submit" id="import-submit-btn" disabled
                      style="padding: 8px 16px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: not-allowed; opacity: 0.6;">
                Upload and Review
              </button>
            </div>
          </form>
        </div>

        <!-- Cleanup Tab Content -->
        <div id="cleanup-content" style="display: none;">
          <p style="margin-bottom: 15px; color: #666;">
            Manage orphan nodes: move them under a project, merge with existing nodes, or delete them.
          </p>
          
          <div style="max-height: 400px; overflow-y: auto; border: 1px solid #dee2e6; border-radius: 4px; margin-bottom: 15px;">
            ${orphanNodes.length > 0 ? `
              <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
                <thead>
                  <tr style="background: #f8f9fa; position: sticky; top: 0;">
                    <th style="padding: 10px; text-align: left; border-bottom: 2px solid #dee2e6;">Node</th>
                    <th style="padding: 10px; text-align: left; border-bottom: 2px solid #dee2e6;">Suggested Parent</th>
                    <th style="padding: 10px; text-align: center; border-bottom: 2px solid #dee2e6; width: 150px;">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  ${orphanNodes.map(orphan => `
                    <tr id="orphan-row-${orphan.id}" style="border-bottom: 1px solid #eee;">
                      <td style="padding: 10px;">
                        <div style="font-weight: 500;">${this.escapeHtml(orphan.name)}</div>
                        <div style="font-size: 11px; color: #666;">
                          (${orphan.entity_type}) - ${orphan.observations_count || 0} obs, ${orphan.children_count || 0} children
                        </div>
                      </td>
                      <td style="padding: 10px;">
                        <select id="parent-select-${orphan.id}" style="width: 100%; padding: 5px; border: 1px solid #ccc; border-radius: 4px; font-size: 12px;">
                          <option value="">-- Select parent --</option>
                          ${orphan.suggested_parents && orphan.suggested_parents.length > 0 ? 
                            orphan.suggested_parents.map(p => `
                              <option value="${p.id}" ${orphan.suggested_parents[0].id === p.id ? 'selected' : ''}>
                                ${this.escapeHtml(p.name)} (score: ${p.score})
                              </option>
                            `).join('') : ''}
                          <optgroup label="All Projects">
                            ${projects.filter(p => !orphan.suggested_parents?.find(sp => sp.id === p.id)).map(p => `
                              <option value="${p.id}">${this.escapeHtml(p.name)}</option>
                            `).join('')}
                          </optgroup>
                        </select>
                      </td>
                      <td style="padding: 10px; text-align: center; white-space: nowrap;">
                        <button onclick="window.graphController.moveOrphanNode(${orphan.id})" 
                                title="Move to selected parent"
                                style="padding: 5px 8px; margin-right: 4px; background: #28a745; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px; height: 26px; vertical-align: middle;">Move</button><button onclick="window.graphController.mergeOrphanNode(${orphan.id})" 
                                title="Merge into selected parent"
                                style="padding: 5px 8px; margin-right: 4px; background: #17a2b8; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px; height: 26px; vertical-align: middle;">Merge</button><button onclick="window.graphController.deleteOrphanNode(${orphan.id}, '${this.escapeHtml(orphan.name).replace(/'/g, "\\'")}'"
                                title="Delete this node"
                                style="padding: 5px 7px; background: #dc3545; color: white; border: none; border-radius: 3px; cursor: pointer; height: 26px; vertical-align: middle; display: inline-flex; align-items: center;"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg></button>
                      </td>
                    </tr>
                  `).join('')}
                </tbody>
              </table>
            ` : '<p style="color: #666; text-align: center; padding: 40px;">No orphan nodes found. All nodes are properly organized.</p>'}
          </div>

          <div style="text-align: right;">
            <button type="button" onclick="window.graphController.closeModal()"
                    style="padding: 8px 16px; background: #6c757d; color: white; border: none; border-radius: 4px; cursor: pointer;">
              Close
            </button>
          </div>
        </div>
      </div>
    `;

    this.showModal('Data Manage', content);
  }

  switchDataManageTab(tab) {
    const exportTab = document.getElementById('export-tab');
    const importTab = document.getElementById('import-tab');
    const cleanupTab = document.getElementById('cleanup-tab');
    const exportContent = document.getElementById('export-content');
    const importContent = document.getElementById('import-content');
    const cleanupContent = document.getElementById('cleanup-content');

    // Reset all tabs
    [exportTab, importTab, cleanupTab].forEach(t => {
      if (t) {
        t.style.background = '#e9ecef';
        t.style.color = '#495057';
      }
    });

    // Hide all content
    [exportContent, importContent, cleanupContent].forEach(c => {
      if (c) c.style.display = 'none';
    });

    // Show selected tab
    if (tab === 'export') {
      exportTab.style.background = '#007bff';
      exportTab.style.color = 'white';
      exportContent.style.display = 'block';
    } else if (tab === 'import') {
      importTab.style.background = '#007bff';
      importTab.style.color = 'white';
      importContent.style.display = 'block';
    } else if (tab === 'cleanup') {
      cleanupTab.style.background = '#007bff';
      cleanupTab.style.color = 'white';
      cleanupContent.style.display = 'block';
    }
  }

  // Cleanup action handlers
  async moveOrphanNode(nodeId) {
    const parentSelect = document.getElementById(`parent-select-${nodeId}`);
    const parentId = parentSelect?.value;

    if (!parentId) {
      alert('Please select a parent project first.');
      return;
    }

    if (!confirm('Are you sure you want to move this node under the selected parent?')) {
      return;
    }

    try {
      const response = await fetch('/data_exchange/move_node', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({ node_id: nodeId, parent_id: parentId })
      });

      const result = await response.json();

      if (result.success) {
        alert(result.message);
        // Remove the row from the table
        const row = document.getElementById(`orphan-row-${nodeId}`);
        if (row) row.remove();
        // Refresh the graph
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
      } else {
        alert('Error: ' + (result.error || 'Failed to move node'));
      }
    } catch (error) {
      console.error('Error moving node:', error);
      alert('An error occurred while moving the node.');
    }
  }

  async mergeOrphanNode(nodeId) {
    const parentSelect = document.getElementById(`parent-select-${nodeId}`);
    const targetId = parentSelect?.value;

    if (!targetId) {
      alert('Please select a target node to merge into first.');
      return;
    }

    if (!confirm('Are you sure you want to merge this node into the selected target? The source node will be deleted and its data will be transferred to the target.')) {
      return;
    }

    try {
      const response = await fetch('/data_exchange/merge_node', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({ source_id: nodeId, target_id: targetId })
      });

      const result = await response.json();

      if (result.success) {
        alert(result.message);
        // Remove the row from the table
        const row = document.getElementById(`orphan-row-${nodeId}`);
        if (row) row.remove();
        // Refresh the graph
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
      } else {
        alert('Error: ' + (result.error || 'Failed to merge node'));
      }
    } catch (error) {
      console.error('Error merging node:', error);
      alert('An error occurred while merging the node.');
    }
  }

  async deleteOrphanNode(nodeId, nodeName) {
    if (!confirm(`Are you sure you want to delete "${nodeName}" forever? This action cannot be undone.`)) {
      return;
    }

    try {
      const response = await fetch(`/data_exchange/delete_node?node_id=${nodeId}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': this.getCSRFToken()
        }
      });

      const result = await response.json();

      if (result.success) {
        alert(result.message);
        // Remove the row from the table
        const row = document.getElementById(`orphan-row-${nodeId}`);
        if (row) row.remove();
        // Refresh the graph
        this.fetchDataAndRenderGraph(this.currentView === 'root', this.currentEntityId);
      } else {
        alert('Error: ' + (result.error || 'Failed to delete node'));
      }
    } catch (error) {
      console.error('Error deleting node:', error);
      alert('An error occurred while deleting the node.');
    }
  }

  toggleSelectAllNodes(checked) {
    const checkboxes = document.querySelectorAll('.export-node-checkbox');
    checkboxes.forEach(cb => cb.checked = checked);
  }

  async exportSelectedNodes() {
    const checkboxes = document.querySelectorAll('.export-node-checkbox:checked');
    const selectedIds = Array.from(checkboxes).map(cb => cb.value);

    if (selectedIds.length === 0) {
      alert('Please select at least one node to export.');
      return;
    }

    // Check if we should use async export (for larger selections)
    // Use async for 3+ nodes or if user prefers it
    const useAsync = selectedIds.length >= 3;

    if (!useAsync) {
      // Sync export for small selections (direct download)
      const params = new URLSearchParams();
      selectedIds.forEach(id => params.append('ids[]', id));
      window.location.href = `/data_exchange/export?${params.toString()}`;
      this.closeModal();
      return;
    }

    // Async export with progress updates
    await this.startAsyncExport(selectedIds);
  }

  async startAsyncExport(selectedIds) {
    // Show progress bar, hide node list
    const progressContainer = document.getElementById('export-progress-container');
    const nodeList = document.getElementById('export-node-list');
    const exportBtn = document.getElementById('export-btn');

    if (progressContainer) progressContainer.style.display = 'block';
    if (nodeList) nodeList.style.display = 'none';
    if (exportBtn) {
      exportBtn.disabled = true;
      exportBtn.style.opacity = '0.6';
      exportBtn.textContent = 'Exporting...';
    }

    try {
      // Start the async export
      const response = await fetch('/data_exchange/export_async', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({ ids: selectedIds })
      });

      const result = await response.json();

      if (!result.success) {
        throw new Error(result.error || 'Failed to start export');
      }

      const exportId = result.export_id;

      // Subscribe to progress updates via ActionCable
      this.subscribeToExportProgress(exportId);

    } catch (error) {
      console.error('Error starting async export:', error);
      alert('Failed to start export: ' + error.message);
      this.resetExportUI();
    }
  }

  subscribeToExportProgress(exportId) {
    // Create ActionCable consumer if not exists
    if (!this.cable) {
      this.cable = createConsumer();
    }

    // Subscribe to the export progress channel
    this.exportSubscription = this.cable.subscriptions.create(
      { channel: 'ExportProgressChannel', export_id: exportId },
      {
        received: (data) => {
          this.handleExportProgress(data);
        },
        connected: () => {
          console.log('Connected to ExportProgressChannel');
        },
        disconnected: () => {
          console.log('Disconnected from ExportProgressChannel');
        }
      }
    );
  }

  handleExportProgress(data) {
    const progressBar = document.getElementById('export-progress-bar');
    const progressMessage = document.getElementById('export-progress-message');
    const progressPercentage = document.getElementById('export-progress-percentage');

    if (data.type === 'progress') {
      // Update progress bar
      if (progressBar) progressBar.style.width = `${data.percentage}%`;
      if (progressMessage) progressMessage.textContent = data.message || 'Exporting...';
      if (progressPercentage) progressPercentage.textContent = `${Math.round(data.percentage)}%`;

    } else if (data.type === 'complete') {
      // Export complete - trigger download
      if (progressBar) progressBar.style.width = '100%';
      if (progressMessage) progressMessage.textContent = 'Export complete! Starting download...';
      if (progressPercentage) progressPercentage.textContent = '100%';

      // Unsubscribe from channel
      this.unsubscribeFromExportProgress();

      if (data.success && data.download_path) {
        // Trigger download
        setTimeout(() => {
          window.location.href = data.download_path;
          this.closeModal();
        }, 500);
      } else {
        alert('Export completed but download link not available.');
        this.resetExportUI();
      }

    } else if (data.type === 'error') {
      // Export failed
      this.unsubscribeFromExportProgress();
      alert('Export failed: ' + (data.error || 'Unknown error'));
      this.resetExportUI();
    }
  }

  unsubscribeFromExportProgress() {
    if (this.exportSubscription) {
      this.exportSubscription.unsubscribe();
      this.exportSubscription = null;
    }
  }

  resetExportUI() {
    const progressContainer = document.getElementById('export-progress-container');
    const nodeList = document.getElementById('export-node-list');
    const exportBtn = document.getElementById('export-btn');
    const progressBar = document.getElementById('export-progress-bar');

    if (progressContainer) progressContainer.style.display = 'none';
    if (nodeList) nodeList.style.display = 'block';
    if (progressBar) progressBar.style.width = '0%';
    if (exportBtn) {
      exportBtn.disabled = false;
      exportBtn.style.opacity = '1';
      exportBtn.textContent = 'Export Selected';
    }
  }

  handleImportFileSelect(input) {
    const file = input.files[0];
    const fileNameDisplay = document.getElementById('selected-file-name');
    const submitBtn = document.getElementById('import-submit-btn');

    if (file) {
      fileNameDisplay.textContent = `Selected: ${file.name}`;
      fileNameDisplay.style.display = 'block';
      submitBtn.disabled = false;
      submitBtn.style.cursor = 'pointer';
      submitBtn.style.opacity = '1';
    } else {
      fileNameDisplay.style.display = 'none';
      submitBtn.disabled = true;
      submitBtn.style.cursor = 'not-allowed';
      submitBtn.style.opacity = '0.6';
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
}
