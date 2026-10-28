import { Controller } from "@hotwired/stimulus"
import cytoscape from "cytoscape"

import { GraphApiClient } from "graph/api_client"
import { GRAPH_STYLES, LAYOUT_OPTIONS } from "graph/cytoscape_config"
import { Tooltip } from "graph/tooltip"
import { ContextMenuManager } from "graph/context_menu"

const LAYOUTS = {
  cose: LAYOUT_OPTIONS,
  breadthfirst: { name: "breadthfirst", directed: true, padding: 30, spacingFactor: 1.2, animate: false },
  concentric: { name: "concentric", padding: 30, minNodeSpacing: 30, animate: false },
  grid: { name: "grid", padding: 30, avoidOverlap: true, animate: false }
}

// Explore's canvas (UI-4b): owns the Cytoscape instance (`this.cy`, public: the system specs drive
// it), the toolbar's scope, layout, depth and filters, and the entity panel frame. The current
// scope is written to the URL with history.replaceState, so a reload lands on the same view.
//
// Events: dispatches `entity:selected` ({ id }) when a node is selected; `graph:changed` (from
// an edit's Turbo Stream) refetches the scope, keeping the positions of the nodes that remain.
//
// Connects to data-controller="explore"
export default class extends Controller {
  static targets = ["canvas", "panel", "status", "scope", "layout", "depth", "typeFilter", "relationFilter"]
  static values = {
    readOnly: Boolean, scope: { type: String, default: "root" }, entityId: Number, projectId: Number,
    ids: String, depth: { type: Number, default: 1 }, panelUrl: String
  }

  connect() {
    this.api = new GraphApiClient()
    this.tooltip = new Tooltip()
    this.contextMenu = new ContextMenuManager(
      { select: (id) => this.select(id), openNeighbourhood: (id) => this.openNeighbourhood(id) },
      { readOnly: this.readOnlyValue }
    )
    this.hideMenus = () => this.contextMenu.hide()
    document.addEventListener("click", this.hideMenus)
    this.#syncToolbar()
    this.load()
  }

  disconnect() {
    document.removeEventListener("click", this.hideMenus)
    this.tooltip.hide()
    this.contextMenu.hide()
    this.cy?.destroy()
    this.cy = null
  }

  // --- Toolbar ---

  changeScope() {
    const value = this.scopeTarget.value
    if (value.startsWith("project:")) {
      this.scopeValue = "project"
      this.projectIdValue = Number(value.split(":")[1])
    } else {
      this.scopeValue = value
    }
    this.load()
  }

  changeLayout() {
    this.#runLayout(this.cy?.elements())
  }

  changeDepth() {
    this.depthValue = Number(this.depthTarget.value) === 2 ? 2 : 1
    if (this.scopeValue === "entity") this.load()
  }

  // Hides nodes of other types and edges of other relation types, locally (no request).
  applyFilters() {
    if (!this.cy) return
    const type = this.typeFilterTarget.value
    const relation = this.relationFilterTarget.value
    this.cy.batch(() => {
      this.cy.nodes().forEach((node) => node.style("display", !type || node.data("type") === type ? "element" : "none"))
      this.cy.edges().forEach((edge) => {
        const shown = (!relation || edge.data("label") === relation) && !edge.hasClass("hidden-relation")
        edge.style("display", shown ? "element" : "none")
      })
    })
  }

  fit() {
    this.cy?.fit(undefined, 30)
  }

  // --- Selection and navigation ---

  select(id) {
    if (!id) return
    this.cy?.nodes().unselect()
    this.cy?.$id(String(id)).select()
    if (this.hasPanelTarget && this.panelUrlValue) {
      this.panelTarget.src = this.panelUrlValue.replace("ENTITY_ID", encodeURIComponent(String(id)))
    }
    this.dispatch("selected", { prefix: "entity", detail: { id: String(id) } })
  }

  openNeighbourhood(id) {
    this.scopeValue = "entity"
    this.entityIdValue = Number(id)
    this.load()
  }

  // --- Data ---

  async load() {
    this.#syncToolbar()
    this.#writeUrl()
    const data = await this.#fetch()
    if (data) this.#render(data)
  }

