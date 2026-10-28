import { Controller } from "@hotwired/stimulus"

// Home's quick search (UI-2b): "/" focuses the box, unless the key is typed into a field.
export default class extends Controller {
  static targets = ["input"]

  focus(event) {
    if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return
    const target = event.target
    if (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)) return

    event.preventDefault()
    this.inputTarget.focus()
  }
}
