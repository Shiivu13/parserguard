import { Controller } from "@hotwired/stimulus"

// Accepts one candidate selector without a full page reload.
// The server applies it to the contract, bumps the version and re-runs it.
export default class extends Controller {
  static targets = ["row", "error"]
  static values = { url: String, pending: Boolean }

  async accept(event) {
    if (!this.pendingValue) return
    const button = event.currentTarget
    const selector = event.params.selector
    this.setBusy(true)

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content
        },
        body: JSON.stringify({ selector })
      })
      const body = await response.json()
      if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`)

      this.pendingValue = false
      this.markChosen(button.closest("li"), body)
    } catch (error) {
      this.errorTarget.textContent = `Could not apply selector: ${error.message}`
      this.errorTarget.hidden = false
      this.setBusy(false)
    }
  }

  markChosen(chosenRow, body) {
    this.rowTargets.forEach((row) => {
      row.classList.toggle("chosen", row === chosenRow)
      row.querySelector("button")?.remove()
    })
    const note = document.createElement("p")
    note.className = "applied"
    note.textContent = `Applied ${body.selector}. Contract is now v${body.contract_version}; re-run queued.`
    chosenRow.append(note)

    document.querySelector("[data-reject-form]")?.remove()
    const status = document.querySelector("[data-suggestion-status]")
    if (status) status.innerHTML = '<span class="badge badge-status-accepted">accepted</span>'
  }

  setBusy(busy) {
    this.element.querySelectorAll("button").forEach((b) => { b.disabled = busy })
    this.element.setAttribute("aria-busy", busy)
  }
}
