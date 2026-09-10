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
    connectivity: ["full", "limited", "portal", "none"].indexOf(s.connectivity) >= 0 ? s.connectivity : "unknown",
    protocol: s.protocol === "esp" || s.protocol === "ssl" ? s.protocol : "",
    gatewayIp: String(s.gatewayIp || ""),
    routes: Array.isArray(s.routes) ? s.routes.map(String) : [],
    fullTunnel: s.fullTunnel === true,
    dns: Array.isArray(s.dns) ? s.dns.map(String) : [],
    searchDomains: Array.isArray(s.searchDomains) ? s.searchDomains.map(String) : [],
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

// Session rows: what the tunnel negotiated, in the official client's words.
function tunnelText(protocol) {
  if (protocol === "esp") return "IPSec · ESP over UDP"
  if (protocol === "ssl") return "SSL · TCP 443"
  return "—"
}

function gatewayText(host, ip) {
  if (host === "" && ip === "") return "—"
  if (host === "") return ip
  if (ip === "" || ip === host) return host
  return host + " (" + ip + ")"
}

function routesText(routes, fullTunnel) {
  if (!routes || routes.length === 0) return "—"
  if (fullTunnel) return "Full tunnel"
  return "Split · " + routes.join(", ")
}

function dnsText(dns, domains) {
  var parts = []
  if (dns && dns.length > 0) parts.push(dns.join(", "))
  if (domains && domains.length > 0) parts.push(domains.join(", "))
  return parts.length > 0 ? parts.join(" · ") : "—"
}

// Host state (the official client's Host Profile tab): what hipreport.sh claims.
function normalizeHostState(raw) {
  var d = raw && typeof raw === "object" ? raw : {}
  var r = d.report && typeof d.report === "object" ? d.report : null
  return {
    enabled: d.enabled === true,
    error: String(d.error || ""),
    os: r ? String(r.os || "") : "",
    clientVersion: r ? String(r.clientVersion || "") : "",
    hostName: r ? String(r.hostName || "") : "",
    hostId: r ? String(r.hostId || "") : "",
    products: r && Array.isArray(r.products) ? r.products.map(String) : []
  }
}

function reportsAsText(h) {
  if (!h || h.os === "") return "—"
  return h.clientVersion !== "" ? h.os + " · client " + h.clientVersion : h.os
}

function hostText(h) {
  if (!h || (h.hostName === "" && h.hostId === "")) return "—"
  if (h.hostId === "") return h.hostName
  return h.hostName + " · " + h.hostId
}

function claimsText(h) {
  if (!h) return "—"
  return h.products.length > 0 ? h.products.join(", ") : "Host info only"
}

// Gateways (the official client's gateway picker).
function normalizeGateways(raw) {
  var d = raw && typeof raw === "object" ? raw : {}
  var list = Array.isArray(d.gateways) ? d.gateways : []
  return {
    gateways: list.map(function(g) {
      return {
        name: String(g.name || ""),
        host: String(g.host || ""),
        description: String(g.description || g.host || ""),
        priority: Number(g.priority) || 0,
        manual: g.manual === true,
        latencyMs: (typeof g.latencyMs === "number") ? g.latencyMs : -2   // -2 = not probed, -1 = unreachable
      }
    }),
    best: String(d.best || ""),
    fetchedAt: Number(d.fetchedAt) || 0,
    probedAt: Number(d.probedAt) || 0,
    portalName: String(d.portalName || "")
  }
}

function latencyText(ms) {
  if (ms === -2 || ms === undefined || ms === null) return ""
  if (ms < 0) return "unreachable"
  return ms + " ms"
}

function priorityText(p) {
  return p > 0 ? "P" + p : ""
}

function gatewayMeta(g) {
  var parts = []
  if (g.host !== "" && g.host !== g.description) parts.push(g.host)
  var pr = priorityText(g.priority)
  if (pr !== "") parts.push(pr)
  if (g.manual) parts.push("manual")
  var lt = latencyText(g.latencyMs)
  if (lt !== "") parts.push(lt)
  return parts.join(" · ")
}

// Always-On / tunnel restoration. One pure decision so the service stays a thin loop.
// ctx: { alwaysOn, restore, configured, depsOk, state, connectivity, pausedUntil, now,
//        nextAttemptAt, inFlight, userOff }
// -> { action: "connect" | "wait" | "none", reason }
function autoConnectDecision(ctx) {
  var c = ctx || {}
  if (c.inFlight || c.userOff) return { action: "none", reason: "busy" }
  if (!c.configured || !c.depsOk) return { action: "none", reason: "unready" }
  if (c.state === "connected" || c.state === "authenticating" || c.state === "activating") return { action: "none", reason: "up" }
  if (!(c.alwaysOn || c.restore)) return { action: "none", reason: "" }
  if (c.pausedUntil > c.now) return { action: "none", reason: "paused" }
  if (c.connectivity === "portal") return { action: "wait", reason: "captive" }
  if (c.connectivity === "none" || c.connectivity === "limited") return { action: "wait", reason: "offline" }
  if (c.nextAttemptAt > c.now) return { action: "wait", reason: "backoff" }
  return { action: "connect", reason: c.alwaysOn ? "always-on" : "restore" }
}

// 30 s, 60 s, 120 s, ... capped at 10 min.
function nextBackoffMs(failures) {
  var n = Math.max(1, Math.floor(Number(failures) || 0))
  return Math.min(600000, 30000 * Math.pow(2, n - 1))
}

function clockText(ms) {
  var d = new Date(ms)
  var h = d.getHours(), m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

// Hero meta line while Always-On is holding back or waiting.
function autoText(reason, pausedUntil, nextAttemptAt, now) {
  switch (reason) {
    case "paused": return "Always-On paused until " + clockText(pausedUntil)
    case "captive": return "Captive portal — sign in to the network first"
    case "offline": return "Waiting for the network"
    case "backoff": return "Retrying in " + Math.max(1, Math.ceil((nextAttemptAt - now) / 1000)) + "s"
    default: return ""
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
