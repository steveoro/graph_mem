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
    const status = payload.status || ""
    const phase = payload.phase || ""
    document.querySelectorAll(`[data-operation-progress-id="${this.operationIdValue}"]`).forEach((element) => {
      element.querySelectorAll("[data-progress-status]").forEach((node) => {
        node.textContent = this.humanizeStatus(status)
        this.updateBadgeClass(node, status)
      })
      element.querySelectorAll("[data-progress-phase]").forEach((node) => { node.textContent = this.humanize(phase) })
      element.querySelectorAll("[data-progress-message]").forEach((node) => { node.textContent = payload.message || "" })
      element.querySelectorAll("[data-progress-current]").forEach((node) => { node.textContent = payload.current ?? 0 })
      element.querySelectorAll("[data-progress-total]").forEach((node) => { node.textContent = payload.total ?? 0 })
      element.querySelectorAll("[data-progress-percentage]").forEach((node) => { node.textContent = `${payload.percentage ?? 0}%` })
      element.querySelectorAll("progress").forEach((node) => { node.value = payload.percentage ?? 0 })
      element.dataset.progressStatus = status
    })
  }

  humanize(value) {
    if (!value) return ""
    return value.toString().replace(/_/g, " ").replace(/\b\w/g, (char) => char.toUpperCase())
  }

  humanizeStatus(status) {
    return this.humanize(status || "idle")
  }

  updateBadgeClass(node, status) {
    if (!node.classList.contains("dashboard-badge")) return

    const statusClassMap = { running: "running", paused: "paused", completed: "completed", failed: "failed", pending: "idle" }
    const suffix = statusClassMap[status] || "idle"
    Array.from(node.classList).forEach((cssClass) => {
      if (cssClass.startsWith("dashboard-badge--")) node.classList.remove(cssClass)
    })
    node.classList.add(`dashboard-badge--${suffix}`)
  }
}
