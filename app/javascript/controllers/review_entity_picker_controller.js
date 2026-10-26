import { Controller } from "@hotwired/stimulus"

// Entity search/autocomplete for the Review page's edit fields (UI-5b; was compaction_review_controller).
export default class extends Controller {
  static targets = ["search", "select", "hidden", "display"]

  connect() {
    this.searchDebounce = null
  }

  searchEntity(event) {
    const input = event.currentTarget
    const query = input.value.trim()
    const select = this.findTargetFor(input, "select")
    if (!select || query.length < 2) return

    clearTimeout(this.searchDebounce)
    this.searchDebounce = setTimeout(() => this.fetchEntities(input, select, query), 200)
  }

  fetchEntities(input, select, query) {
    const url = `/data_exchange/entity_search?q=${encodeURIComponent(query)}`
    fetch(url, { headers: { "Accept": "application/json" } })
      .then((response) => response.json())
      .then((data) => {
        if (!data.entities || data.entities.length === 0) return

        const currentValue = select.value
        const currentText = select.options[select.selectedIndex]?.text || ""

        // Build options using DOM construction (no innerHTML with user data)
        const frag = document.createDocumentFragment()

        if (currentValue) {
          const kept = document.createElement("option")
          kept.value = currentValue
          kept.textContent = currentText
          frag.appendChild(kept)
        }

        data.entities
          .filter((entity) => entity.id.toString() !== currentValue)
          .forEach((entity) => {
            const opt = document.createElement("option")
            opt.value = String(entity.id)
            opt.textContent = String(entity.name ?? '') + ' (' + String(entity.entity_type ?? '') + ')'
            frag.appendChild(opt)
          })

        // Replace all options at once
        while (select.firstChild) select.removeChild(select.firstChild)
        select.appendChild(frag)
        select.value = currentValue
      })
  }

  selectEntity(event) {
    const select = event.currentTarget
    if (!select.value) return

    const hidden = this.findTargetFor(select, "hidden")
    const display = this.findTargetFor(select, "display")
    const selected = select.options[select.selectedIndex]

    if (hidden) hidden.value = select.value
    if (display) display.textContent = selected.text
    select.classList.add("hidden")
  }

  findTargetFor(element, targetName) {
    const id = element.dataset[`${targetName}Id`]
    if (id) return document.getElementById(id)
    return null
  }
}
