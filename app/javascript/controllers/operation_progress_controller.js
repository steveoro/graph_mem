import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static values = { operationId: String }

  connect() {
    if (!this.operationIdValue) return

    this.subscription = createConsumer().subscriptions.create(
      { channel: "OperationProgressChannel", operation_id: this.operationIdValue },
      { received: (payload) => this.render(payload) }
    )
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  render(payload) {
    document.querySelectorAll(`[data-operation-progress-id="${this.operationIdValue}"]`).forEach((element) => {
      element.querySelectorAll("[data-progress-status]").forEach((node) => { node.textContent = payload.status || "" })
      element.querySelectorAll("[data-progress-phase]").forEach((node) => { node.textContent = payload.phase || "" })
      element.querySelectorAll("[data-progress-message]").forEach((node) => { node.textContent = payload.message || "" })
      element.querySelectorAll("[data-progress-current]").forEach((node) => { node.textContent = payload.current ?? 0 })
      element.querySelectorAll("[data-progress-total]").forEach((node) => { node.textContent = payload.total ?? 0 })
      element.querySelectorAll("[data-progress-percentage]").forEach((node) => { node.textContent = `${payload.percentage ?? 0}%` })
      element.querySelectorAll("progress").forEach((node) => { node.value = payload.percentage ?? 0 })
      element.dataset.progressStatus = payload.status || ""
    })
  }
}
