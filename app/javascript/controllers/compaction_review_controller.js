import { Controller } from "@hotwired/stimulus"

// Supports inline entity search/autocomplete and bulk selection for the compaction review UI.
export default class extends Controller {
  static targets = ["selectAll", "rowCheckbox", "search", "select", "hidden", "display"]

  connect() {
    this.searchDebounce = null
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.rowCheckboxTargets.forEach((checkbox) => { checkbox.checked = checked })
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
        const currentOption = currentValue ? `<option value="${currentValue}">${currentText}</option>` : ""
        const resultOptions = data.entities
          .filter((entity) => entity.id.toString() !== currentValue)
          .map((entity) => `<option value="${entity.id}">${entity.name} (${entity.entity_type})</option>`)
          .join("")

        select.innerHTML = currentOption + resultOptions
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
