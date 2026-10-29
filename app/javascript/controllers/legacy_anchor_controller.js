import { Controller } from "@hotwired/stimulus"

// The Maintenance hub's anchors (/maintenance#background-jobs, #mcp-clients, #project-scans)
// survive its 301 to /projects: send an old bookmark on to where that section lives now (UI-6).
export default class extends Controller {
  static values = { targets: Object }

  connect() {
    const target = this.targetsValue[window.location.hash.slice(1)]
    if (target) window.location.replace(target)
  }
}
