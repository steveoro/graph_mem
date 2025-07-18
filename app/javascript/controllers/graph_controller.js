import { Controller } from "@hotwired/stimulus"
import cytoscape from 'cytoscape';

// Connects to data-controller="graph"
export default class extends Controller {
  static targets = [ "container" ]

  connect() {
    console.log("Graph controller connected");
    this.currentView = 'root'; // 'root', 'full', or 'subgraph'
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
    
    navDiv.appendChild(rootBtn);
    navDiv.appendChild(fullBtn);
    navDiv.appendChild(backBtn);
    
    // Add the navigation as a child of the graph container
    this.containerTarget.appendChild(navDiv);
    this.navControls = { rootBtn, fullBtn, backBtn };
    
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
      Observations: ${data.observations_count || 0}
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
      { text: `Observations: ${data.observations_count || 0}`, clickable: true, action: 'show-observations' },
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
      
      this.showModal('Entity Observations', `
        <h3>${nodeData.label} (ID: ${nodeData.id})</h3>
        <p><strong>Type:</strong> ${nodeData.type || 'N/A'}</p>
        <p><strong>Total Observations:</strong> ${observations.length}</p>
        <hr>
        ${observations.length > 0 ? 
          observations
            .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
            .map(obs => `
              <div style="margin-bottom: 10px; padding: 8px; background: #f8f9fa; border-radius: 4px;">
                <div style="font-size: 11px; color: #666; margin-bottom: 4px;">
                  ${new Date(obs.created_at).toLocaleString()}
                </div>
                <div>${obs.text_content}</div>
              </div>
            `).join('') 
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
    if (nodeData.observations_count > 10) {
      if (!confirm(`This entity has ${nodeData.observations_count} observations. Show them all?`)) {
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
      max-width: 500px;
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

    this.cy.nodes().not(draggedNode).forEach((potentialTargetNode) => {
      if (targetFound) return; // Already found a target

      const targetBB = potentialTargetNode.renderedBoundingBox();
      const draggedBB = draggedNode.renderedBoundingBox();
      
      // Check for overlap using bounding boxes
      const isOverlapping = (
        draggedBB.x1 < targetBB.x2 &&
        draggedBB.x2 > targetBB.x1 &&
        draggedBB.y1 < targetBB.y2 &&
        draggedBB.y2 > targetBB.y1
      );

      if (isOverlapping) {
        targetFound = potentialTargetNode;
      }
    });

    if (targetFound) {
      const shiftKeyPressed = event.originalEvent && event.originalEvent.shiftKey;

      if (shiftKeyPressed) {
        // Attempting a MERGE operation
        const sourceId = draggedNode.id();
        const targetId = targetFound.id();
        const sourceName = draggedNode.data('label') || sourceId;
        const targetName = targetFound.data('label') || targetId;
        const sourceType = draggedNode.data('type');
        const targetType = targetFound.data('type');

        // Check if types match (including null/undefined handling)
        const typesMatch = (sourceType === targetType) || 
                          (!sourceType && !targetType) ||
                          (sourceType === null && targetType === null);

        if (typesMatch) {
          const confirmMessage = `Do you really want to merge these two nodes and their subgraphs into a single one?\n\nSource: "${sourceName}" (type: ${sourceType || 'N/A'})\nTarget: "${targetName}" (type: ${targetType || 'N/A'})`;
          
          if (confirm(confirmMessage)) {
            this.mergeEntities(sourceId, targetId, targetName);
          } else {
            // Reset position if user cancels
            draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
          }
        } else {
          alert(`Cannot drag-merge nodes of different type.\n\nSource type: "${sourceType || 'N/A'}"\nTarget type: "${targetType || 'N/A'}"`);
          // Reset position
          draggedNode.position(draggedNode.data('originalPosition') || draggedNode.position());
        }
      } else {
        // No SHIFT key: Normal drag behavior (just repositioning)
        console.log("Node dropped without SHIFT key. Normal repositioning.");
        // Allow normal positioning - no special action needed
      }
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
}
