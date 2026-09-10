.pragma library

// Pure helpers for the GlobalProtect panel. No QML types here so the file can
// be reasoned about (and reused) on its own.

var PHRASES = [
  "Tunnel sealed",
  "Packets escorted",
  "Routes guarded",
  "Handshake held",
  "Keys turning",
  "Gateway humming",
  "Wires whispering",
  "Portal aligned"
]

function normalizeStatus(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var deps = s.deps && typeof s.deps === "object" ? s.deps : {}
  return {
    state: typeof s.state === "string" && s.state !== "" ? s.state : "disconnected",
    portal: String(s.portal || ""),
    gateway: String(s.gateway || ""),
    username: String(s.username || ""),
    hasSession: s.hasSession === true,
    iface: String(s.iface || ""),
    ip4: String(s.ip4 || ""),
    since: Number(s.since) || 0,
    rxBytes: Number(s.rxBytes) || 0,
    txBytes: Number(s.txBytes) || 0,
    detail: String(s.detail || ""),
    deps: {
      openconnect: deps.openconnect === true,
      nmOpenconnect: deps.nmOpenconnect === true,
      webkit: deps.webkit === true
    }
  }
}

function stateText(state, portal) {
  switch (state) {
    case "unconfigured": return "Set a portal to get started"
    case "missing-deps": return "Needs networkmanager-openconnect"
    case "authenticating": return "Signing in…"
    case "activating": return "Bringing the tunnel up…"
    case "connected": return "Connected"
    case "error": return "Something went wrong"
    default: return "Disconnected"
  }
}

function formatBytesPerSec(n) {
  n = Math.max(0, Number(n) || 0)
  if (n < 1024) return Math.round(n) + " B/s"
  if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB/s"
  return (n / (1024 * 1024)).toFixed(1) + " MB/s"
}

function formatDuration(seconds) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(seconds / 3600)
  var m = Math.floor((seconds % 3600) / 60)
  var s = seconds % 60
  if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m " + (s < 10 ? "0" : "") + s + "s"
  return s + "s"
}

function pushSample(history, value, max) {
  var next = (history || []).slice()
  next.push(Math.max(0, Number(value) || 0))
  while (next.length > max) next.shift()
  return next
}

// Strip scheme, path, and whitespace from whatever the user pasted so the
// portal setting is always a bare host (optionally with a port).
function cleanPortalHost(text) {
  var t = String(text || "").trim()
  t = t.replace(/^[a-z]+:\/\//i, "")
  t = t.replace(/\/.*$/, "")
  return t.toLowerCase()
}
