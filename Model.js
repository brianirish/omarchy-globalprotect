.pragma library

// Pure helpers for the GlobalProtect panel. No QML types here, so the same
// file runs under Node for tests/model_test.js.
//
// Text comes from the i18n/ catalogs through `tr`, anything with t(key) and
// tn(key, count): the panel's Commons.Translations in the shell, the
// tests/tr.js stand-in under Node. Numbers come through `formatNumber(value,
// decimals)` (Commons.I18n.formatNumber in the shell), so they take the
// language's digits and decimal separator, and clock times through `clock`
// ({ time(ms), dateTime(ms) }, the language's locale in the shell). Both
// default to plain formatting here. Portal hosts, gateway names, addresses
// and DNS data are passed through verbatim: they are data, shown as plain
// text.

// Fills %1, %2, ... from values in one pass, the way QML's String.arg()
// does, so a value that itself contains "%2" is never substituted again.
// Node has no arg().
function fill(template, values) {
  return String(template).replace(/%(\d)/g, function(match, n) {
    var value = values[Number(n) - 1]
    return value === undefined ? match : String(value)
  })
}

function number(value, formatNumber, decimals) {
  if (formatNumber) return formatNumber(value, decimals)
  return decimals === undefined ? String(value) : Number(value).toFixed(decimals)
}

function pad2(value, formatNumber) {
  return (value < 10 ? number(0, formatNumber) : "") + number(value, formatNumber)
}

var defaultClock = {
  time: function(ms) { return clockText(ms) },
  dateTime: function(ms) {
    var d = new Date(ms)
    return (d.getMonth() + 1) + "/" + d.getDate() + " " + clockText(ms)
  }
}

// The hero's rotating lines while connected. Each key is written out, so
// tests/i18n_test.js can see that every one is in en.json.
var PHRASE_COUNT = 8

function phraseText(index, tr) {
  switch (((Math.floor(Number(index) || 0) % PHRASE_COUNT) + PHRASE_COUNT) % PHRASE_COUNT) {
    case 0: return tr.t("phrase.tunnelSealed")
    case 1: return tr.t("phrase.packetsEscorted")
    case 2: return tr.t("phrase.routesGuarded")
    case 3: return tr.t("phrase.handshakeHeld")
    case 4: return tr.t("phrase.keysTurning")
    case 5: return tr.t("phrase.gatewayHumming")
    case 6: return tr.t("phrase.wiresWhispering")
    default: return tr.t("phrase.portalAligned")
  }
}

// A boolean setting. `omarchy bar set <id> <key> true` without --json
// stores the string "true", so the strings count as well.
function flag(value, fallback) {
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return fallback
}

function normalizeStatus(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var deps = s.deps && typeof s.deps === "object" ? s.deps : {}
  return {
    state: typeof s.state === "string" && s.state !== "" ? s.state : "disconnected",
    // Shared intent, kept by the CLI so every bar's widget agrees the last teardown was ours.
    userOff: s.userOff === true,
    pausedUntil: Number(s.pausedUntil) || 0,
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
    ip6: String(s.ip6 || ""),
    resolver: {
      dns: s.resolver && Array.isArray(s.resolver.dns) ? s.resolver.dns.map(String) : [],
      domains: s.resolver && Array.isArray(s.resolver.domains) ? s.resolver.domains.map(String) : [],
      active: !!(s.resolver && s.resolver.active === true),
      defaultRoute: !!(s.resolver && s.resolver.defaultRoute === true)
    },
    splitDns: ["not-needed", "needed", "enabled"].indexOf(s.splitDns) >= 0 ? s.splitDns : "not-needed",
    portals: Array.isArray(s.portals) ? s.portals.map(String) : [],
    policy: normalizePolicy(s.policy),
    welcomeAvailable: s.welcomeAvailable === true,
    detail: String(s.detail || ""),
    deps: {
      openconnect: deps.openconnect === true,
      nmOpenconnect: deps.nmOpenconnect === true,
      webkit: deps.webkit === true
    }
  }
}

function stateText(state, tr) {
  switch (state) {
    case "unconfigured": return tr.t("state.unconfigured")
    case "missing-deps": return fill(tr.t("state.missingDeps"), ["networkmanager-openconnect"])
    case "authenticating": return tr.t("state.authenticating")
    case "activating": return tr.t("state.activating")
    case "connected": return tr.t("state.connected")
    case "error": return tr.t("state.error")
    default: return tr.t("state.disconnected")
  }
}

