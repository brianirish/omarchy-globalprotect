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

  // The panel's text, from i18n/<language>.json. Calls to strings.t() stay
  // inside bindings so Setup > Language re-renders them live.
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Numbers in the language's digits and decimal separator; clock times in
  // its locale's short format. Both are handed to Model.js as values.
  readonly property var num: (value, decimals) => I18n.formatNumber(value, decimals)
  readonly property var formatLocale: Qt.locale(I18n.formatLocale)
  readonly property var clock: ({
    time: function(ms) { return new Date(ms).toLocaleTimeString(gpPanel.formatLocale, Locale.ShortFormat) },
    dateTime: function(ms) { return new Date(ms).toLocaleString(gpPanel.formatLocale, Locale.ShortFormat) }
  })

  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    return u.replace(/^file:\/\//, "").replace(/\/$/, "")
  }

  // Installed version (manifest.json), shown small and grey beside the hero title.
  property string version: ""
  FileView {
    id: manifestFile
    path: gpPanel.pluginDir + "/manifest.json"
    onLoaded: gpPanel.version = Model.manifestVersion(text())
  }
  // The hero draws its title as plain text, so the tag is placed by measuring
  // where that title ends: after it, or before it in a mirrored
  // (right-to-left) panel. Passing the sizes in keeps the bindings live.
  function afterTitleX(titleItem, titleWidth, ownWidth, mirrored, heroWidth, heroHeight) {
    var left = titleItem.mapToItem(header, 0, 0).x
    return mirrored ? left - Style.space(6) - ownWidth : left + titleWidth + Style.space(6)
  }
  function titleBottomY(titleItem, titleHeight, ownHeight, heroWidth, heroHeight) {
    return titleItem.mapToItem(header, 0, 0).y + titleHeight - ownHeight - 3
  }
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: gp.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string iconState: gp.state === "error" ? "error" : (gp.transitioning ? "busy" : (gp.connected ? "on" : "off"))
  readonly property string autoMeta: gp.transitioning ? "" : Model.autoText(gp.autoReason, gp.pausedUntil, gp.nextAttemptAt, nowMs, strings, gpPanel.num, gpPanel.clock)
  readonly property string heroMeta: gp.connected ? Model.phraseText(phraseIndex, strings) : (autoMeta !== "" ? autoMeta : Model.stateText(gp.state, strings))
  readonly property string statusLine: gp.actionStatus !== "" ? gp.actionStatus : gp.lastErrorText
  readonly property bool statusIsError: gp.actionStatus === "" && gp.lastErrorText !== ""
  readonly property bool showSession: gp.connected
  readonly property bool showAccount: gp.username !== "" || gp.hasSession
  readonly property bool showSetup: !gp.configured
  readonly property bool showInstall: gp.configured && gp.everPolled && !gp.depsOk
  readonly property var cursorRows: rowsForCursor()
  readonly property string cursorRow: cursorActive && cursorRows.length > 0 ? cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))] : ""
  readonly property string toggleHint: !gp.configured ? strings.t("hint.setPortalFirst")
    : (!gp.depsOk ? strings.t("hint.installPluginFirst")
    : (gp.active
      ? (gp.alwaysOn ? Model.fill(strings.tn("hint.disconnectAndPause", gp.pauseMinutes), [gpPanel.num(gp.pauseMinutes)]) : strings.t("hint.disconnect"))
      : strings.t("hint.connect")))

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
    if (keys.length > 0) gp.flash(Model.fill(strings.t("flash.appliedPortalSettings"), [keys.join(", ")]))
  }

  function switchPortal(host) {
    if (host === gp.portal || host === "") return
    if (gp.active) gp.disconnectVpn("switchPortal")
    saveSetting("portal", host)
    gp.flash(Model.fill(strings.t("flash.portal"), [host]))
    delayedPortalRefresh.restart()
  }

  function removePortal(host) {
    if (host === gp.portal) return
    Quickshell.execDetached([gpPanel.pluginDir + "/bin/omarchy-globalprotect", "forget", "--portal", host, "--remove"])
    gp.flash(Model.fill(strings.t("flash.removedPortal"), [host]))
    delayedPortalRefresh.restart()
  }

  function selectGateway(name) {
    if (name === gp.gateway) return
    saveSetting("gateway", name)
    gp.flash(name === "" ? strings.t("flash.bestGateway") : Model.fill(strings.t("flash.preferredGateway"), [name]))
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
    gp.flash(strings.t("flash.portalSaved"))
    Qt.callLater(function() { gp.refresh() })
  }

  function enableSplitDns() {
    if (!gpPanel.bar) return
    gpPanel.bar.run(gpPanel.pluginDir + "/bin/omarchy-globalprotect-enable-split-dns")
    gp.flash(strings.t("flash.installingDnsRule"))
    depsRecheck.restart()
  }

  function installDeps() {
    if (!gpPanel.bar) return
    gpPanel.bar.run(gpPanel.pluginDir + "/bin/omarchy-globalprotect-install-deps")
    gp.flash(Model.fill(strings.t("flash.installing"), ["networkmanager-openconnect"]))
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
    tr: strings
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

  // The stock Tailscale panel's phrase swap: a quick fade out, the next
  // phrase, a slightly longer fade in, both easing out.
  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 0.0; duration: Style.duration(150); easing.type: Easing.OutCubic }
    ScriptAction { script: gpPanel.phraseIndex = (gpPanel.phraseIndex + 1) % Model.PHRASE_COUNT }
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 1.0; duration: Style.duration(200); easing.type: Easing.OutCubic }
  }

  // ShellIpc answers on the shell's own socket as well as qs ipc, so
  // `omarchy-shell brianirish.globalprotect connect` works. manageIpc is off
  // because this one handler owns the target, panel functions included.
  ShellIpc {
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
    tooltipText: gpPanel.opened ? "" : Model.fill(strings.t("bar.tooltip"), [Model.stateText(gp.state, strings)])
    iconComponent: Component {
      Item {
        GpIcon {
          id: barIcon
          anchors.centerIn: parent
          iconSize: button.iconSize
          // The ring stays in the panel. In the bar it would count toward
          // the icon's fitted size and shrink the shield (see GpIcon).
          showRing: false
          color: gpPanel.barIconColor
          badgeColor: gpPanel.urgent
          holeColor: gpPanel.bar ? gpPanel.bar.background : Color.background
          state: gpPanel.iconState
          Behavior on color { ColorAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

          // Breathes while connecting, as the Tailscale panel's account
          // switch does. A loop, not an entrance, so it keeps that panel's
          // symmetric curve; it stays still when animations are off, since a
          // looping animation with no duration would flicker.
          SequentialAnimation {
            running: gp.transitioning && !Style.reduceMotion
            loops: Animation.Infinite
            onStopped: barIcon.opacity = 1.0
            NumberAnimation { target: barIcon; property: "opacity"; to: 0.45; duration: Style.duration(420); easing.type: Easing.InOutQuad }
            NumberAnimation { target: barIcon; property: "opacity"; to: 1.0; duration: Style.duration(420); easing.type: Easing.InOutQuad }
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
        else if (k === "r") { gp.refresh(); gp.flash(strings.t("flash.refreshed")) }
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

            Text {
              id: versionTag
              z: 1
              // hero > labels column > title row > title text (see Ui/PanelHero.qml)
              readonly property var titleText: (hero.children.length > 1 && hero.children[1].children.length > 0
                                                && hero.children[1].children[0].children.length > 0)
                                               ? hero.children[1].children[0].children[0] : null
              visible: gpPanel.version !== "" && titleText !== null && titleText.visible
              textFormat: Text.PlainText
              text: "v" + gpPanel.version
              color: hero.dim
              font.family: hero.fontFamily
              font.pixelSize: Style.font.caption
              x: titleText ? gpPanel.afterTitleX(titleText, titleText.width, width, LayoutMirroring.enabled, hero.width, hero.height) : 0
              y: titleText ? gpPanel.titleBottomY(titleText, titleText.height, height, hero.width, hero.height) : 0
            }

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
                  Behavior on color { ColorAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
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
            // In a little slower than out, as the shell's own panels fade.
            Behavior on opacity {
              id: statusFade
              NumberAnimation { duration: Style.duration(statusFade.targetValue > 0 ? 180 : 120); easing.type: Easing.OutCubic }
            }
            Behavior on color { ColorAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
          }

          // ---------- Session ----------
          PanelSeparator { visible: sessionSection.visible; foreground: gpPanel.foreground }

          Section {
            id: sessionSection
            shown: gpPanel.showSession

            PanelSectionHeader { text: strings.t("session.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            InfoRow {
              label: strings.t("session.gateway")
              value: Model.gatewayText(gp.gatewayHost, gp.gatewayIp)
            }

            InfoRow {
              label: strings.t("session.tunnel")
              value: Model.tunnelText(gp.protocol, strings)
            }

            InfoRow {
              id: addressRow
              label: strings.t("session.address")
              value: Model.addressText(gp.ip4, gp.ip6)
              iconText: ""
              hasCursor: gpPanel.cursorRow === "address"
              onActivated: gp.copyAddress()
              onHovered: function(on) { if (on) { gpPanel.cursorActive = true; gpPanel.cursorIndex = Math.max(0, gpPanel.cursorRows.indexOf("address")) } }
              tooltip: strings.t("session.copyAddress")
            }

            InfoRow {
              label: strings.t("session.connectedFor")
              value: gp.since > 0 ? Model.formatDuration(gpPanel.nowMs / 1000 - gp.since, strings, gpPanel.num) : "—"
            }

            InfoRow {
              label: strings.t("session.routes")
              value: Model.routesText(gp.routes, gp.fullTunnel, strings)
            }

            InfoRow {
              label: strings.t("session.dns")
              value: Model.resolverText(gp.resolver, gp.dns, gp.searchDomains, gp.splitDns, strings)
            }

            Button {
              visible: gp.splitDns === "needed" && gp.dnsMode !== "off"
              width: parent.width
              iconText: ""
              text: strings.t("session.enableDns")
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
              text: strings.t("session.dnsExplanation")
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
                    text: strings.t("session.throughput")
                    color: gpPanel.dim
                    font.family: gpPanel.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    width: parent.width - rateText.implicitWidth
                    elide: Text.ElideRight
                  }
                  Text {
                    id: rateText
                    textFormat: Text.PlainText
                    text: "↓ " + Model.formatBytesPerSec(gp.rxRate, gpPanel.num) + "   ↑ " + Model.formatBytesPerSec(gp.txRate, gpPanel.num)
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
              text: strings.t("session.rediscover")
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

            PanelSectionHeader { text: strings.t("account.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: gp.username !== ""
                ? Model.fill(strings.t("account.signedInAs"), [gp.username])
                : Model.fill(strings.t("account.sessionStored"), [gp.portal])
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
                text: strings.t("account.signInAgain")
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
                text: strings.t("account.forget")
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
              text: Model.fill(strings.t("account.welcomePage"), [gp.policy.portalName !== "" ? gp.policy.portalName : gp.portal])
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
              text: gp.hasSession ? strings.t("account.hintSession") : strings.t("account.hintNoSession")
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

            PanelSectionHeader { text: strings.t("setup.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

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
                text: strings.t("setup.save")
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
              text: strings.t("setup.hint")
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

            PanelSectionHeader { text: strings.t("install.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("install.explanation")
              color: gpPanel.foreground
              opacity: 0.8
              font.family: gpPanel.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              iconText: ""
              text: Model.fill(strings.t("install.button"), ["networkmanager-openconnect"])
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

            PanelSectionHeader { text: strings.t("portals.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Repeater {
              model: gp.portals
              GatewayRow {
                required property var modelData
                required property int index
                title: modelData
                meta: modelData === gp.portal ? strings.t("portals.current") : strings.t("portals.clickToSwitch")
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
              text: strings.t("portals.hint")
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

            PanelSectionHeader { text: strings.t("gateways.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            GatewayRow {
              title: strings.t("gateways.best")
              meta: gp.gatewayList.best !== ""
                ? Model.fill(strings.t("gateways.picks"), [gp.gatewayList.best])
                : (gp.gatewayList.gateways.length === 0 ? strings.t("gateways.portalDecides") : "")
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
                meta: Model.gatewayMeta(modelData, strings, gpPanel.num)
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
              text: gp.gatewayList.gateways.length === 0 ? strings.t("gateways.fetch") : strings.t("gateways.refresh")
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
              text: gp.gatewaysErrorText !== ""
                ? gp.gatewaysErrorText
                : (gp.gatewayList.gateways.length === 0 ? strings.t("gateways.hintFetch") : strings.t("gateways.hintPick"))
              color: gp.gatewaysErrorText !== "" ? gpPanel.urgent : gpPanel.foreground
              opacity: gp.gatewaysErrorText !== "" ? 0.9 : 0.55
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

            PanelSectionHeader { text: strings.t("host.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            InfoRow {
              label: strings.t("host.reportsAs")
              value: Model.reportsAsText(gp.hostState, strings)
            }

            InfoRow {
              label: strings.t("host.host")
              value: Model.hostText(gp.hostState)
            }

            InfoRow {
              label: strings.t("host.claims")
              value: Model.claimsText(gp.hostState, strings)
            }

            InfoRow {
              visible: gp.hipReport && gp.connected
              label: strings.t("host.lastCheck")
              value: gp.hipStatus.lastSubmit !== ""
                ? Model.fill(strings.t("host.lastCheckSent"), [Model.timestampText(gp.hipStatus.lastCheck, gpPanel.clock), Model.timestampText(gp.hipStatus.lastSubmit, gpPanel.clock)])
                : Model.timestampText(gp.hipStatus.lastCheck, gpPanel.clock)
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
                : (gp.hipReport ? strings.t("host.hintOn") : strings.t("host.hintOff"))
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

            PanelSectionHeader { text: strings.t("settings.header"); foreground: gpPanel.foreground; fontFamily: gpPanel.fontFamily }

            Toggle {
              width: parent.width
              label: strings.t("settings.hipReport")
              description: strings.t("settings.hipReportDescription")
              checked: gp.hipReport
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("hipReport", !gp.hipReport)
            }

            Toggle {
              width: parent.width
              label: strings.t("settings.alwaysOn")
              description: gp.alwaysOn
                ? Model.fill(strings.tn("settings.alwaysOnOnDescription", gp.pauseMinutes), [gpPanel.num(gp.pauseMinutes)])
                : strings.t("settings.alwaysOnOffDescription")
              checked: gp.alwaysOn
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("connectMethod", gp.alwaysOn ? "on-demand" : "always-on")
            }

            Button {
              visible: gp.alwaysOn && gp.paused
              width: parent.width
              iconText: ""
              text: strings.t("settings.resumeAlwaysOn")
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
              label: strings.t("settings.followPortal")
              description: gp.policy.portalName !== ""
                ? Model.fill(strings.t("settings.followPortalNamed"), [gp.policy.portalName + (gp.policy.version !== "" ? " (v" + gp.policy.version + ")" : "")])
                : strings.t("settings.followPortalDescription")
              checked: gp.followPortal
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("followPortal", !gp.followPortal)
            }

            SettingField { id: addPortalField; label: strings.t("settings.addPortal"); placeholder: "vpn2.example.com"; settingKey: "portal"; current: ""; visible: gp.policy.canChangePortal }

            Toggle {
              width: parent.width
              label: strings.t("settings.sslOnly")
              description: strings.t("settings.sslOnlyDescription")
              checked: gp.sslOnly
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("sslOnly", !gp.sslOnly)
            }

            Toggle {
              width: parent.width
              label: strings.t("settings.blockLan")
              description: strings.t("settings.blockLanDescription")
              checked: gp.blockLan
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("blockLan", !gp.blockLan)
            }

            Toggle {
              width: parent.width
              label: strings.t("settings.tunnelDns")
              description: gp.dnsMode === "auto"
                ? strings.t("settings.dnsAutoDescription")
                : (gp.dnsMode === "split" ? strings.t("settings.dnsSplitDescription") : strings.t("settings.dnsOffDescription"))
              checked: gp.dnsMode !== "off"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("dnsMode", gp.dnsMode === "off" ? "auto" : (gp.dnsMode === "auto" ? "split" : "off"))
            }

            SettingField { id: mtuField; label: strings.t("settings.mtu"); placeholder: strings.t("settings.mtuPlaceholder"); settingKey: "mtu"; current: gp.mtu > 0 ? String(gp.mtu) : ""; numeric: true }

            Toggle {
              width: parent.width
              label: strings.t("settings.systemBrowser")
              description: gp.systemBrowser
                ? strings.t("settings.systemBrowserOnDescription")
                : strings.t("settings.systemBrowserOffDescription")
              checked: gp.systemBrowser
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("samlBrowser", gp.systemBrowser ? "embedded" : "system")
            }

            SettingField { id: proxyField; label: strings.t("settings.proxy"); placeholder: "http://proxy.example.com:3128"; settingKey: "proxy"; current: gp.proxy }
            SettingField { id: certField; label: strings.t("settings.certificate"); placeholder: "/path/to/client.pem"; settingKey: "certificate"; current: gp.certificate }
            SettingField { id: keyField; label: strings.t("settings.key"); placeholder: Model.fill(strings.t("settings.keyPlaceholder"), ["/path/to/client.key"]); settingKey: "certificateKey"; current: gp.certificateKey }

            Toggle {
              width: parent.width
              label: strings.t("settings.debug")
              description: Model.fill(strings.t("settings.debugDescription"), ["~/.local/state/omarchy-globalprotect/debug.log"])
              checked: gp.debug
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("debug", !gp.debug)
            }

            Button {
              width: parent.width
              iconText: ""
              iconSpinning: gp.collectingLogs
              text: strings.t("settings.collectLogs")
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
              label: Model.fill(strings.t("settings.reportsAs"), [gp.clientOs === "win" ? "Windows" : (gp.clientOs === "mac" ? "macOS" : "Linux")])
              description: strings.t("settings.reportsAsDescription")
              checked: gp.clientOs !== "win"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("clientOs", gp.clientOs === "win" ? "linux" : (gp.clientOs === "linux" ? "mac" : "win"))
            }

            Toggle {
              width: parent.width
              label: gp.authInterface === "gateway" ? strings.t("settings.authGateway")
                : (gp.authInterface === "portal" ? strings.t("settings.authPortal") : strings.t("settings.authAuto"))
              description: gp.authInterface === "auto"
                ? strings.t("settings.authAutoDescription")
                : (gp.authInterface === "gateway"
                    ? Model.fill(strings.t("settings.authGatewayDescription"), ["/ssl-vpn/prelogin.esp"])
                    : Model.fill(strings.t("settings.authPortalDescription"), ["/global-protect/prelogin.esp"]))
              checked: gp.authInterface !== "auto"
              foreground: gpPanel.foreground
              fontFamily: gpPanel.fontFamily
              onClicked: gpPanel.saveSetting("authInterface", gp.authInterface === "auto" ? "gateway" : (gp.authInterface === "gateway" ? "portal" : "auto"))
            }

            SettingField { id: refreshField; label: strings.t("settings.refresh"); placeholder: "5"; settingKey: "refreshIntervalSec"; current: String(gp.refreshIntervalSec); numeric: true; minimum: 2 }
            SettingField { id: pauseField; label: strings.t("settings.pause"); placeholder: "30"; settingKey: "pauseMinutes"; current: String(gp.pauseMinutes); numeric: true; minimum: 1 }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.fill(strings.t("settings.footer"), [gp.portal + (gp.policy.portalName !== "" ? " (" + gp.policy.portalName + ")" : ""), "shell.json"])
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
        message: strings.t("forget.message")
        confirmText: strings.t("forget.confirm")
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
    Behavior on opacity {
      id: sectionFade
      NumberAnimation { duration: Style.duration(sectionFade.targetValue > 0 ? 180 : 120); easing.type: Easing.OutCubic }
    }
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
      textFormat: Text.PlainText
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
        Behavior on color { ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
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

  // The info rows' label column fits the widest label in the current
  // language (German "Meldet sich als", Greek "Τελευταίος έλεγχος"), so rows
  // stay aligned and labels aren't cut, within 96 to 150 px. The keys are the
  // labels the session and host rows use.
  FontMetrics {
    id: infoLabelMetrics
    font.family: gpPanel.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
  readonly property real infoLabelWidth: {
    var labels = [strings.t("session.address"), strings.t("session.connectedFor"), strings.t("session.dns"),
                  strings.t("session.gateway"), strings.t("session.routes"), strings.t("session.tunnel"),
                  strings.t("host.claims"), strings.t("host.host"), strings.t("host.lastCheck"), strings.t("host.reportsAs")]
    var font = infoLabelMetrics.font
    var widest = 0
    for (var i = 0; i < labels.length; i++) widest = Math.max(widest, infoLabelMetrics.advanceWidth(labels[i]))
    return Math.ceil(Math.min(Style.space(150), Math.max(Style.space(96), widest + 1)))
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
        width: gpPanel.infoLabelWidth
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: infoRow.value
        color: gpPanel.foreground
        font.family: gpPanel.fontFamily
        font.pixelSize: Style.font.body
        width: parent.width - gpPanel.infoLabelWidth - parent.spacing - (rowIcon.visible ? rowIcon.width + parent.spacing : 0)
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
        Behavior on color { ColorAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      }
    }
  }
}
