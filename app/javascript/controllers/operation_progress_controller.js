import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// One cable connection for every card on the page.
let consumer
const sharedConsumer = () => (consumer ||= createConsumer())

export default class extends Controller {
  static values = { operationId: String }

  connect() {
    this.connected = true
    this.subscribe()
  }

  disconnect() {
    this.connected = false
    this.unsubscribe()
  }

  // A live-refresh morph can swap the operation (a new scheduled run): follow it (1.84.0).
  operationIdValueChanged() {
    if (this.connected) this.subscribe()
  }

  subscribe() {
    if (this.subscription && this.subscribedTo === this.operationIdValue) return

    this.unsubscribe()
    if (!this.operationIdValue) return

    this.subscribedTo = this.operationIdValue
    this.subscription = sharedConsumer().subscriptions.create(
      { channel: "OperationProgressChannel", operation_id: this.operationIdValue },
      { received: (payload) => this.render(payload) }
    )
  }

  unsubscribe() {
    this.subscription?.unsubscribe()
    this.subscription = null
    this.subscribedTo = null
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
      // A step's own bar (data-progress-step, 1.84.0) is the page's to refresh, not the run's percentage.
      element.querySelectorAll("progress:not([data-progress-step])").forEach((node) => { node.value = payload.percentage ?? 0 })
      if (payload.updated_at) {
        element.querySelectorAll("[data-progress-received-at]").forEach((node) => {
          node.textContent = this.formatTime(new Date(payload.updated_at), element)
        })
      }
      this.renderSteps(element, payload.details)
      element.dataset.progressStatus = status
      this.updateActionVisibility(element, status)
    })
  }

  // A run made of steps (the scheduled-jobs card, 1.81.0): details = { index, steps: [{ outcome, started_at }] }.
  renderSteps(element, details) {
    const steps = details && Array.isArray(details.steps) ? details.steps : null
    if (!steps || !Number.isInteger(details.index)) return

    const index = Math.min(details.index, steps.length - 1)
    const step = steps[index] || {}
    element.querySelectorAll("[data-progress-step-number]").forEach((node) => { node.textContent = Math.min(details.index + 1, steps.length) })
    element.querySelectorAll("[data-progress-step-started]").forEach((node) => {
      node.textContent = step.started_at ? this.formatTime(new Date(step.started_at), element) : "—"
    })
    steps.forEach((entry, position) => {
      element.querySelectorAll(`[data-progress-step-outcome="${position}"]`).forEach((node) => { node.textContent = entry.outcome || "" })
    })
  }

  // The server's time zone (data-progress-time-zone), so live times match the rendered ones.
  formatTime(date, element) {
    const timeZone = element.dataset.progressTimeZone || undefined
    return date.toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false, timeZone })
  }

  updateActionVisibility(element, status) {
    element.querySelectorAll("[data-progress-action]").forEach((node) => {
      const visibleFor = (node.dataset.progressVisibleFor || "").split(/\s+/).filter(Boolean)
      if (visibleFor.length === 0) return

      node.style.display = visibleFor.includes(status) ? "" : "none"
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
    if (!node.classList.contains("ui-badge")) return

    const statusClassMap = { running: "running", paused: "paused", completed: "completed", failed: "failed", pending: "idle" }
    const suffix = statusClassMap[status] || "idle"
    Array.from(node.classList).forEach((cssClass) => {
      if (cssClass.startsWith("ui-badge--")) node.classList.remove(cssClass)
    })
    node.classList.add(`ui-badge--${suffix}`)
  }
}
