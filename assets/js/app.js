// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/afp"
import topbar from "../vendor/topbar"

const setTheme = (theme) => {
  if (theme === "system") {
    localStorage.removeItem("afp:theme")
    document.documentElement.removeAttribute("data-theme")
  } else {
    localStorage.setItem("afp:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
  }
}

if (!document.documentElement.hasAttribute("data-theme")) {
  setTheme(localStorage.getItem("afp:theme") || "system")
}

window.addEventListener("storage", event => {
  if (event.key === "afp:theme") setTheme(event.newValue || "system")
})

window.addEventListener("phx:set-theme", event => setTheme(event.target.dataset.phxTheme))

const TicketBoardDrag = {
  mounted() {
    this.draggedTicket = null
    this.activeDropTarget = null

    this.onDragStart = event => {
      const card = event.target.closest("[data-ticket-card]")
      if (!card || !this.el.contains(card)) return

      if (event.target.closest("input, textarea, select, button, a")) {
        event.preventDefault()
        return
      }

      this.draggedTicket = {
        id: card.dataset.ticketId,
        status: card.dataset.ticketStatus,
      }

      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", this.draggedTicket.id)
      card.classList.add("opacity-60", "ring-2", "ring-sky-400")
    }

    this.onDragOver = event => {
      if (!this.draggedTicket) return

      const target = this.dropTargetFor(event)
      if (!target) return

      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
      this.markDropTarget(target)
    }

    this.onDrop = event => {
      if (!this.draggedTicket) return

      const target = this.dropTargetFor(event)
      if (!target) return

      event.preventDefault()
      const status = target.dataset.ticketDropStatus
      const ticket = this.draggedTicket
      this.clearDragState()

      if (ticket.status === status) return

      this.pushEvent("drop_ticket", {ticket_id: ticket.id, status})
    }

    this.onDragEnd = _event => this.clearDragState()

    this.el.addEventListener("dragstart", this.onDragStart)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("dragend", this.onDragEnd)
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this.onDragStart)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("dragend", this.onDragEnd)
  },

  updated() {
    this.clearDragState()
  },

  dropTargetFor(event) {
    const target = event.target.closest("[data-ticket-drop-status]")
    return target && this.el.contains(target) ? target : null
  },

  markDropTarget(target) {
    if (this.activeDropTarget === target) return

    this.clearDropTarget()
    this.activeDropTarget = target
    target.classList.add("bg-sky-50", "ring-2", "ring-sky-300", "dark:bg-sky-950/40")
  },

  clearDropTarget() {
    if (!this.activeDropTarget) return

    this.activeDropTarget.classList.remove(
      "bg-sky-50",
      "ring-2",
      "ring-sky-300",
      "dark:bg-sky-950/40"
    )
    this.activeDropTarget = null
  },

  clearDragState() {
    this.el
      .querySelectorAll("[data-ticket-card]")
      .forEach(card => card.classList.remove("opacity-60", "ring-2", "ring-sky-400"))

    this.clearDropTarget()
    this.draggedTicket = null
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, TicketBoardDrag},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
