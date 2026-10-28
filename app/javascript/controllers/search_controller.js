import { Controller } from "@hotwired/stimulus"

// The Search page (UI-3): a chip, mode or select change submits the form (all state is in the
// URL), the result whose panel is open stays highlighted, and "/" focuses the query box unless
// the key is typed into a field. No markup is built here.
export default class extends Controller {
  static targets = ["form", "query", "result"]

  submit() {
    this.formTarget.requestSubmit()
  }

  select(event) {
    const selected = event.currentTarget.closest("[data-search-target~='result']")
    this.resultTargets.forEach((result) => {
      result.classList.toggle("search-result--selected", result === selected)
      if (result === selected) result.setAttribute("aria-current", "true")
      else result.removeAttribute("aria-current")
    })
  }

  focus(event) {
    if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return
    const target = event.target
    if (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)) return

    event.preventDefault()
    this.queryTarget.focus()
  }
}
