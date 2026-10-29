import { Controller } from "@hotwired/stimulus"

// Flash toasts (UI-1). Notices dismiss themselves after a few seconds; alerts stay until
// dismissed. Toasts added later by a Turbo Stream connect through the target callback.
// An undo toast with data-undo-until (Explore's edits, UI-4b) loses its Undo button when that
// time passes and points to Home's Recent activity instead; other undo toasts keep it.
export default class extends Controller {
  static targets = ["item"]
  static values = { timeout: { type: Number, default: 6000 } }

  initialize() {
    this.timers = new WeakMap()
  }

  itemTargetConnected(item) {
    if (item.classList.contains("ui-toast--notice")) {
      this.timers.set(item, setTimeout(() => item.remove(), this.timeoutValue))
    } else if (item.dataset.undoUntil) {
      this.#expireUndo(item)
    }
  }

  itemTargetDisconnected(item) {
    clearTimeout(this.timers.get(item))
  }

  dismiss(event) {
    event.target.closest(".ui-toast")?.remove()
  }

  #expireUndo(item) {
    const remaining = Date.parse(item.dataset.undoUntil) - Date.now()
    if (Number.isNaN(remaining)) return
    const expire = () => {
      item.querySelector("form")?.remove()
      const note = document.createElement("p")
      note.className = "ui-toast__text ui-toast__later"
      note.dataset.testid = "toast-undo-later"
      note.textContent = "Undo it later from Home › Recent activity."
      item.querySelector(".ui-toast__text")?.after(note)
    }
    if (remaining <= 0) expire()
    else this.timers.set(item, setTimeout(expire, remaining))
  }
}
