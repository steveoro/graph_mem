import { Controller } from "@hotwired/stimulus"

// Flash toasts (UI-1). Notices dismiss themselves after a few seconds; alerts stay until
// dismissed. Toasts added later by a Turbo Stream connect through the target callback.
export default class extends Controller {
  static targets = ["item"]
  static values = { timeout: { type: Number, default: 6000 } }

  initialize() {
    this.timers = new WeakMap()
  }

  itemTargetConnected(item) {
    if (!item.classList.contains("ui-toast--notice")) return
    this.timers.set(item, setTimeout(() => item.remove(), this.timeoutValue))
  }

  itemTargetDisconnected(item) {
    clearTimeout(this.timers.get(item))
  }

  dismiss(event) {
    event.target.closest(".ui-toast")?.remove()
  }
}
