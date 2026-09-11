import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Headless state machine for the GlobalProtect panel. Owns every process
// (status polls, the connect/disconnect CLI runs, the nmcli event stream) and
// exposes plain properties so Panel.qml only renders.
Item {
  id: root

  property var settings: ({})
  property string cliPath: ""
  property bool panelOpen: false

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  readonly property string portal: Model.cleanPortalHost(setting("portal", ""))
  readonly property string gateway: String(setting("gateway", "")).trim()
  readonly property string clientOs: ["win", "linux", "mac"].indexOf(String(setting("clientOs", "win"))) >= 0 ? String(setting("clientOs", "win")) : "win"
  readonly property bool hipReport: setting("hipReport", false) === true
  readonly property string authInterface: ["auto", "portal", "gateway"].indexOf(String(setting("authInterface", "auto"))) >= 0 ? String(setting("authInterface", "auto")) : "auto"
  readonly property bool debug: setting("debug", false) === true
  readonly property bool alwaysOn: String(setting("connectMethod", "on-demand")) === "always-on"
  readonly property bool systemBrowser: String(setting("samlBrowser", "embedded")) === "system"
  readonly property string proxy: String(setting("proxy", "")).trim()
  readonly property string certificate: String(setting("certificate", "")).trim()
  readonly property string certificateKey: String(setting("certificateKey", "")).trim()
  readonly property string dnsMode: ["auto", "split", "off"].indexOf(String(setting("dnsMode", "auto"))) >= 0 ? String(setting("dnsMode", "auto")) : "auto"
  readonly property bool sslOnly: setting("sslOnly", false) === true
  readonly property int mtu: Math.max(0, parseInt(String(setting("mtu", 0)), 10) || 0)
  readonly property bool blockLan: setting("blockLan", false) === true
  readonly property bool followPortal: setting("followPortal", true) !== false
  readonly property int pauseMinutes: Math.min(1440, Math.max(1, parseInt(String(setting("pauseMinutes", 30)), 10) || 30))
  readonly property int refreshIntervalSec: Math.min(120, Math.max(2, parseInt(String(setting("refreshIntervalSec", 5)), 10) || 5))

  // unconfigured | missing-deps | disconnected | authenticating | activating | connected | error
  property string state: "disconnected"
  property string detail: ""
  property string gatewayHost: ""
  property string iface: ""
  property string ip4: ""
  property double since: 0
  property double rxBytes: 0
  property double txBytes: 0
  property real rxRate: 0
  property real txRate: 0
  property var rxHistory: []
  property var txHistory: []
  property string username: ""
  property bool hasSession: false
  property string connectivity: "unknown"
  property string protocol: ""
  property string gatewayIp: ""
  property var routes: []
  property bool fullTunnel: false
  property var dns: []
  property var searchDomains: []
  property string ip6: ""
  property var resolver: ({ dns: [], domains: [], active: false, defaultRoute: false })
  property string splitDns: "not-needed"
  property var portals: []
  property var policy: Model.normalizePolicy(null)
  property bool welcomeAvailable: false
  property var hipStatus: Model.normalizeHipStatus(null)
  property string _lastHipWarningAt: ""
  signal policyReceived(var policy)
  property var deps: ({ openconnect: false, nmOpenconnect: false, webkit: false })
  property string actionStatus: ""
  property string lastError: ""
  property var hostState: Model.normalizeHostState(null)
  // Only the leader (the widget on the first screen; see Model.isLeader) acts
  // on shared events, so two bars do not notify, restore, or connect twice.
  property bool leader: true
  property double _clearedPause: 0
  // Always-On / tunnel restoration bookkeeping (see Model.autoConnectDecision).
  property double pausedUntil: 0
  property int failures: 0
  property double nextAttemptAt: 0
  property bool wantRestore: false
  property bool captiveNotified: false
  property string autoReason: ""
  readonly property bool paused: pausedUntil > Date.now()
  property var gatewayList: Model.normalizeGateways(null)
  property string gatewaysError: ""
  readonly property bool gatewaysBusy: gatewaysProc.running
  property bool everPolled: false

  // Optimistic intent: -1 follow reality, 0 turning off, 1 turning on.
  property int _desired: -1
  property double _lastSampleMs: 0
  property double _lastRx: 0
  property double _lastTx: 0
  property string _connectErr: ""

  readonly property bool connected: state === "connected"
  readonly property bool transitioning: state === "authenticating" || state === "activating" || connectProc.running || disconnectProc.running
  readonly property bool active: _desired === -1 ? (connected || state === "authenticating" || state === "activating") : _desired === 1
  readonly property bool busy: transitioning || forgetProc.running
  readonly property bool collectingLogs: collectLogsProc.running
  // The CLI remembers the last portal itself, so a widget whose settings have not
  // been injected yet (plugin hot-reload) still knows it is configured.
  property string reportedPortal: ""
  readonly property bool configured: portal !== "" || reportedPortal !== ""
  readonly property bool depsOk: deps.openconnect === true && deps.nmOpenconnect === true && deps.webkit === true

  function cliArgs(cmd, extra) {
    var args = [cliPath, cmd, "--portal", portal, "--gateway", gateway, "--client-os", clientOs, "--auth-interface", authInterface]
    if (hipReport) args.push("--hip")
    if (debug) args.push("--debug")
    if (systemBrowser) args.push("--browser")
    if (proxy !== "") args.push("--proxy", proxy)
    if (certificate !== "") args.push("--certificate", certificate)
    if (certificateKey !== "") args.push("--key", certificateKey)
    if (sslOnly) args.push("--ssl-only")
    if (mtu > 0) args.push("--mtu", String(mtu))
    if (blockLan) args.push("--block-lan")
    args.push("--dns-mode", dnsMode)
    return args.concat(extra || [])
  }

  function refresh() {
    if (cliPath === "" || statusProc.running) return
    statusProc.command = cliArgs("status")
    statusProc.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function applyStatus(raw) {
    var s = Model.normalizeStatus(raw)
    var previous = state
    // The intent as it was when this poll was sampled. Ours (_desired) covers this
    // widget; s.userOff is the CLI's record of it, which the widget on the OTHER bar
    // needs: each bar runs its own Service, and without it that one saw the tunnel
    // vanish, called it an outage, and restored what the user had just switched off.
    var userOff = _desired === 0 || s.userOff
    if (s.pausedUntil > pausedUntil && s.pausedUntil !== _clearedPause) pausedUntil = s.pausedUntil  // a pause set from any bar
    everPolled = true
    // A poll that straddles one of our own transitions reports the state from
    // before it: "disconnected" while our connect runs (the run file is the
    // truth), "connected" after our disconnect finished. Applying the latter
    // made the next real poll look like an outage, which Always-Off restored.
    var stale = Model.snapshotIsStale({ state: s.state, connecting: connectProc.running,
                                        disconnecting: disconnectProc.running, userOff: userOff })
    if (!stale) state = s.state
    if (stale || s.state !== previous) trace("status raw=" + s.state + " prev=" + previous + " stale=" + stale + " userOff=" + userOff)
    detail = s.detail
    reportedPortal = s.portal
    gatewayHost = s.gateway
    iface = s.iface
    ip4 = s.ip4
    since = s.since
    username = s.username
    hasSession = s.hasSession
    connectivity = s.connectivity
    protocol = s.protocol
    gatewayIp = s.gatewayIp
    routes = s.routes
    fullTunnel = s.fullTunnel
    dns = s.dns
    searchDomains = s.searchDomains
    ip6 = s.ip6
    resolver = s.resolver
    splitDns = s.splitDns
    portals = s.portals
    policy = s.policy
    welcomeAvailable = s.welcomeAvailable
    deps = s.deps
    if (s.state === "connected") sample(s.rxBytes, s.txBytes)
    else resetSamples()
    if (_desired !== -1 && !connectProc.running && !disconnectProc.running && connected === (_desired === 1)) _desired = -1
    if (leader && Model.tunnelDropped({ previous: previous, state: state, disconnecting: disconnectProc.running,
                                        userOff: userOff, reconnectPending: reconnectAfterDown.running })) {
      trace("tunnelDropped -> restore")
      // Not our doing: restore it (the official client's tunnel restoration), re-signing in if the cookie expired.
      wantRestore = true
      notify("Disconnected", "The GlobalProtect tunnel went down; reconnecting", "network-vpn-disconnected")
    }
    if (leader && state === "connected" && previous !== "connected" && previous !== "")
      notify("Connected", gatewayHost !== "" ? "Through " + gatewayHost : "The GlobalProtect tunnel is up", "network-vpn")
    if (state === "connected") { wantRestore = false; failures = 0; nextAttemptAt = 0 }
    evaluateAuto()
  }

  function evaluateAuto() {
    if (!leader) return
    var now = Date.now()
    var d = Model.autoConnectDecision({
      alwaysOn: alwaysOn, restore: wantRestore, configured: configured, depsOk: depsOk, state: state,
      connectivity: connectivity, pausedUntil: pausedUntil, now: now, nextAttemptAt: nextAttemptAt,
      inFlight: connectProc.running || disconnectProc.running || reconnectAfterDown.running, userOff: _desired === 0
    })
    autoReason = d.action === "none" && d.reason !== "paused" ? "" : d.reason
    if (connectivity === "full") captiveNotified = false
    if (d.reason === "captive" && !captiveNotified) {
      captiveNotified = true
      notify("Captive portal", "Sign in to this network first; GlobalProtect connects afterwards", "network-wireless-hotspot")
    }
    if (d.action === "connect") { trace("evaluateAuto -> connect reason=" + d.reason); connectVpn(false, "auto:" + d.reason) }
  }

  function pause(minutes) {
    pausedUntil = Date.now() + minutes * 60000
    wantRestore = false
    failures = 0
    nextAttemptAt = 0
    if (cliPath !== "") Quickshell.execDetached(cliArgs("pause", ["--minutes", String(minutes)]))  // every bar honours it
    flash("Always-On paused for " + minutes + " min")
    evaluateAuto()
  }

  function resume() {
    _clearedPause = pausedUntil  // a status poll already in flight may still carry it
    pausedUntil = 0
    nextAttemptAt = 0
    failures = 0
    if (cliPath !== "") Quickshell.execDetached(cliArgs("pause", ["--minutes", "0"]))
    flash("Always-On resumed")
    // Connect from whichever bar was clicked; the leader would otherwise wait a tick.
    if (alwaysOn && !connected && !transitioning) connectVpn(false, "resume")
    else evaluateAuto()
  }

  function togglePause() {
    if (!alwaysOn) return
    if (paused) resume()
    else pause(pauseMinutes)
  }

  function sample(rx, tx) {
    var now = Date.now()
    if (_lastSampleMs > 0 && now > _lastSampleMs && rx >= _lastRx && tx >= _lastTx) {
      var dt = (now - _lastSampleMs) / 1000
      rxRate = (rx - _lastRx) / dt
      txRate = (tx - _lastTx) / dt
      rxHistory = Model.pushSample(rxHistory, rxRate, 40)
      txHistory = Model.pushSample(txHistory, txRate, 40)
    }
    _lastSampleMs = now
    _lastRx = rx
    _lastTx = tx
    rxBytes = rx
    txBytes = tx
  }

  function resetSamples() {
    _lastSampleMs = 0
    _lastRx = 0
    _lastTx = 0
    rxRate = 0
    txRate = 0
    rxHistory = []
    txHistory = []
    rxBytes = 0
    txBytes = 0
  }

  function connectVpn(fresh, why) {
    trace("connectVpn fresh=" + (fresh === true) + " why=" + (why || "?"))
    if (!configured || connectProc.running) return
    if (!depsOk) { lastError = "Install networkmanager-openconnect first"; return }
    pausedUntil = 0
    _desired = 1
    lastError = ""
    _connectErr = ""
    actionStatus = ""
    state = "authenticating"
    connectProc.command = cliArgs("connect", fresh === true ? ["--fresh"] : [])
    connectProc.running = true
  }

  function disconnectVpn(why) {
    trace("disconnectVpn why=" + (why || "?"))
    if (disconnectProc.running) return
    _desired = 0
    lastError = ""
    wantRestore = false
    // Turning Always-On off by hand means "leave me alone for a while" (the official client's Disable).
    if (alwaysOn) { pausedUntil = Date.now() + pauseMinutes * 60000; flash("Disconnecting · Always-On paused for " + pauseMinutes + " min") }
    if (connectProc.running) { connectProc.signal(15); return }
    disconnectProc.command = cliArgs("disconnect", alwaysOn ? ["--pause-minutes", String(pauseMinutes)] : [])
    disconnectProc.running = true
  }

  function toggle(why) {
    trace("toggle active=" + active + " why=" + (why || "?"))
    if (active) disconnectVpn("toggle:" + (why || "?"))
    else connectVpn(false, "toggle:" + (why || "?"))
  }

  function signInAgain() {
    if (connectProc.running) return
    if (connected || state === "activating") {
      _desired = 1
      reconnectAfterDown.fresh = true
      reconnectAfterDown.start()
      disconnectProc.command = cliArgs("disconnect")
      disconnectProc.running = true
    } else {
      connectVpn(true, "signInAgain")
    }
  }

  // The official client's "rediscover network": drop the tunnel and come back
  // through the stored session, so routes and the gateway get renegotiated.
  function rediscover() {
    if (connectProc.running || disconnectProc.running) return
    if (!connected && state !== "activating") { connectVpn(false, "rediscover"); return }
    _desired = 1
    lastError = ""
    flash("Rediscovering network…")
    reconnectAfterDown.fresh = false
    reconnectAfterDown.start()
    disconnectProc.command = cliArgs("disconnect")
    disconnectProc.running = true
  }

  // What the HIP report would say right now; cheap, so refresh whenever it could have changed.
  function loadHostState() {
    if (cliPath === "" || hostStateProc.running) return
    hostStateProc.command = cliArgs("hip-report")
    hostStateProc.running = true
  }

  onPanelOpenChanged: if (panelOpen) { loadHostState(); loadGateways(false); loadHipStatus() }

  function loadHipStatus() {
    if (cliPath === "" || hipStatusProc.running || !hipReport) return
    hipStatusProc.command = cliArgs("hip-status")
    hipStatusProc.running = true
  }

  function showWelcome() {
    if (cliPath === "" || !welcomeAvailable) return
    Quickshell.execDetached(cliArgs("welcome", ["--show"]))
  }

  // The official client refreshes the portal config on the portal's interval; with the
  // stored portal cookie this is silent (--quiet never opens a window).
  property double _lastQuietRefresh: 0

  function maybeRefreshConfig() {
    if (!connected || gatewaysProc.running || cliPath === "") return
    var hours = policy.refreshConfigInterval
    if (hours <= 0) return
    var now = Date.now()
    var age = now / 1000 - gatewayList.fetchedAt
    if (gatewayList.fetchedAt > 0 && age < hours * 3600) return
    if (now - _lastQuietRefresh < 3600000) return  // a portal that rejects the stored cookie is asked at most hourly
    _lastQuietRefresh = now
    gatewaysProc.command = cliArgs("gateways", ["--refresh", "--quiet", "--probe"])
    gatewaysProc.running = true
  }
  onHipReportChanged: if (panelOpen) loadHostState()
  onClientOsChanged: if (panelOpen) loadHostState()

  // Gateway list from the portal. refresh=true signs in at the portal (a window may
  // flash) and fetches it; otherwise the cached list is shown and re-probed.
  function loadGateways(refresh) {
    if (cliPath === "" || !configured || gatewaysProc.running) return
    gatewaysError = ""
    if (refresh) flash("Fetching gateways…")
    gatewaysProc.command = cliArgs("gateways", refresh ? ["--refresh", "--probe"] : ["--probe"])
    gatewaysProc.running = true
  }

  function refreshGateways() { loadGateways(true) }

  // The official client's "Collect Logs": a scrubbed tarball for troubleshooting.
  function collectLogs() {
    if (collectLogsProc.running) return
    flash("Collecting logs…")
    collectLogsProc.command = cliArgs("collect-logs")
    collectLogsProc.running = true
  }

  function forget() {
    if (forgetProc.running) return
    forgetProc.command = cliArgs("forget")
    forgetProc.running = true
  }

  function copyAddress() {
    if (ip4 === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(ip4) + " | wl-copy"])
    flash("Copied " + ip4)
  }

  function flash(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // One journal line per decision (journalctl --user | grep 'gp-trace'); rare events only.
  Component.onCompleted: trace("service up")  // one line per bar at startup: how many copies, which leads

  function trace(what) {
    console.log("gp-trace " + what + " | leader=" + leader + " state=" + state + " desired=" + _desired + " alwaysOn=" + alwaysOn
                + " restore=" + wantRestore + " paused=" + paused + " conn=" + connectProc.running
                + " disc=" + disconnectProc.running + " rad=" + reconnectAfterDown.running)
  }

  function notify(title, body, icon) {
    Quickshell.execDetached(["notify-send", "-a", "GlobalProtect", "-i", icon, "-e", title, body])
  }

  Timer {
    id: refreshTimer
    interval: (root.panelOpen ? root.refreshIntervalSec : root.refreshIntervalSec * 4) * 1000
    repeat: true
    running: root.cliPath !== ""
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // One-second samples feed the throughput sparkline while it is on screen.
  Timer {
    id: fastSample
    interval: 1000
    repeat: true
    running: root.panelOpen && root.connected
    onTriggered: root.refresh()
  }

  Timer { id: monitorDebounce; interval: 400; repeat: false; onTriggered: root.refresh() }
  // Always-On heartbeat: cheap, and it is what turns "retry in 30 s" into an attempt.
  Timer { id: autoTick; interval: 5000; repeat: true; running: root.leader && root.cliPath !== "" && (root.alwaysOn || root.wantRestore); onTriggered: root.evaluateAuto() }
  Timer { id: delayedRefresh; interval: 600; repeat: false; onTriggered: root.refresh() }
  Timer { id: actionStatusTimer; interval: 2200; repeat: false; onTriggered: root.actionStatus = "" }
  // Comes back after a deliberate disconnect: fresh=true forces the sign-in
  // window (sign in again), fresh=false reuses the stored session (rediscover).
  Timer { id: reconnectAfterDown; interval: 800; repeat: false; property bool fresh: true; onTriggered: root.connectVpn(fresh, "reconnectAfterDown") }
  Timer { id: monitorRestart; interval: 3000; repeat: false; onTriggered: monitorProc.running = true }

  // A poll that never returns would otherwise block every later refresh.
  Timer {
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (statusProc.running) statusProc.running = false
  }

  Process {
    id: statusProc
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) {
      var parsed = null
      try { parsed = JSON.parse(statusOut.text) } catch (e) {}
      if (code === 0 && parsed) root.applyStatus(parsed)
    }
  }

  // NetworkManager narrates every change; a debounced refresh keeps the icon
  // honest without hammering nmcli.
  Process {
    id: monitorProc
    command: ["nmcli", "monitor"]
    running: true
    stdout: SplitParser { onRead: function(line) { monitorDebounce.restart() } }
    onExited: monitorRestart.start()
  }

  Process {
    id: connectProc
    stdout: SplitParser {
      onRead: function(line) {
        var m = String(line).match(/^phase=(\S+)/)
        if (!m) return
        if (m[1] === "preparing" || m[1] === "signing-in" || m[1] === "authenticating") root.state = "authenticating"
        else if (m[1] === "activating") root.state = "activating"
        else if (m[1] === "connected") root.state = "connected"
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var m = String(line).match(/^error=(.*)$/)
        if (m) root._connectErr = m[1]
      }
    }
    onExited: function(code) {
      root.trace("connectProc exited code=" + code)
      if (root._desired === 0) {
        // The user turned it off mid-flight: make sure NM is not left activating.
        disconnectProc.command = root.cliArgs("disconnect")
        disconnectProc.running = true
      } else if (code === 0) {
        root.lastError = ""
        root.failures = 0
        root.nextAttemptAt = 0
        root.wantRestore = false
      } else if (code === 2) {
        root._desired = -1
        root.state = "disconnected"
        if (root.alwaysOn || root.wantRestore) {
          root.wantRestore = false
          root.pausedUntil = Date.now() + root.pauseMinutes * 60000
          root.flash("Sign-in cancelled · Always-On paused for " + root.pauseMinutes + " min")
        } else {
          root.flash("Sign-in cancelled")
        }
      } else {
        root._desired = -1
        root.state = "error"
        root.lastError = root._connectErr !== "" ? root._connectErr : "Connection failed"
        root.failures += 1
        root.nextAttemptAt = Date.now() + Model.nextBackoffMs(root.failures)
        root.notify("Connection failed", root.lastError, "dialog-error")
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: disconnectProc
    stderr: StdioCollector { id: disconnectErr; waitForEnd: true }
    onExited: function(code) {
      root.trace("disconnectProc exited code=" + code)
      if (code !== 0) {
        root._desired = -1
        root.lastError = String(disconnectErr.text || "").replace(/^error=/m, "").trim() || "Disconnect failed"
      } else if (!reconnectAfterDown.running) {
        root.state = "disconnected"
        root.notify("Disconnected", "The GlobalProtect tunnel is closed", "network-vpn-disconnected")
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: hostStateProc
    stdout: StdioCollector { id: hostStateOut; waitForEnd: true }
    onExited: function(code) {
      var parsed = null
      try { parsed = JSON.parse(hostStateOut.text) } catch (e) {}
      if (code === 0 && parsed) root.hostState = Model.normalizeHostState(parsed)
    }
  }

  Process {
    id: gatewaysProc
    stdout: StdioCollector { id: gatewaysOut; waitForEnd: true }
    stderr: StdioCollector { id: gatewaysErr; waitForEnd: true }
    onExited: function(code) {
      var parsed = null
      try { parsed = JSON.parse(gatewaysOut.text) } catch (e) {}
      var quiet = String(gatewaysProc.command).indexOf("--quiet") >= 0
      if (code === 0 && parsed) {
        root.gatewayList = Model.normalizeGateways(parsed)
        if (String(gatewaysProc.command).indexOf("--refresh") >= 0) {
          if (!quiet) root.flash(root.gatewayList.gateways.length + " gateway" + (root.gatewayList.gateways.length === 1 ? "" : "s") + " from the portal")
          root.policy = root.gatewayList.policy
          root.policyReceived(root.gatewayList.policy)
          delayedRefresh.restart()
        }
      } else if (code === 2) {
        root.flash("Gateway refresh cancelled")
      } else if (code === 4 || quiet) {
        // silent refresh not possible right now; try again on the next tick
      } else {
        root.gatewaysError = String(gatewaysErr.text || "").replace(/^error=/m, "").trim() || "Could not fetch gateways"
      }
    }
  }

  Process {
    id: hipStatusProc
    stdout: StdioCollector { id: hipStatusOut; waitForEnd: true }
    onExited: function(code) {
      var parsed = null
      try { parsed = JSON.parse(hipStatusOut.text) } catch (e) {}
      if (code !== 0 || !parsed) return
      root.hipStatus = Model.normalizeHipStatus(parsed)
      if (root.hipStatus.warning !== "" && root.hipStatus.warningAt !== root._lastHipWarningAt) {
        root._lastHipWarningAt = root.hipStatus.warningAt
        if (root.leader) root.notify("Host check", root.hipStatus.warning, "dialog-warning")
      }
    }
  }

  Timer { id: hipStatusTick; interval: 600000; repeat: true; running: root.connected && root.hipReport; onTriggered: root.loadHipStatus() }
  Timer { id: configRefreshTick; interval: 300000; repeat: true; running: root.leader && root.connected && root.cliPath !== ""; triggeredOnStart: true; onTriggered: root.maybeRefreshConfig() }

  Process {
    id: collectLogsProc
    stdout: StdioCollector { id: collectOut; waitForEnd: true }
    stderr: StdioCollector { id: collectErr; waitForEnd: true }
    onExited: function(code) {
      var m = String(collectOut.text || "").match(/^path=(.+)$/m)
      if (code === 0 && m) {
        Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(m[1]) + " | wl-copy"])
        root.flash("Logs saved · path copied")
        root.notify("Logs collected", m[1], "document-save")
      } else {
        root.flash(String(collectErr.text || "").replace(/^error=/m, "").trim() || "Could not collect logs")
      }
    }
  }

  Process {
    id: forgetProc
    onExited: function(code) {
      root.flash(code === 0 ? "Session forgotten" : "Could not forget the session")
      delayedRefresh.restart()
    }
  }
}
