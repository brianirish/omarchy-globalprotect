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
  property string protocol: ""
  property string gatewayIp: ""
  property var routes: []
  property bool fullTunnel: false
  property var dns: []
  property var searchDomains: []
  property var deps: ({ openconnect: false, nmOpenconnect: false, webkit: false })
  property string actionStatus: ""
  property string lastError: ""
  property var hostState: Model.normalizeHostState(null)
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
    everPolled = true
    // While our own connect run is in flight the CLI's run file is the truth;
    // a stale "disconnected" from a poll that raced the run file would flicker.
    if (!(connectProc.running && s.state === "disconnected")) state = s.state
    detail = s.detail
    reportedPortal = s.portal
    gatewayHost = s.gateway
    iface = s.iface
    ip4 = s.ip4
    since = s.since
    username = s.username
    hasSession = s.hasSession
    protocol = s.protocol
    gatewayIp = s.gatewayIp
    routes = s.routes
    fullTunnel = s.fullTunnel
    dns = s.dns
    searchDomains = s.searchDomains
    deps = s.deps
    if (s.state === "connected") sample(s.rxBytes, s.txBytes)
    else resetSamples()
    if (_desired !== -1 && !connectProc.running && !disconnectProc.running && connected === (_desired === 1)) _desired = -1
    if (previous === "connected" && state !== "connected" && !disconnectProc.running && _desired !== 0)
      notify("Disconnected", "The GlobalProtect tunnel went down", "network-vpn-disconnected")
    if (state === "connected" && previous !== "connected" && previous !== "")
      notify("Connected", gatewayHost !== "" ? "Through " + gatewayHost : "The GlobalProtect tunnel is up", "network-vpn")
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

  function connectVpn(fresh) {
    if (!configured || connectProc.running) return
    if (!depsOk) { lastError = "Install networkmanager-openconnect first"; return }
    _desired = 1
    lastError = ""
    _connectErr = ""
    actionStatus = ""
    state = "authenticating"
    connectProc.command = cliArgs("connect", fresh === true ? ["--fresh"] : [])
    connectProc.running = true
  }

  function disconnectVpn() {
    if (disconnectProc.running) return
    _desired = 0
    lastError = ""
    if (connectProc.running) { connectProc.signal(15); return }
    disconnectProc.command = cliArgs("disconnect")
    disconnectProc.running = true
  }

  function toggle() {
    if (active) disconnectVpn()
    else connectVpn(false)
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
      connectVpn(true)
    }
  }

  // The official client's "rediscover network": drop the tunnel and come back
  // through the stored session, so routes and the gateway get renegotiated.
  function rediscover() {
    if (connectProc.running || disconnectProc.running) return
    if (!connected && state !== "activating") { connectVpn(false); return }
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

  onPanelOpenChanged: if (panelOpen) loadHostState()
  onHipReportChanged: if (panelOpen) loadHostState()
  onClientOsChanged: if (panelOpen) loadHostState()

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
  Timer { id: delayedRefresh; interval: 600; repeat: false; onTriggered: root.refresh() }
  Timer { id: actionStatusTimer; interval: 2200; repeat: false; onTriggered: root.actionStatus = "" }
  // Comes back after a deliberate disconnect: fresh=true forces the sign-in
  // window (sign in again), fresh=false reuses the stored session (rediscover).
  Timer { id: reconnectAfterDown; interval: 800; repeat: false; property bool fresh: true; onTriggered: root.connectVpn(fresh) }
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
      if (root._desired === 0) {
        // The user turned it off mid-flight: make sure NM is not left activating.
        disconnectProc.command = root.cliArgs("disconnect")
        disconnectProc.running = true
      } else if (code === 0) {
        root.lastError = ""
      } else if (code === 2) {
        root._desired = -1
        root.state = "disconnected"
        root.flash("Sign-in cancelled")
      } else {
        root._desired = -1
        root.state = "error"
        root.lastError = root._connectErr !== "" ? root._connectErr : "Connection failed"
        root.notify("Connection failed", root.lastError, "dialog-error")
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: disconnectProc
    stderr: StdioCollector { id: disconnectErr; waitForEnd: true }
    onExited: function(code) {
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
