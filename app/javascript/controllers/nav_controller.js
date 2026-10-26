import { Controller } from "@hotwired/stimulus"

// Sidebar toggle for small screens (UI-1). Escape closes the menu.
export default class extends Controller {
  static targets = ["toggle", "menu"]

  toggle() {
    this.setOpen(!this.element.classList.contains("ui-sidebar--open"))
  }

  close() {
    if (this.element.classList.contains("ui-sidebar--open")) this.setOpen(false)
  }

  setOpen(open) {
    this.element.classList.toggle("ui-sidebar--open", open)
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", String(open))
  }
}