// Session rows: what the tunnel negotiated, in the official client's words.
function tunnelText(protocol, tr) {
  if (protocol === "esp") return tr.t("tunnel.esp")
  if (protocol === "ssl") return tr.t("tunnel.ssl")
  return "—"
}

function gatewayText(host, ip) {
  if (host === "" && ip === "") return "—"
  if (host === "") return ip
  if (ip === "" || ip === host) return host
  return host + " (" + ip + ")"
}

function routesText(routes, fullTunnel, tr) {
  if (!routes || routes.length === 0) return "—"
  if (fullTunnel) return tr.t("routes.full")
  return fill(tr.t("routes.split"), [routes.join(", ")])
}

function dnsText(dns, domains) {
  var parts = []
  if (dns && dns.length > 0) parts.push(dns.join(", "))
  if (domains && domains.length > 0) parts.push(domains.join(", "))
  return parts.length > 0 ? parts.join(" · ") : "—"
}

// The DNS row: what resolved actually uses on the tunnel, else what was pushed and why it is idle.
function resolverText(resolver, pushedDns, pushedDomains, splitDns, tr) {
  if (resolver && resolver.active && resolver.dns.length > 0) {
    var scope = resolver.domains.indexOf("~.") >= 0 ? tr.t("dns.allQueries") : (resolver.domains.length > 0 ? resolver.domains.join(", ") : "")
    return resolver.dns.join(", ") + (scope !== "" ? " · " + scope : "")
  }
  var pushed = dnsText(pushedDns, pushedDomains)
  if (pushed === "—") return "—"
  return fill(splitDns === "needed" ? tr.t("dns.notApplied") : tr.t("dns.idle"), [pushed])
}

function addressText(ip4, ip6) {
  if (ip4 === "" && ip6 === "") return "—"
  if (ip6 === "") return ip4
  if (ip4 === "") return ip6
  return ip4 + " · " + ip6
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

function reportsAsText(h, tr) {
  if (!h || h.os === "") return "—"
  return h.clientVersion !== "" ? fill(tr.t("host.reportsAsClient"), [h.os, h.clientVersion]) : h.os
}

function hostText(h) {
  if (!h || (h.hostName === "" && h.hostId === "")) return "—"
  if (h.hostId === "") return h.hostName
  return h.hostName + " · " + h.hostId
}

function claimsText(h, tr) {
  if (!h) return "—"
  return h.products.length > 0 ? h.products.join(", ") : tr.t("host.infoOnly")
}

// Portal-driven app settings (agent-config), as parsed by the CLI.
function normalizePolicy(raw) {
  var p = raw && typeof raw === "object" ? raw : {}
  return {
    portalName: String(p.portalName || ""),
    version: String(p.version || ""),
    configDigest: String(p.configDigest || ""),
    connectMethod: String(p.connectMethod || ""),
    refreshConfigInterval: Number(p.refreshConfigInterval) || 0,
    tunnelMtu: Number(p.tunnelMtu) || 0,
    sslOnly: p.sslOnly === true,
    rediscoverNetwork: p.rediscoverNetwork !== false,
    enableSignout: p.enableSignout !== false,
    canChangePortal: p.canChangePortal !== false,
    welcomePage: String(p.welcomePage || "")
  }
}

// Settings the portal wants changed, as {key: value} — empty when everything already matches.
function policyChanges(policy, settings) {
  var out = {}
  if (!policy) return out
  if (policy.connectMethod === "user-logon" && settings.connectMethod !== "always-on") out.connectMethod = "always-on"
  if (policy.connectMethod === "on-demand" && settings.connectMethod !== "on-demand") out.connectMethod = "on-demand"
  if (policy.tunnelMtu > 0 && settings.mtu !== policy.tunnelMtu) out.mtu = policy.tunnelMtu
  if (policy.sslOnly && settings.sslOnly !== true) out.sslOnly = true
  return out
}

function normalizeHipStatus(raw) {
  var h = raw && typeof raw === "object" ? raw : {}
  return { lastCheck: String(h.lastCheck || ""), lastSubmit: String(h.lastSubmit || ""), warning: String(h.warning || ""), warningAt: String(h.warningAt || "") }
}

// A journal timestamp: the time alone today, the date and time otherwise.
function timestampText(iso, clock, nowMs) {
  if (!iso) return "—"
  var d = new Date(iso)
  if (isNaN(d.getTime())) return iso
  var c = clock || defaultClock
  var now = new Date(nowMs === undefined ? Date.now() : nowMs)
  return d.toDateString() === now.toDateString() ? c.time(d.getTime()) : c.dateTime(d.getTime())
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
    portalName: String(d.portalName || ""),
    policy: normalizePolicy(d.policy)
  }
}

