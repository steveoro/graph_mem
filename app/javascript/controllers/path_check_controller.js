import { Controller } from "@hotwired/stimulus"

// The scan form's live path check (UI-6 P3): after a pause in typing, point the
// "scan-path-check" Turbo Frame at GET /projects/scans/check_path?path=…, which renders what
// ScanRootPolicy would do with the path. A folder chip fills the field and checks it at once.
export default class extends Controller {
  static targets = ["input", "frame"]
  static values = { url: String, delay: { type: Number, default: 400 } }

  disconnect() {
    clearTimeout(this.timer)
  }

  check() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.load(), this.delayValue)
  }

  pick({ params: { path } }) {
    this.inputTarget.value = path
    this.inputTarget.focus()
    clearTimeout(this.timer)
    this.load()
  }

  load() {
    const url = new URL(this.urlValue, window.location.origin)
    const path = this.inputTarget.value.trim()
    if (path) url.searchParams.set("path", path)
    this.frameTarget.src = url.toString()
  }
}
