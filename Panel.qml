import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// GlobalProtect bar widget: a shield in the bar and a keyboard-friendly panel
// with the connection switch, live session stats, account actions, first-run
// setup, and settings. All process work lives in Service.qml.
Panel {
  id: gpPanel
  moduleName: "brianirish.globalprotect"
  ipcTarget: "brianirish.globalprotect"
  manageIpc: false

  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    return u.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: gp.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string iconState: gp.state === "error" ? "error" : (gp.transitioning ? "busy" : (gp.connected ? "on" : "off"))
  readonly property string autoMeta: gp.transitioning ? "" : Model.autoText(gp.autoReason, gp.pausedUntil, gp.nextAttemptAt, nowMs)
  readonly property string heroMeta: gp.connected ? Model.PHRASES[phraseIndex % Model.PHRASES.length] : (autoMeta !== "" ? autoMeta : Model.stateText(gp.state, gp.portal))
  readonly property string statusLine: gp.actionStatus !== "" ? gp.actionStatus : gp.lastError
  readonly property bool statusIsError: gp.actionStatus === "" && gp.lastError !== ""
  readonly property bool showSession: gp.connected
  readonly property bool showAccount: gp.username !== "" || gp.hasSession
  readonly property bool showSetup: !gp.configured
  readonly property bool showInstall: gp.configured && gp.everPolled && !gp.depsOk
  readonly property var cursorRows: rowsForCursor()
  readonly property string cursorRow: cursorActive && cursorRows.length > 0 ? cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))] : ""
  readonly property string toggleHint: !gp.configured ? "Set a portal first" : (!gp.depsOk ? "Install the NetworkManager plugin first" : (gp.active ? (gp.alwaysOn ? "Disconnect and pause Always-On for " + gp.pauseMinutes + " min" : "Disconnect") : "Connect through Google SSO"))

  property int phraseIndex: 0
  property bool cursorActive: false
  property int cursorIndex: 0
  property double nowMs: Date.now()
  property bool forgetOpen: false

  function rowsForCursor() {
    var rows = ["header"]
    if (gp.connected && gp.ip4 !== "") rows.push("address")
    if (gp.connected && gp.policy.rediscoverNetwork) rows.push("rediscover")
    if (gp.connected && gp.splitDns === "needed" && gp.dnsMode !== "off") rows.push("splitdns")
    if (gp.username !== "" || gp.hasSession) rows.push("signin", "forget")
    if (gp.welcomeAvailable) rows.push("welcome")
    if (gp.portals.length > 1) for (var pi = 0; pi < gp.portals.length; pi++) rows.push("portal:" + pi)
    if (gp.configured && gp.depsOk) {
      rows.push("gw:auto")
      for (var i = 0; i < gp.gatewayList.gateways.length; i++) rows.push("gw:" + i)
      rows.push("gwrefresh")
    }
    if (gp.configured && gp.everPolled && !gp.depsOk) rows.push("install")
    if (gp.configured && gp.alwaysOn && gp.paused) rows.push("resume")
    if (gp.configured) rows.push("logs")
    return rows
  }

  function moveCursor(dy) {
    cursorActive = true
    var n = cursorRows.length
    if (n === 0) return
    cursorIndex = Math.max(0, Math.min(n - 1, cursorIndex + dy))
  }

  function activateCursor() {
    var row = cursorRow
    if (row === "header") gp.toggle("cursor-header")
    else if (row === "address") gp.copyAddress()
    else if (row === "rediscover") gp.rediscover()
    else if (row === "splitdns") enableSplitDns()
    else if (row === "signin") gp.signInAgain()
    else if (row === "forget") openForget()
    else if (row === "install") installDeps()
    else if (row === "logs") gp.collectLogs()
    else if (row === "resume") gp.resume()
    else if (row === "welcome") gp.showWelcome()
    else if (row.indexOf("portal:") === 0) switchPortal(gp.portals[parseInt(row.substring(7), 10)] || "")
    else if (row === "gw:auto") selectGateway("")
    else if (row === "gwrefresh") gp.refreshGateways()
    else if (row.indexOf("gw:") === 0) {
      var g = gp.gatewayList.gateways[parseInt(row.substring(3), 10)]
      if (g) selectGateway(g.name)
    }
  }

  function applyPolicy(policy) {
    if (!gp.followPortal) return
    var changes = Model.policyChanges(policy, { connectMethod: gp.alwaysOn ? "always-on" : "on-demand", mtu: gp.mtu, sslOnly: gp.sslOnly })
    var keys = Object.keys(changes)
    for (var i = 0; i < keys.length; i++) saveSetting(keys[i], changes[keys[i]])
    if (keys.length > 0) gp.flash("Applied the portal's settings: " + keys.join(", "))
  }

  function switchPortal(host) {
    if (host === gp.portal || host === "") return
    if (gp.active) gp.disconnectVpn("switchPortal")
    saveSetting("portal", host)
    gp.flash("Portal: " + host)
    delayedPortalRefresh.restart()
  }

  function removePortal(host) {
    if (host === gp.portal) return
    Quickshell.execDetached([gpPanel.pluginDir + "/bin/omarchy-globalprotect", "forget", "--portal", host, "--remove"])
    gp.flash("Removed " + host)
    delayedPortalRefresh.restart()
  }

  function selectGateway(name) {
    if (name === gp.gateway) return
    saveSetting("gateway", name)
    gp.flash(name === "" ? "Best available gateway" : "Preferred gateway: " + name)
  }

  function openForget() {
    if (!showAccount) return
    forgetOpen = true
    Qt.callLater(function() { forgetDialog.forceActiveFocus() })
  }

  function closeForget() {
    forgetOpen = false
    keyCatcher.forceActiveFocus()
  }

  function saveSetting(key, value) {
    var next = Object.assign({}, gpPanel.settings)
    next[key] = value
    gpPanel.settings = next
    if (gpPanel.bar && gpPanel.bar.shell && typeof gpPanel.bar.shell.updateEntryInline === "function")
      gpPanel.bar.shell.updateEntryInline(gpPanel.moduleName, Object.assign({ id: gpPanel.moduleName }, next))
  }

  function savePortal() {
    var host = Model.cleanPortalHost(portalField.text)
    if (host === "") return
    saveSetting("portal", host)
    keyCatcher.forceActiveFocus()
    gp.flash("Portal saved")
    Qt.callLater(function() { gp.refresh() })
  }

  function enableSplitDns() {
    if (!gpPanel.bar) return
    gpPanel.bar.run(gpPanel.pluginDir + "/bin/omarchy-globalprotect-enable-split-dns")
    gp.flash("Installing the DNS polkit rule…")
    depsRecheck.restart()
  }

  function installDeps() {
    if (!gpPanel.bar) return
    gpPanel.bar.run(gpPanel.pluginDir + "/bin/omarchy-globalprotect-install-deps")
    gp.flash("Installing networkmanager-openconnect…")
    depsRecheck.restart()
  }

  function rgba(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  onOpenedChanged: {
    gp.panelOpen = opened
    if (opened) {
      gp.refresh()
      cursorActive = false
      cursorIndex = 0
      nowMs = Date.now()
    } else {
      forgetOpen = false
    }
  }
  onCursorRowsChanged: if (cursorIndex >= cursorRows.length) cursorIndex = Math.max(0, cursorRows.length - 1)
  Component.onCompleted: gp.cliPath = gpPanel.pluginDir + "/bin/omarchy-globalprotect"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Which screen this copy of the widget lives on; the first screen's copy leads.
  readonly property var hostScreen: QsWindow.window ? QsWindow.window.screen : null
  readonly property bool leader: Model.isLeader(hostScreen ? hostScreen.name : "",
                                                (Quickshell.screens || []).map(function (s) { return s.name }))

  Service {
    id: gp
    leader: gpPanel.leader
    settings: gpPanel.settings
  }

  Timer { id: delayedPortalRefresh; interval: 800; repeat: false; onTriggered: gp.refresh() }

  Connections {
    target: gp
    function onPolicyReceived(policy) { gpPanel.applyPolicy(policy) }
  }

  Timer {
    id: clockTick
    interval: 1000
    repeat: true
    running: gpPanel.opened && gp.connected
    onTriggered: gpPanel.nowMs = Date.now()
  }

  Timer {
    id: depsRecheck
    interval: 4000
    repeat: true
    running: false
    onTriggered: {
      gp.refresh()
      if (gp.depsOk) running = false
    }
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: gpPanel.opened && gp.connected
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction { script: gpPanel.phraseIndex = (gpPanel.phraseIndex + 1) % Model.PHRASES.length }
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
  }

  IpcHandler {
    target: gpPanel.ipcTarget
    function open(): void { gpPanel.open() }
    function close(): void { gpPanel.close() }
    function show(): void { gpPanel.open() }
    function hide(): void { gpPanel.close() }
    function toggle(): void { gpPanel.toggle() }
    function connect(): string { gp.connectVpn(false, "ipc"); return "ok" }
    function disconnect(): string { gp.disconnectVpn("ipc"); return "ok" }
    function toggleVpn(): string { gp.toggle("ipc"); return "ok" }
    function refresh(): string { gp.refresh(); return "ok" }
    function rediscover(): string { gp.rediscover(); return "ok" }
    function status(): string { return gp.state }
  }

  // ---------------------------------------------------------------- bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: gpPanel.bar
    tooltipText: gpPanel.opened ? "" : ("GlobalProtect · " + Model.stateText(gp.state, gp.portal))
    iconComponent: Component {
      Item {
        GpIcon {
          id: barIcon
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: gpPanel.barIconColor
          ringColor: gpPanel.barForeground
          badgeColor: gpPanel.urgent
          holeColor: gpPanel.bar ? gpPanel.bar.background : Color.background
          state: gpPanel.iconState
          Behavior on color { ColorAnimation { duration: 160 } }

          SequentialAnimation {
            running: gp.transitioning
            loops: Animation.Infinite
            onStopped: barIcon.opacity = 1.0
            NumberAnimation { target: barIcon; property: "opacity"; to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
            NumberAnimation { target: barIcon; property: "opacity"; to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) gp.toggle("right-click")
      else if (buttonCode === Qt.MiddleButton) gp.refresh()
      else gpPanel.toggle()
    }
  }

  // ------------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: gpPanel
    bar: gpPanel.bar
    open: gpPanel.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: gpPanel.forgetOpen || portalField.activeFocus || proxyField.editing || certField.editing || keyField.editing || mtuField.editing || addPortalField.editing || refreshField.editing || pauseField.editing
      onMoveRequested: function(dx, dy) {
        if (!gpPanel.cursorActive) { gpPanel.cursorActive = true; return }
        if (dy !== 0) gpPanel.moveCursor(dy)
      }
      onActivateRequested: if (gpPanel.cursorActive) gpPanel.activateCursor()
      onCloseRequested: gpPanel.close()
      onTabRequested: function(direction) { gpPanel.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "t") gp.toggle("key-t")
        else if (k === "r") { gp.refresh(); gp.flash("Refreshed") }
        else if (k === "c") gp.copyAddress()
        else if (k === "s") gp.signInAgain()
        else if (k === "n") gp.rediscover()
        else if (k === "l") gp.collectLogs()
        else if (k === "g") gp.refreshGateways()
        else if (k === "p") gp.togglePause()
        else if (k === "w") gp.showWelcome()
        else if (k === "f") gpPanel.openForget()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: gpPanel.cursorRow === "header"
            function focusHero() { gpPanel.cursorActive = true; gpPanel.cursorIndex = 0 }

            PanelHero {
              id: hero
              width: parent.width
              title: "GlobalProtect"
              meta: gpPanel.heroMeta
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              iconOpacity: 1.0
              iconComponent: Component {
                GpIcon {
                  iconSize: Style.font.display
                  color: gp.active ? gpPanel.foreground : gpPanel.dim
                  ringColor: gpPanel.foreground
                  badgeColor: gpPanel.urgent
                  holeColor: Color.popups.background
                  state: gpPanel.iconState
                  Behavior on color { ColorAnimation { duration: 160 } }
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: gp.active
                  busy: gp.busy
                  interactive: gp.configured && gp.depsOk
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: gp.toggle("switch")

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: gpPanel.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // ---------- Status line ----------
          Text {
            id: statusText
            textFormat: Text.PlainText
            visible: opacity > 0.01
            opacity: gpPanel.statusLine !== "" ? 1 : 0
            width: parent.width
            text: gpPanel.statusLine
            color: gpPanel.statusIsError ? gpPanel.urgent : gpPanel.dim
            font.family: gpPanel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
          }

          // ---------- Session ----------
          PanelSeparator { visible: sessionSection.visible; foreground: gpPanel.foreground }

          Section {
            id: sessionSection
            shown: gpPanel.showSession

            PanelSectionHeader { text: "SESSION"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            InfoRow {
              label: "Gateway"
              value: Model.gatewayText(gp.gatewayHost, gp.gatewayIp)
            }

            InfoRow {
              label: "Tunnel"
              value: Model.tunnelText(gp.protocol)
            }

            InfoRow {
              id: addressRow
              label: "Address"
              value: Model.addressText(gp.ip4, gp.ip6)
              iconText: ""
              hasCursor: gpPanel.cursorRow === "address"
              onActivated: gp.copyAddress()
              onHovered: function(on) { if (on) { gpPanel.cursorActive = true; gpPanel.cursorIndex = Math.max(0, gpPanel.cursorRows.indexOf("address")) } }
              tooltip: "Copy address"
            }

            InfoRow {
              label: "Connected for"
              value: gp.since > 0 ? Model.formatDuration(gpPanel.nowMs / 1000 - gp.since) : "—"
            }

            InfoRow {
              label: "Routes"
              value: Model.routesText(gp.routes, gp.fullTunnel)
            }

            InfoRow {
              label: "DNS"
              value: Model.resolverText(gp.resolver, gp.dns, gp.searchDomains, gp.splitDns)
            }

            Button {
              visible: gp.splitDns === "needed" && gp.dnsMode !== "off"
              width: parent.width
              iconText: ""
              text: "Enable tunnel DNS (polkit prompt)"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "splitdns"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gpPanel.enableSplitDns()
            }

            Text {
              visible: gp.splitDns === "needed" && gp.dnsMode !== "off"
              textFormat: Text.PlainText
              width: parent.width
              text: "Omarchy pins DNS globally, so the gateway's DNS is ignored and internal names will not resolve. Enabling installs a small polkit rule that lets this widget set the tunnel's DNS in systemd-resolved."
              color: gpPanel.foreground
              opacity: 0.55
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Throughput sparkline
            Item {
              width: parent.width
              implicitHeight: sparkColumn.implicitHeight

              Column {
                id: sparkColumn
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  Text {
                    textFormat: Text.PlainText
                    text: "Throughput"
                    color: gpPanel.dim
                    font.family: gpPanel.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    width: parent.width - rateText.implicitWidth
                    elide: Text.ElideRight
                  }
                  Text {
                    id: rateText
                    textFormat: Text.PlainText
                    text: "↓ " + Model.formatBytesPerSec(gp.rxRate) + "   ↑ " + Model.formatBytesPerSec(gp.txRate)
                    color: gpPanel.foreground
                    font.family: gpPanel.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Canvas {
                  id: spark
                  width: parent.width
                  height: Style.space(40)
                  property var rx: gp.rxHistory
                  property var tx: gp.txHistory
                  property color fg: gpPanel.foreground
                  onRxChanged: requestPaint()
                  onTxChanged: requestPaint()
                  onFgChanged: requestPaint()
                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var n = 40
                    var max = 1
                    for (var i = 0; i < rx.length; i++) max = Math.max(max, rx[i])
                    for (var j = 0; j < tx.length; j++) max = Math.max(max, tx[j])
                    var step = width / (n - 1)
                    function xOf(arr, idx) { return width - (arr.length - 1 - idx) * step }
                    function yOf(v) { return height - 2 - (v / max) * (height - 4) }
                    // Baseline
                    ctx.strokeStyle = gpPanel.rgba(fg, 0.12)
                    ctx.lineWidth = 1
                    ctx.beginPath(); ctx.moveTo(0, height - 1); ctx.lineTo(width, height - 1); ctx.stroke()
                    if (rx.length > 1) {
                      ctx.beginPath()
                      ctx.moveTo(xOf(rx, 0), height - 1)
                      for (var a = 0; a < rx.length; a++) ctx.lineTo(xOf(rx, a), yOf(rx[a]))
                      ctx.lineTo(xOf(rx, rx.length - 1), height - 1)
                      ctx.closePath()
                      ctx.fillStyle = gpPanel.rgba(fg, 0.18)
                      ctx.fill()
                      ctx.beginPath()
                      for (var b = 0; b < rx.length; b++) { if (b === 0) ctx.moveTo(xOf(rx, b), yOf(rx[b])); else ctx.lineTo(xOf(rx, b), yOf(rx[b])) }
                      ctx.strokeStyle = gpPanel.rgba(fg, 0.7)
                      ctx.lineWidth = 1.5
                      ctx.stroke()
                    }
                    if (tx.length > 1) {
                      ctx.beginPath()
                      for (var c = 0; c < tx.length; c++) { if (c === 0) ctx.moveTo(xOf(tx, c), yOf(tx[c])); else ctx.lineTo(xOf(tx, c), yOf(tx[c])) }
                      ctx.strokeStyle = gpPanel.rgba(fg, 0.4)
                      ctx.lineWidth = 1
                      ctx.stroke()
                    }
                  }
                }
              }
            }

            Button {
              visible: gp.policy.rediscoverNetwork
              width: parent.width
              iconText: ""
              iconSpinning: gp.transitioning
              text: "Rediscover network"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "rediscover"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gp.rediscover()
            }
          }

          // ---------- Account ----------
          PanelSeparator { visible: accountSection.visible; foreground: gpPanel.foreground }

          Section {
            id: accountSection
            shown: gpPanel.showAccount

            PanelSectionHeader { text: "ACCOUNT"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: gp.username !== "" ? "Signed in as " + gp.username : "A portal session is stored for " + gp.portal
              color: gpPanel.foreground
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideMiddle
            }

            Row {
              id: accountActions
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              Button {
                width: accountActions.cellWidth
                iconText: ""
                iconSpinning: gp.state === "authenticating"
                text: "Sign in again"
                fontSize: Style.font.bodySmall
                foreground: gpPanel.foreground
                fontFamily: gpPanel.fontFamily
                bordered: true
                hasCursor: gpPanel.cursorRow === "signin"
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: gp.signInAgain()
              }

              Button {
                width: accountActions.cellWidth
                iconText: ""
                text: "Forget session"
                fontSize: Style.font.bodySmall
                foreground: gpPanel.foreground
                fontFamily: gpPanel.fontFamily
                bordered: true
                hasCursor: gpPanel.cursorRow === "forget"
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: gpPanel.openForget()
              }
            }

            Button {
              visible: gp.welcomeAvailable
              width: parent.width
              iconText: ""
              text: "Welcome page from " + (gp.policy.portalName !== "" ? gp.policy.portalName : gp.portal)
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "welcome"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gp.showWelcome()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: gp.hasSession
                ? "Reconnects reuse the stored portal session until it expires; Google itself stays signed in inside the sign-in window."
                : "Google stays signed in inside the sign-in window, so reconnecting usually needs no typing."
              color: gpPanel.foreground
              opacity: 0.6
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Setup ----------
          PanelSeparator { visible: setupSection.visible; foreground: gpPanel.foreground }

          Section {
            id: setupSection
            shown: gpPanel.showSetup

            PanelSectionHeader { text: "SETUP"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Row {
              id: setupRow
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: portalField
                width: parent.width - saveButton.width - setupRow.spacing
                foreground: gpPanel.foreground
                placeholderText: "vpn.example.com"
                text: gp.portal
                onAccepted: gpPanel.savePortal()
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
                }
              }

              Button {
                id: saveButton
                anchors.verticalCenter: parent.verticalCenter
                text: "Save"
                fontSize: Style.font.bodySmall
                foreground: gpPanel.foreground
                fontFamily: gpPanel.fontFamily
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: gpPanel.savePortal()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Enter your company's GlobalProtect portal host, then flip the switch. Sign-in opens in its own window (Google, or a password prompt if the portal has no SSO); NetworkManager then owns the tunnel."
              color: gpPanel.foreground
              opacity: 0.6
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Install ----------
          PanelSeparator { visible: installSection.visible; foreground: gpPanel.foreground }

          Section {
            id: installSection
            shown: gpPanel.showInstall

            PanelSectionHeader { text: "ONE MORE THING"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "The NetworkManager OpenConnect plugin drives the tunnel. Install it once (a password prompt will appear)."
              color: gpPanel.foreground
              opacity: 0.8
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              iconText: ""
              text: "Install networkmanager-openconnect"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "install"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gpPanel.installDeps()
            }
          }

          // ---------- Settings ----------
          // ---------- Portals ----------
          PanelSeparator { visible: portalsSection.visible; foreground: gpPanel.foreground }

          Section {
            id: portalsSection
            shown: gp.portals.length > 1

            PanelSectionHeader { text: "PORTALS"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Repeater {
              model: gp.portals
              GatewayRow {
                required property var modelData
                required property int index
                title: modelData
                meta: modelData === gp.portal ? "current" : "click to switch"
                selected: modelData === gp.portal
                hasCursor: gpPanel.cursorRow === "portal:" + index
                onActivated: gpPanel.switchPortal(modelData)
                trailingIcon: modelData === gp.portal ? "" : ""
                onTrailingActivated: gpPanel.removePortal(modelData)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Each portal keeps its own session, gateways, and settings from the portal. Add one in Settings."
              color: gpPanel.foreground
              opacity: 0.55
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Gateways ----------
          PanelSeparator { visible: gatewaysSection.visible; foreground: gpPanel.foreground }

          Section {
            id: gatewaysSection
            shown: gp.configured && gp.everPolled && gp.depsOk

            PanelSectionHeader { text: "GATEWAYS"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            GatewayRow {
              title: "Best available"
              meta: gp.gatewayList.best !== "" ? "picks " + gp.gatewayList.best : (gp.gatewayList.gateways.length === 0 ? "portal decides" : "")
              selected: gp.gateway === ""
              hasCursor: gpPanel.cursorRow === "gw:auto"
              onActivated: gpPanel.selectGateway("")
            }

            Repeater {
              model: gp.gatewayList.gateways
              GatewayRow {
                required property var modelData
                required property int index
                title: modelData.description
                meta: Model.gatewayMeta(modelData)
                selected: gp.gateway === modelData.name
                connectedHere: gp.connected && gp.gatewayHost === modelData.host
                hasCursor: gpPanel.cursorRow === "gw:" + index
                onActivated: gpPanel.selectGateway(modelData.name)
              }
            }

            Button {
              width: parent.width
              iconText: ""
              iconSpinning: gp.gatewaysBusy
              text: gp.gatewayList.gateways.length === 0 ? "Fetch gateways from the portal" : "Refresh gateways"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "gwrefresh"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gp.refreshGateways()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: gp.gatewaysError !== ""
                ? gp.gatewaysError
                : (gp.gatewayList.gateways.length === 0
                    ? "Fetching signs in at the portal (the Google window may flash) and lists its gateways with priority and latency."
                    : "Best available picks the highest priority, then the lowest latency. Click a gateway to prefer it.")
              color: gp.gatewaysError !== "" ? gpPanel.urgent : gpPanel.foreground
              opacity: gp.gatewaysError !== "" ? 0.9 : 0.55
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Host state ----------
          PanelSeparator { visible: hostStateSection.visible; foreground: gpPanel.foreground }

          Section {
            id: hostStateSection
            shown: gp.configured && gp.everPolled && gp.depsOk

            PanelSectionHeader { text: "HOST STATE"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            InfoRow {
              label: "Reports as"
              value: Model.reportsAsText(gp.hostState)
            }

            InfoRow {
              label: "Host"
              value: Model.hostText(gp.hostState)
            }

            InfoRow {
              label: "Claims"
              value: Model.claimsText(gp.hostState)
            }

            InfoRow {
              visible: gp.hipReport && gp.connected
              label: "Last check"
              value: Model.timestampText(gp.hipStatus.lastCheck) + (gp.hipStatus.lastSubmit !== "" ? " · sent " + Model.timestampText(gp.hipStatus.lastSubmit) : "")
            }

            Text {
              visible: gp.hipStatus.warning !== ""
              textFormat: Text.PlainText
              width: parent.width
              text: gp.hipStatus.warning
              color: gpPanel.urgent
              opacity: 0.9
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: gp.hostState.error !== ""
                ? gp.hostState.error
                : (gp.hipReport
                    ? "This is what openconnect's hipreport.sh submits when the tunnel comes up and on the portal's check interval."
                    : "HIP report is off: nothing is sent to the portal. Turn it on below if your portal requires a host check.")
              color: gp.hostState.error !== "" ? gpPanel.urgent : gpPanel.foreground
              opacity: gp.hostState.error !== "" ? 0.9 : 0.55
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { visible: settingsSection.visible; foreground: gpPanel.foreground }

          Section {
            id: settingsSection
            shown: gp.configured

            PanelSectionHeader { text: "SETTINGS"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Toggle {
              width: parent.width
              label: "HIP report"
              description: "Send a host-integrity report if your portal requires one"
              checked: gp.hipReport
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("hipReport", !gp.hipReport)
            }

            Toggle {
              width: parent.width
              label: "Always-On"
              description: gp.alwaysOn
                ? "Connects at login and whenever the network returns; the switch pauses it for " + gp.pauseMinutes + " min"
                : "Connect at login and whenever the network returns (the official client's user-logon mode)"
              checked: gp.alwaysOn
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("connectMethod", gp.alwaysOn ? "on-demand" : "always-on")
            }

            Button {
              visible: gp.alwaysOn && gp.paused
              width: parent.width
              iconText: ""
              text: "Resume Always-On now"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "resume"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gp.resume()
            }

            Toggle {
              width: parent.width
              label: "Follow the portal's settings"
              description: gp.policy.portalName !== ""
                ? "Connect method, MTU, and SSL-only come from " + gp.policy.portalName + (gp.policy.version !== "" ? " (v" + gp.policy.version + ")" : "") + " when it says so"
                : "Apply the connect method, MTU, and SSL-only the portal pushes (fetched with the gateway list)"
              checked: gp.followPortal
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("followPortal", !gp.followPortal)
            }

            SettingField { id: addPortalField; label: "Add portal"; placeholder: "vpn2.example.com"; settingKey: "portal"; current: ""; visible: gp.policy.canChangePortal }

            Toggle {
              width: parent.width
              label: "SSL only"
              description: "Never use ESP over UDP; the tunnel runs over TCP 443 (slower, but survives UDP-hostile networks)"
              checked: gp.sslOnly
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("sslOnly", !gp.sslOnly)
            }

            Toggle {
              width: parent.width
              label: "No direct access to local network"
              description: "Route the LAN's subnets into the tunnel while connected (the official client's setting of the same name)"
              checked: gp.blockLan
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("blockLan", !gp.blockLan)
            }

            Toggle {
              width: parent.width
              label: "Tunnel DNS"
              description: gp.dnsMode === "auto"
                ? "Auto: pushed domains go to the tunnel's DNS; on a full tunnel without domains, all queries do"
                : (gp.dnsMode === "split" ? "Split: only the pushed domains use the tunnel's DNS" : "Off: the resolver is left alone")
              checked: gp.dnsMode !== "off"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("dnsMode", gp.dnsMode === "off" ? "auto" : (gp.dnsMode === "auto" ? "split" : "off"))
            }

            SettingField { id: mtuField; label: "MTU"; placeholder: "0 = automatic"; settingKey: "mtu"; current: gp.mtu > 0 ? String(gp.mtu) : ""; numeric: true }

            Toggle {
              width: parent.width
              label: "System browser for SAML"
              description: gp.systemBrowser
                ? "Sign-in opens in your default browser; the portal hands the session back through a globalprotectcallback: link"
                : "Sign in inside the widget's own window (recommended). Switch on if your portal only supports the default-browser flow"
              checked: gp.systemBrowser
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("samlBrowser", gp.systemBrowser ? "embedded" : "system")
            }

            SettingField { id: proxyField; label: "Proxy"; placeholder: "http://proxy.example.com:3128"; settingKey: "proxy"; current: gp.proxy }
            SettingField { id: certField; label: "Certificate"; placeholder: "/path/to/client.pem"; settingKey: "certificate"; current: gp.certificate }
            SettingField { id: keyField; label: "Key"; placeholder: "/path/to/client.key (if separate)"; settingKey: "certificateKey"; current: gp.certificateKey }

            Toggle {
              width: parent.width
              label: "Debug logging"
              description: "Record each connect step in ~/.local/state/omarchy-globalprotect/debug.log"
              checked: gp.debug
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("debug", !gp.debug)
            }

            Button {
              width: parent.width
              iconText: ""
              iconSpinning: gp.collectingLogs
              text: "Collect logs"
              fontSize: Style.font.bodySmall
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              bordered: true
              hasCursor: gpPanel.cursorRow === "logs"
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: gp.collectLogs()
            }

            Toggle {
              width: parent.width
              label: "Reports as " + (gp.clientOs === "win" ? "Windows" : (gp.clientOs === "mac" ? "macOS" : "Linux"))
              description: "The client OS sent to the portal; many portals only admit Windows and macOS. Click to cycle Windows → Linux → macOS"
              checked: gp.clientOs !== "win"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("clientOs", gp.clientOs === "win" ? "linux" : (gp.clientOs === "linux" ? "mac" : "win"))
            }

            Toggle {
              width: parent.width
              label: "Sign-in interface: " + (gp.authInterface === "auto" ? "auto" : gp.authInterface)
              description: gp.authInterface === "auto"
                ? "Probe the gateway interface first, then the portal. Click to force gateway or portal"
                : (gp.authInterface === "gateway" ? "SAML at /ssl-vpn/prelogin.esp on the gateway host" : "SAML at /global-protect/prelogin.esp on the portal")
              checked: gp.authInterface !== "auto"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("authInterface", gp.authInterface === "auto" ? "gateway" : (gp.authInterface === "gateway" ? "portal" : "auto"))
            }

            SettingField { id: refreshField; label: "Refresh (s)"; placeholder: "5"; settingKey: "refreshIntervalSec"; current: String(gp.refreshIntervalSec); numeric: true; minimum: 2 }
            SettingField { id: pauseField; label: "Pause (min)"; placeholder: "30"; settingKey: "pauseMinutes"; current: String(gp.pauseMinutes); numeric: true; minimum: 1 }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Portal: " + gp.portal + (gp.policy.portalName !== "" ? " (" + gp.policy.portalName + ")" : "") + "  ·  everything above is stored under this widget's entry in shell.json."
              color: gpPanel.foreground
              opacity: 0.55
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      ConfirmDialog {
        id: forgetDialog
        anchors.fill: parent
        z: 10
        opened: gpPanel.forgetOpen
        message: "Forget the stored portal session and the Google sign-in kept for this VPN?"
        confirmText: "Forget"
        background: Color.popups.background
        foreground: gpPanel.foreground
        fontFamily: gpPanel.fontFamily
        onCanceled: gpPanel.closeForget()
        onConfirmed: { gp.forget(); gpPanel.closeForget() }
        Keys.onPressed: function(event) { if (forgetDialog.handleKey(event)) event.accepted = true }
      }
    }
  }

  // ------------------------------------------------------------- components
  component Section: Column {
    property bool shown: true
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(10)
    visible: opacity > 0.01
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }

  // One labelled text field bound to a settings key; saves on Enter or focus loss.
  component SettingField: Row {
    id: settingField
    property string label: ""
    property string placeholder: ""
    property string settingKey: ""
    property string current: ""
    property bool numeric: false
    property int minimum: 0
    property alias editing: field.activeFocus
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: settingField.label
      color: gpPanel.dim
      font.family: gpPanel.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(80)
      elide: Text.ElideRight
    }

    TextField {
      id: field
      width: parent.width - Style.space(80) - parent.spacing
      foreground: gpPanel.foreground
      placeholderText: settingField.placeholder
      text: settingField.current
      verticalPadding: Style.space(4)
      onEditingFinished: {
        var v = text.trim()
        if (settingField.numeric) {
          var n = parseInt(v, 10)
          if (isNaN(n) || n < settingField.minimum) n = settingField.minimum
          if (String(n) !== settingField.current && !(n === 0 && settingField.current === "")) gpPanel.saveSetting(settingField.settingKey, n)
          return
        }
        if (v !== settingField.current) gpPanel.saveSetting(settingField.settingKey, v)
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
      }
    }
  }

  component GatewayRow: CursorSurface {
    id: gatewayRow
    property string title: ""
    property string meta: ""
    property bool selected: false
    property bool connectedHere: false
    property string trailingIcon: ""
    signal activated()
    signal trailingActivated()

    width: parent ? parent.width : implicitWidth
    implicitHeight: gwContent.implicitHeight + Style.space(10)
    foreground: gpPanel.foreground
    hasCursor: false

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: gatewayRow.activated()
    }

    Text {
      visible: gatewayRow.trailingIcon !== ""
      text: gatewayRow.trailingIcon
      color: gpPanel.dim
      font.family: gpPanel.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) { mouse.accepted = true; gatewayRow.trailingActivated() }
      }
    }

    Row {
      id: gwContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: gatewayRow.selected ? "" : (gatewayRow.connectedHere ? "" : "")
        color: gatewayRow.selected || gatewayRow.connectedHere ? gpPanel.foreground : gpPanel.dim
        font.family: gpPanel.fontFamily
        font.pixelSize: Style.font.bodySmall
        width: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 120 } }
      }

      Column {
        width: parent.width - Style.space(16) - parent.spacing
        spacing: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: gatewayRow.title
          color: gpPanel.foreground
          font.family: gpPanel.fontFamily
          font.pixelSize: Style.font.body
          font.bold: gatewayRow.selected
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: gatewayRow.meta !== ""
          width: parent.width
          text: gatewayRow.meta
          color: gpPanel.dim
          font.family: gpPanel.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
    }
  }

  component InfoRow: CursorSurface {
    id: infoRow
    property string label: ""
    property string value: ""
    property string iconText: ""
    property string tooltip: ""
    signal activated()
    signal hovered(bool on)

    width: parent ? parent.width : implicitWidth
    implicitHeight: rowContent.implicitHeight + Style.space(10)
    foreground: gpPanel.foreground
    hasCursor: false

    MouseArea {
      anchors.fill: parent
      hoverEnabled: infoRow.iconText !== ""
      cursorShape: infoRow.iconText !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: infoRow.hovered(containsMouse)
      onClicked: if (infoRow.iconText !== "") infoRow.activated()

      PanelToolTip {
        visible: infoRow.tooltip !== "" && parent.containsMouse
        text: infoRow.tooltip
        fontFamily: gpPanel.fontFamily
      }
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: infoRow.label
        color: gpPanel.dim
        font.family: gpPanel.fontFamily
        font.pixelSize: Style.font.bodySmall
        width: Style.space(96)
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: infoRow.value
        color: gpPanel.foreground
        font.family: gpPanel.fontFamily
        font.pixelSize: Style.font.body
        width: parent.width - Style.space(96) - parent.spacing - (rowIcon.visible ? rowIcon.width + parent.spacing : 0)
        elide: Text.ElideMiddle
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: rowIcon
        textFormat: Text.PlainText
        visible: infoRow.iconText !== ""
        text: infoRow.iconText
        color: infoRow.hasCursor ? gpPanel.foreground : gpPanel.dim
        font.family: gpPanel.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }
  }
}