function latencyText(ms, tr, formatNumber) {
  if (ms === -2 || ms === undefined || ms === null) return ""
  if (ms < 0) return tr.t("gateways.unreachable")
  return number(ms, formatNumber) + " ms"
}

function priorityText(p, tr, formatNumber) {
  return p > 0 ? fill(tr.t("gateways.priorityShort"), [number(p, formatNumber)]) : ""
}

function gatewayMeta(g, tr, formatNumber) {
  var parts = []
  if (g.host !== "" && g.host !== g.description) parts.push(g.host)
  var pr = priorityText(g.priority, tr, formatNumber)
  if (pr !== "") parts.push(pr)
  if (g.manual) parts.push(tr.t("gateways.manual"))
  var lt = latencyText(g.latencyMs, tr, formatNumber)
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

// Did the tunnel go down without us asking? Read the user's switch-off intent
// (userOff) as it was when the status was sampled: the Service must call this
// BEFORE it resets that intent, or a user's own disconnect looks like an outage
// and Always-Off restores the tunnel it was just told to drop.
function tunnelDropped(ctx) {
  var c = ctx || {}
  return c.previous === "connected" && c.state !== "connected"
      && !c.disconnecting && !c.userOff && !c.reconnectPending
}

// A status poll that straddles one of our own transitions reports the state
// from before it. Ignore "disconnected" while our connect runs, and "connected"
// while our disconnect runs or right after the user switched off.
function snapshotIsStale(ctx) {
  var c = ctx || {}
  if (c.connecting && c.state === "disconnected") return true
  if ((c.disconnecting || c.userOff) && c.state === "connected") return true
  return false
}

// One bar per screen means one copy of the widget per screen. Exactly one of
// them, the one on the first screen, acts on shared events: notifications,
// tunnel restoration, Always-On, the portal refresh. The rest display and
// take clicks. A lone or unidentified screen always acts.
function isLeader(screenName, screenNames) {
  if (!screenNames || screenNames.length === 0 || !screenName) return true
  return screenName === screenNames[0]
}

// The installed version, from manifest.json's text; "" when unreadable.
function manifestVersion(text) {
  try {
    var v = JSON.parse(String(text || "")).version
    return v ? String(v) : ""
  } catch (e) {
    return ""
  }
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
function autoText(reason, pausedUntil, nextAttemptAt, now, tr, formatNumber, clock) {
  switch (reason) {
    case "paused": return fill(tr.t("auto.pausedUntil"), [(clock || defaultClock).time(pausedUntil)])
    case "captive": return tr.t("auto.captive")
    case "offline": return tr.t("auto.offline")
    case "backoff": return fill(tr.t("auto.retryingIn"), [formatDuration(Math.max(1, Math.ceil((nextAttemptAt - now) / 1000)), tr, formatNumber)])
    default: return ""
  }
}

// Units (B/s, KB/s, MB/s) stay as they are in every language; the number
// takes the language's digits and decimal separator.
function formatBytesPerSec(n, formatNumber) {
  n = Math.max(0, Number(n) || 0)
  if (n < 1024) return number(Math.round(n), formatNumber) + " B/s"
  if (n < 1024 * 1024) return number(n / 1024, formatNumber, n < 10240 ? 1 : 0) + " KB/s"
  return number(n / (1024 * 1024), formatNumber, 1) + " MB/s"
}

function formatDuration(seconds, tr, formatNumber) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(seconds / 3600)
  var m = Math.floor((seconds % 3600) / 60)
  var s = seconds % 60
  if (h > 0) return fill(tr.t("duration.hoursMinutes"), [number(h, formatNumber), pad2(m, formatNumber)])
  if (m > 0) return fill(tr.t("duration.minutesSeconds"), [number(m, formatNumber), pad2(s, formatNumber)])
  return fill(tr.t("duration.seconds"), [number(s, formatNumber)])
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
