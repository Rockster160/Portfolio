// Uncaught errors and rejected promises on any page, sent to /client_errors so
// they land in the same error log as the server's own. Loaded first, so it is
// listening before anything else in the bundle runs.
//
// Only what can be acted on is sent: a cross-origin "Script error." carries no
// detail at all, and a browser extension's failures are not the app's.

const ENDPOINT = "/client_errors"
// Reports one page load sends at most. A loop throwing on every frame says
// everything in its first one.
const MAX_PER_PAGE = 10
const IGNORED_MESSAGES = [/^Script error\.?$/i, /ResizeObserver loop/i]
const EXTENSION_SOURCE = /^(?:chrome|moz|safari|safari-web)-extension:\/\//i

const sent = new Set()

function worthSending(message, source, stack) {
  if (!message) return false
  if (IGNORED_MESSAGES.some((rx) => rx.test(message))) return false
  if (EXTENSION_SOURCE.test(source || "")) return false
  if (stack && stack.split("\n").some((line) => EXTENSION_SOURCE.test(line.trim().replace(/^at\s+(?:.*\()?/, "")))) return false
  return true
}

export function reportClientError({ kind, name, message, stack, source }) {
  try {
    message = String(message || "").slice(0, 1000)
    if (!worthSending(message, source, stack)) return
    // The same failure once per page load: the server counts repeats across
    // loads, and a page that throws on every render would otherwise flood it.
    const key = `${name}|${message}`
    if (sent.has(key) || sent.size >= MAX_PER_PAGE) return
    sent.add(key)

    fetch(ENDPOINT, {
      method: "POST",
      keepalive: true,
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind,
        name: name || "Error",
        message,
        stack: String(stack || "").slice(0, 4000),
        source: source || "",
        page: window.location.pathname,
        // The build this page loaded with, which a page held open for days can
        // be well behind.
        build: document.querySelector('meta[name="app-build"]')?.content || "",
        url: window.location.href,
      }),
    }).catch(() => {})
  } catch (_) {
    // Reporting a failure must never become one.
  }
}

window.addEventListener("error", (event) => {
  const error = event.error
  const where = event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : ""
  reportClientError({
    kind: "error",
    name: error?.name,
    message: error?.message || event.message,
    stack: error?.stack,
    source: where,
  })
})

// A rejection's reason can be anything at all, including something that won't
// serialize.
function describe(reason) {
  if (typeof reason === "string") return reason
  try {
    return JSON.stringify(reason) ?? String(reason)
  } catch (_) {
    return String(reason)
  }
}

window.addEventListener("unhandledrejection", (event) => {
  const reason = event.reason
  const isError = reason instanceof Error
  reportClientError({
    kind: "rejection",
    name: isError ? reason.name : "UnhandledRejection",
    message: isError ? reason.message : describe(reason),
    stack: isError ? reason.stack : "",
    source: "",
  })
})
