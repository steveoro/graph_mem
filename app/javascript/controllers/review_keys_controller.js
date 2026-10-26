import { Controller } from "@hotwired/stimulus"
import { el } from "lib/dom"

// Keyboard shortcuts for the Review page (UI-5b). Items are groups and rows (targets "item");
// actions are elements marked data-review-keys-action="apply|dismiss|snooze|open|edit|restore"
// inside the focused item or the detail pane. Shortcuts never fire while typing in a field.
// 1 / 2 open the preview card for keeping the first / second side of a contradiction: nothing is
// applied without the card's own Apply button.
const HELP = [
  [ "j / k", "next / previous item" ], [ "Enter", "open" ], [ "a", "apply (opens the preview card when needed)" ],
  [ "d", "dismiss" ], [ "s", "snooze" ], [ "e", "save edits" ], [ "r", "restore" ], [ "x", "select" ],
  [ "/", "search" ], [ "1 / 2", "keep the first / second side of a contradiction" ], [ "?", "this help" ]
]

export default class extends Controller {
  static targets = ["item", "search"]

  connect() {
    this.index = -1
    this.onKeydown = this.keydown.bind(this)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  keydown(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || this.typing(event.target)) return
    // Enter on a focused link or button presses it (keyboard users), not the selected row.
    if (event.key === "Enter" && event.target.closest("a, button, summary, [role='button']")) return

    const handler = {
      j: () => this.move(1), k: () => this.move(-1), Enter: () => this.act("open"),
      a: () => this.act("apply"), d: () => this.act("dismiss"), s: () => this.act("snooze"),
      e: () => this.act("edit"), r: () => this.act("restore"), x: () => this.toggleSelected(),
      "/": () => this.searchTarget?.focus(), "?": () => this.help(),
      1: () => this.keep(1), 2: () => this.keep(2)
    }[event.key]
    if (!handler) return

    event.preventDefault()
    handler()
  }

  typing(target) {
    return Boolean(target.closest("input, textarea, select, [contenteditable='true'], [contenteditable='']"))
  }

  move(delta) {
    const items = this.itemTargets
    if (items.length === 0) return

    this.index = Math.min(Math.max(this.index + delta, 0), items.length - 1)
    this.focusCurrent()
  }

  focusCurrent() {
    const items = this.itemTargets
    items.forEach((item) => item.classList.remove("review-item--focused"))
    const item = items[Math.min(this.index, items.length - 1)]
    if (!item) return

    item.classList.add("review-item--focused")
    item.setAttribute("tabindex", "-1")
    item.focus()
    item.scrollIntoView({ block: "nearest" })
  }

  // Finds the action in the focused item, then in the detail pane; submits a form, clicks a link.
  act(action) {
    const selector = `[data-review-keys-action="${action}"]`
    const item = this.itemTargets[this.index]
    const target = item?.querySelector(selector) || document.querySelector(`#review-detail ${selector}`)
    if (!target) return

    if (target.tagName === "FORM") target.requestSubmit()
    else target.click()
    // The acted-on row is removed by the response: keep focus on the item now at this position.
    setTimeout(() => this.focusCurrent(), 400)
  }

  keep(side) {
    document.querySelector(`#review-detail [data-review-keys-keep="${side}"]`)?.click()
  }

  toggleSelected() {
    const item = this.itemTargets[this.index]
    if (!item) return

    item.setAttribute("aria-selected", item.getAttribute("aria-selected") === "true" ? "false" : "true")
  }

  help() {
    let dialog = document.getElementById("review-keys-help")
    if (!dialog) {
      const rows = HELP.map(([ keys, what ]) => el("tr", {}, el("th", {}, keys), el("td", {}, what)))
      dialog = el("dialog", { id: "review-keys-help", className: "ui-card" },
        el("h2", {}, "Keyboard shortcuts"), el("table", {}, el("tbody", {}, ...rows)),
        el("form", { method: "dialog" }, el("button", { className: "ui-btn", type: "submit" }, "Close")))
      document.body.appendChild(dialog)
    }
    dialog.showModal()
  }
}
