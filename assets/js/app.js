// Admin console client bundle. Replaces the previously hand-vendored
// phoenix.min.js / phoenix_live_view.js in priv/static/assets/ — this is
// now the single source, and this app's first real JS build step (see
// docs/shared/Admin_Menu_Standard.md §5 for why one was needed: AG Grid
// is an npm package, and there was no pipeline to bundle it into anything).
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { Hooks } from "./hooks"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks
})

liveSocket.connect()

// Exposed for the browser console during development only — the theme
// toggle and initial paint bootstrap are inline in AdminLive's own <head>
// and do not depend on this bundle having loaded.
window.liveSocket = liveSocket
