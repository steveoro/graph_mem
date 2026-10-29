import { Controller } from "@hotwired/stimulus"

// Explore's <dialog> (UI-4b): opens as a modal when its "explore-dialog" frame gets content (a
// link or the canvas set the frame's src), and closes when the frame is emptied (an edit's
// Turbo Stream), on Esc, or with a Cancel button (data-action="explore-dialog#close"). Focus
// moves into the dialog and back to where it was.
//
// Connects to data-controller="explore-dialog"
export default class extends Controller {
  static targets = ["frame"]

  connect() {
    this.observer = new MutationObserver(() => this.#sync())
    this.observer.observe(this.frameTarget, { childList: true })
  }

  disconnect() {
    this.observer?.disconnect()
  }

  // Opens `url` in the dialog's frame (used by the canvas menus).
  open(url) {
    this.opener = document.activeElement
    this.frameTarget.src = url
  }

  close() {
    this.element.close()
  }

  // The native close event (Esc, close(), a form with method=dialog): empty the frame.
  closed() {
    this.frameTarget.removeAttribute("src")
    this.frameTarget.replaceChildren()
    this.opener?.focus?.()
    this.opener = null
  }

  #sync() {
    const filled = this.frameTarget.childElementCount > 0
    if (filled && !this.element.open) {
      this.opener ??= document.activeElement
      this.element.showModal()
      this.element.querySelector("[autofocus], button, select, input, a[href]")?.focus()
    } else if (!filled && this.element.open) {
      this.element.close()
    }
  }
}