  // graph:changed: refetch the current scope; the nodes that remain keep their positions.
  async refresh(event) {
    const removed = new Set((event?.detail?.removed || []).map(String))
    if (this.scopeValue === "entity" && removed.has(String(this.entityIdValue))) {
      const changed = (event.detail.changed || []).map(String)
      if (changed[0]) this.entityIdValue = Number(changed[0])
    }
    const data = await this.#fetch()
    if (!data) return
    if (!this.cy) return this.#render(data)

    const positions = new Map()
    this.cy.nodes().forEach((node) => { if (!removed.has(node.id())) positions.set(node.id(), { ...node.position() }) })
    const selected = this.cy.nodes(":selected").map((node) => node.id())
    this.cy.batch(() => {
      this.cy.elements().remove()
      this.cy.add(data.elements)
    })
    this.cy.nodes().forEach((node) => {
      const kept = positions.get(node.id())
      if (kept) node.position(kept)
      else node.position(this.#nearNeighbour(node, positions))
    })
    selected.forEach((id) => this.cy.$id(id).select())
    this.applyFilters()
    this.#showTruncation(data)
  }

  async #fetch() {
    this.#setStatus("")
    try {
      return await this.api.fetchGraphData({
        scope: this.scopeValue, entityId: this.entityIdValue || null, projectId: this.projectIdValue || null,
        ids: this.idsValue || null, depth: this.depthValue
      })
    } catch (error) {
      console.error("Could not load the graph:", error)
      this.#setStatus("The graph couldn't be loaded. Try again, or pick another scope.", true)
      return null
    }
  }

  #render(data) {
    this.tooltip.hide()
    this.contextMenu.hide()
    this.cy?.destroy()
    this.cy = cytoscape({ container: this.canvasTarget, elements: data.elements, style: GRAPH_STYLES, layout: { name: "preset" } })
    this.#bindEvents()
    this.#runLayout(this.cy.elements())
    this.applyFilters()
    this.#showTruncation(data)
  }

  #runLayout(elements) {
    if (!this.cy || !elements) return
    const name = this.hasLayoutTarget ? this.layoutTarget.value : "cose"
    try {
      elements.layout({ ...(LAYOUTS[name] || LAYOUT_OPTIONS) }).run()
    } catch (error) {
      console.error("Layout failed:", error)
      this.#setStatus("The layout failed; the graph is shown as loaded.", true)
    }
  }

  // A new node goes next to a neighbour that kept its position (or the middle of the view).
  #nearNeighbour(node, positions) {
    const anchor = node.neighborhood("node").toArray().find((other) => positions.has(other.id()))
    const base = anchor ? positions.get(anchor.id()) : { x: this.cy.width() / 2, y: this.cy.height() / 2 }
    return { x: base.x + 40 + Math.random() * 40, y: base.y + 40 + Math.random() * 40 }
  }

  #bindEvents() {
    this.cy.on("mouseover", "node", (event) => {
      this.tooltip.show(event.target, event.renderedPosition || event.position, this.canvasTarget.getBoundingClientRect())
    })
    this.cy.on("mouseout", "node", () => this.tooltip.hide())
    this.cy.on("tap", "node", (event) => this.select(event.target.id()))
    this.cy.on("dbltap", "node", (event) => this.openNeighbourhood(event.target.id()))
    this.cy.on("cxttap", "node", (event) => this.contextMenu.showNodeMenu(event, this.cy))
    this.cy.on("cxttap", "edge", (event) => this.contextMenu.showEdgeMenu(event, this.cy))
    this.cy.on("tap", (event) => { if (event.target === this.cy) this.contextMenu.hide() })
  }

  #showTruncation(data) {
    if (data.truncated) {
      const shown = data.elements.filter((element) => element.group === "nodes").length
      this.#setStatus(`Showing ${shown.toLocaleString("en-US")} of ${Number(data.total).toLocaleString("en-US")} entities; pick a project to see the rest.`)
    }
  }

  #setStatus(message, error = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("explore-status--error", error)
  }

  #syncToolbar() {
    if (!this.hasScopeTarget) return
    const value = this.scopeValue === "project" ? `project:${this.projectIdValue}` : this.scopeValue
    const option = Array.from(this.scopeTarget.options).find((candidate) => candidate.value === value)
    if (option) {
      option.disabled = false
      this.scopeTarget.value = value
    }
    if (this.hasDepthTarget) this.depthTarget.value = String(this.depthValue)
  }

  #writeUrl() {
    const params = new URLSearchParams()
    if (this.scopeValue === "full") params.set("scope", "full")
    if (this.scopeValue === "project" && this.projectIdValue) params.set("project_id", this.projectIdValue)
    if (this.scopeValue === "entity" && this.entityIdValue) {
      params.set("entity_id", this.entityIdValue)
      if (this.depthValue === 2) params.set("depth", "2")
    }
    if (this.scopeValue === "search" && this.idsValue) params.set("ids", this.idsValue)
    const query = params.toString()
    window.history.replaceState(window.history.state, "", window.location.pathname + (query ? "?" + query : ""))
  }
}
