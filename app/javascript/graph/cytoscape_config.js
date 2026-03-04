export const GRAPH_STYLES = [
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
];

export const LAYOUT_OPTIONS = {
  name: 'cose',
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
  animateFilter: function (_node, _i) { return true; },
  animationDuration: 500,
  animationEasing: undefined,
  animate: true,
  selectionType: 'single',
  wheelSensitivity: 0.1
};
