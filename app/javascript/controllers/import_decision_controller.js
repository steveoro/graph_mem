import { Controller } from "@hotwired/stimulus"

// Import review: keeps each root node's hidden action field in step with its
// match select. A chosen target means "merge", an empty one means "create".
export default class extends Controller {
  sync(event) {
    const select = event.target
    const input = this.element.querySelector(`.action-input[data-index="${select.dataset.index}"]`)
    if (input) input.value = select.value ? "merge" : "create"
  }
}
