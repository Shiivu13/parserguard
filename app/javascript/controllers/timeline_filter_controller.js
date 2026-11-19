import { Controller } from "@hotwired/stimulus"

// Client-side severity filter for the drift timeline. Remembers the choice per browser.
export default class extends Controller {
  static targets = ["toggle", "row", "count"]
  static storageKey = "parserguard.timeline.severities"

  connect() {
    const saved = this.load()
    if (saved) this.toggleTargets.forEach((t) => { t.checked = saved.includes(t.value) })
    this.apply()
  }

  apply() {
    const visible = this.toggleTargets.filter((t) => t.checked).map((t) => t.value)
    let shown = 0
    this.rowTargets.forEach((row) => {
      const show = visible.includes(row.dataset.severity)
      row.hidden = !show
      if (show) shown += 1
    })
    if (this.hasCountTarget) this.countTarget.textContent = `${shown} of ${this.rowTargets.length} shown`
    this.save(visible)
  }

  load() {
    try { return JSON.parse(localStorage.getItem(this.constructor.storageKey)) } catch { return null }
  }

  save(values) {
    try { localStorage.setItem(this.constructor.storageKey, JSON.stringify(values)) } catch { /* private mode */ }
  }
}
