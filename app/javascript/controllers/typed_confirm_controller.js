import { Controller } from "@hotwired/stimulus"

// Typed confirmation (UI-7): the submit button is enabled only while the typed text matches.
// Cosmetic: the server checks the same text and answers 422 on a mismatch.
export default class extends Controller {
  static targets = ["input", "button"]
  static values = { expected: String }

  connect() {
    this.check()
  }

  check() {
    this.buttonTarget.disabled = this.inputTarget.value.trim() !== this.expectedValue
  }
}
