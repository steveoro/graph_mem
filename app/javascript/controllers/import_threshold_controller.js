import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["slider", "output"]

  sync() {
    this.outputTarget.textContent = Number(this.sliderTarget.value).toFixed(2)
  }
}
