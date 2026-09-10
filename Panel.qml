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
  readonly property string heroMeta: gp.connected ? Model.PHRASES[phraseIndex % Model.PHRASES.length] : Model.stateText(gp.state, gp.portal)
  readonly property string statusLine: gp.actionStatus !== "" ? gp.actionStatus : gp.lastError
  readonly property bool statusIsError: gp.actionStatus === "" && gp.lastError !== ""
  readonly property bool showSession: gp.connected
  readonly property bool showAccount: gp.username !== "" || gp.hasSession
  readonly property bool showSetup: !gp.configured
  readonly property bool showInstall: gp.configured && gp.everPolled && !gp.depsOk
  readonly property var cursorRows: rowsForCursor()
  readonly property string cursorRow: cursorActive && cursorRows.length > 0 ? cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))] : ""
  readonly property string toggleHint: !gp.configured ? "Set a portal first" : (!gp.depsOk ? "Install the NetworkManager plugin first" : (gp.active ? "Disconnect" : "Connect through Google SSO"))

  property int phraseIndex: 0
  property bool cursorActive: false
  property int cursorIndex: 0
  property double nowMs: Date.now()
  property bool forgetOpen: false

  function rowsForCursor() {
    var rows = ["header"]
    if (gp.connected && gp.ip4 !== "") rows.push("address")
    if (gp.connected) rows.push("rediscover")
    if (gp.username !== "" || gp.hasSession) rows.push("signin", "forget")
    if (gp.configured && gp.everPolled && !gp.depsOk) rows.push("install")
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
    if (row === "header") gp.toggle()
    else if (row === "address") gp.copyAddress()
    else if (row === "rediscover") gp.rediscover()
    else if (row === "signin") gp.signInAgain()
    else if (row === "forget") openForget()
    else if (row === "install") installDeps()
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

  Service {
    id: gp
    settings: gpPanel.settings
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
    function connect(): string { gp.connectVpn(false); return "ok" }
    function disconnect(): string { gp.disconnectVpn(); return "ok" }
    function toggleVpn(): string { gp.toggle(); return "ok" }
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
      if (buttonCode === Qt.RightButton) gp.toggle()
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
      blocked: gpPanel.forgetOpen || portalField.activeFocus || gatewayField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!gpPanel.cursorActive) { gpPanel.cursorActive = true; return }
        if (dy !== 0) gpPanel.moveCursor(dy)
      }
      onActivateRequested: if (gpPanel.cursorActive) gpPanel.activateCursor()
      onCloseRequested: gpPanel.close()
      onTabRequested: function(direction) { gpPanel.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "t") gp.toggle()
        else if (k === "r") { gp.refresh(); gp.flash("Refreshed") }
        else if (k === "c") gp.copyAddress()
        else if (k === "s") gp.signInAgain()
        else if (k === "n") gp.rediscover()
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
                  onToggled: gp.toggle()

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
              value: gp.ip4 !== "" ? gp.ip4 : "—"
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
              value: Model.dnsText(gp.dns, gp.searchDomains)
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
              text: "Enter your company's GlobalProtect portal host. Connecting opens Google sign-in in its own window; NetworkManager then owns the tunnel."
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
          PanelSeparator { visible: settingsSection.visible; foreground: gpPanel.foreground }

          Section {
            id: settingsSection
            shown: gp.configured

            PanelSectionHeader { text: "SETTINGS"; foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "Gateway"
                color: gpPanel.dim
                font.family: gpPanel.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(70)
              }

              TextField {
                id: gatewayField
                width: parent.width - Style.space(70) - parent.spacing
                foreground: gpPanel.foreground
                placeholderText: "Portal default"
                text: gp.gateway
                verticalPadding: Style.space(4)
                onEditingFinished: {
                  var v = text.trim()
                  if (v !== gp.gateway) gpPanel.saveSetting("gateway", v)
                }
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
                }
              }
            }

            Toggle {
              width: parent.width
              label: "HIP report"
              description: "Send a host-integrity report if your portal requires one"
              checked: gp.hipReport
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("hipReport", !gp.hipReport)
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Portal: " + gp.portal + "  ·  reports as " + (gp.clientOs === "win" ? "Windows" : (gp.clientOs === "mac" ? "macOS" : "Linux")) + ". Edit these in shell.json under this widget's entry."
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
