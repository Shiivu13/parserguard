import { Controller } from "@hotwired/stimulus"

// Shows/hides the (escaped) HTML source of a snapshot.
export default class extends Controller {
  static targets = ["panel", "button"]

  toggle() {
    const open = this.panelTarget.hidden
    this.panelTarget.hidden = !open
    this.buttonTarget.textContent = open ? "Hide" : "Show"
    this.buttonTarget.setAttribute("aria-expanded", String(open))
  }
}
