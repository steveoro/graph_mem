import { Controller } from "@hotwired/stimulus"
import cytoscape from 'cytoscape';

// Connects to data-controller="graph"
export default class extends Controller {
  static targets = [ "container" ]

  connect() {
    console.log("Graph controller connected");
    this.fetchDataAndRenderGraph();
  }

  async fetchDataAndRenderGraph() {
    try {
      const response = await fetch('/api/v1/graph_data');
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
  }

  initializeDragAndDropListeners() {
    if (!this.cy) return;

    this.cy.on('dragfreeon', 'node', (event) => {
      // DEBUG
      console.log("Drag free on event:", event);
      this.handleNodeDrop(event);
    });

    // Optional: Visual feedback for drag over
    this.cy.on('dragover', 'node', (event) => {
      // DEBUG
      console.log("Drag over event:", event);
      const nodeOver = event.target;
      // Example: Add a class or change style. Ensure you have a way to revert this.
      // For simplicity, this is left as a placeholder for now.
      // nodeOver.addClass('potential-drop-target'); 
    });

    this.cy.on('dragout', 'node', (event) => {
      // DEBUG
      console.log("Drag out event:", event);
      const nodeOut = event.target;
      // Example: Remove class or revert style
      // nodeOut.removeClass('potential-drop-target');
    });
  }

  handleNodeDrop(event) {
    const draggedNode = event.target;
    const draggedNodePosition = draggedNode.position();
    let targetFound = null;
    // DEBUG
    console.log("handleNodeDrop:", event);

    this.cy.nodes().not(draggedNode).forEach((potentialTargetNode) => {
      if (targetFound) return; // Already found a target

      // DEBUG
      console.log("draggedNode.forEach:", potentialTargetNode);
      const targetBB = potentialTargetNode.renderedBoundingBox();
      const isOverlapping = (
        draggedNodePosition.x >= targetBB.x1 &&
        draggedNodePosition.x <= targetBB.x2 &&
        draggedNodePosition.y >= targetBB.y1 &&
        draggedNodePosition.y <= targetBB.y2
      );

      if (isOverlapping) {
        targetFound = potentialTargetNode;
      }
    });

    if (targetFound) {
      const shiftKeyPressed = event.originalEvent.shiftKey;

      if (shiftKeyPressed) {
        // Attempting a MERGE operation
        const sourceId = draggedNode.id();
        const targetId = targetFound.id();
        const sourceName = draggedNode.data('label') || sourceId;
        const targetName = targetFound.data('label') || targetId;
        const sourceType = draggedNode.data('type');
        const targetType = targetFound.data('type');

        if (sourceType === targetType) {
          if (confirm(`Are you sure you want to merge '${sourceName}' (type: ${sourceType}) into '${targetName}' (type: ${targetType})?`)) {
            this.mergeEntities(sourceId, targetId);
          }
        } else {
          alert(`Merge failed: Nodes must be of the same entity type. Source is '${sourceType}', Target is '${targetType}'.`);
        }
      } else {
        // No SHIFT key: This will be for creating a relation (to be implemented next)
        console.log("Node dropped without SHIFT key. Future: Create relation.");
        // For now, do nothing or snap back if desired.
      }
    } else {
      // If not dropped on another node, you might want to snap it back or update its position on the server.
      // For now, we do nothing, Cytoscape handles the new position visually.
    }
  }

  async mergeEntities(sourceId, targetId) {
    console.log(`Attempting to merge ${sourceId} into ${targetId}`);
    const csrfToken = this.getCSRFToken();
    if (!csrfToken) {
      console.error("CSRF token not found. Merge aborted.");
      alert("Error: CSRF token not found. Cannot perform merge.");
      return;
    }

    try {
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
}
