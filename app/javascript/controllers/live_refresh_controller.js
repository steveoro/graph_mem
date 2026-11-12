import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Keeps a block of the page live (1.84.0, System › Background jobs: #jobs-cards). It polls urlValue,
// which answers with a Turbo Stream `update … method="morph"` for this element, so each poll only
// patches what changed. Every activeInterval ms while the state target says a job runs
// (data-active="true"), every idleInterval ms otherwise.
//
// - Paused while the tab is hidden; coming back polls at once, then the timer resumes.
// - One poll at a time: a tick is skipped while the previous one is still loading.
// - An open <details> stays open across morphs.
// - A poll that gets anything but a stream back (an expired session's login page) stops the polling
//   and visits that page.
//
//   #jobs-cards{ data: { controller: "live-refresh", live_refresh_url_value: "/system/jobs/cards" } }
//     %span{ hidden: true, data: { live_refresh_target: "state", active: "true" } }
export default class extends Controller {
  static targets = ["state"]
  static values = {
    url: String,
    activeInterval: { type: Number, default: 3000 },
    idleInterval: { type: Number, default: 30000 }
  }

  connect() {
    this.stopped = false
    this.loading = false
    this.onVisibility = () => this.visibilityChanged()
    this.onBeforeMorphAttribute = (event) => this.keepDetailsOpen(event)
    document.addEventListener("visibilitychange", this.onVisibility)
    this.element.addEventListener("turbo:before-morph-attribute", this.onBeforeMorphAttribute)
    this.schedule()
  }

  disconnect() {
    this.stop()
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.element.removeEventListener("turbo:before-morph-attribute", this.onBeforeMorphAttribute)
  }

  schedule() {
    clearTimeout(this.timer)
    if (this.stopped || document.hidden) return

    this.timer = setTimeout(() => this.tick(), this.active ? this.activeIntervalValue : this.idleIntervalValue)
  }

  async tick() {
    clearTimeout(this.timer)
    if (this.stopped || document.hidden || this.loading || !this.urlValue) return

    this.loading = true
    try {
      await this.poll()
    } catch (_error) {
      // A failed poll (the server restarting, the network down) just waits for the next tick.
    } finally {
      this.loading = false
    }
    this.schedule()
  }

  async poll() {
    const response = await fetch(this.urlValue, {
      headers: { Accept: "text/vnd.turbo-stream.html" },
      credentials: "same-origin"
    })
    const type = response.headers.get("Content-Type") || ""
    if (response.ok && type.startsWith("text/vnd.turbo-stream.html")) {
      if (!this.stopped) Turbo.renderStreamMessage(await response.text())
    } else if (response.redirected) {
      this.stop()
      Turbo.visit(response.url)
    }
  }

  visibilityChanged() {
    if (document.hidden) {
      clearTimeout(this.timer)
    } else {
      this.tick()
    }
  }

  stop() {
    this.stopped = true
    clearTimeout(this.timer)
  }

  keepDetailsOpen(event) {
    if (event.target instanceof HTMLDetailsElement && event.detail.attributeName === "open") event.preventDefault()
  }

  get active() {
    return this.hasStateTarget && this.stateTarget.dataset.active === "true"
  }
}
