import QtQuick
import QtQuick.Shapes
import qs.Commons

// Natively drawn GlobalProtect mark: a shield with a keyhole, plus a ring that
// orbits while a connection is being made and seals into a full circle once
// the tunnel is up. Drawn with QtQuick.Shapes so it stays crisp at bar size
// and hero size alike and takes the theme's colors directly.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color ringColor: color
  property color badgeColor: Color.urgent
  property color holeColor: Color.background
  // off | busy | on | error
  property string state: "off"

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property bool busy: state === "busy"
  readonly property bool on: state === "on"
  readonly property bool errored: state === "error"
  property real ringSweep: on ? 360 : (busy ? 100 : 0)
  readonly property real bodyOpacity: (state === "off") ? 0.55 : 1.0

  Behavior on ringSweep { NumberAnimation { duration: 360; easing.type: Easing.InOutCubic } }

  Shape {
    id: shield
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    opacity: root.bodyOpacity
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.color
      startX: root.iconSize * 0.5
      startY: root.iconSize * 0.06
      PathLine { x: root.iconSize * 0.88; y: root.iconSize * 0.22 }
      PathCubic {
        x: root.iconSize * 0.5; y: root.iconSize * 0.96
        control1X: root.iconSize * 0.9; control1Y: root.iconSize * 0.7
        control2X: root.iconSize * 0.72; control2Y: root.iconSize * 0.88
      }
      PathCubic {
        x: root.iconSize * 0.12; y: root.iconSize * 0.22
        control1X: root.iconSize * 0.28; control1Y: root.iconSize * 0.88
        control2X: root.iconSize * 0.1; control2Y: root.iconSize * 0.7
      }
      PathLine { x: root.iconSize * 0.5; y: root.iconSize * 0.06 }
    }
  }

  // Keyhole: a dot with a short stem, cut out in the background color.
  Item {
    id: keyhole
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -root.iconSize * 0.04
    width: root.iconSize * 0.24
    height: root.iconSize * 0.36
    opacity: root.bodyOpacity

    Rectangle {
      width: parent.width
      height: parent.width
      radius: width / 2
      color: root.holeColor
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
    }
    Rectangle {
      width: Math.max(1.5, parent.width * 0.42)
      height: parent.height - parent.width * 0.55
      color: root.holeColor
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      radius: width / 2
    }
  }

  // Orbiting / sealing ring.
  Shape {
    id: ring
    anchors.centerIn: parent
    width: root.iconSize * 1.5
    height: width
    preferredRendererType: Shape.CurveRenderer
    visible: root.ringSweep > 0.5
    opacity: root.on ? 0.38 : 1.0
    Behavior on opacity { NumberAnimation { duration: 360; easing.type: Easing.InOutCubic } }

    ShapePath {
      strokeColor: root.ringColor
      strokeWidth: Math.max(1.5, root.iconSize * 0.09)
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: ring.width / 2
        centerY: ring.height / 2
        radiusX: ring.width / 2 - Math.max(1.5, root.iconSize * 0.09)
        radiusY: ring.height / 2 - Math.max(1.5, root.iconSize * 0.09)
        startAngle: -90
        sweepAngle: root.ringSweep
      }
    }

    NumberAnimation on rotation {
      id: orbit
      from: 0
      to: 360
      duration: 1100
      loops: Animation.Infinite
      running: root.busy
      easing.type: Easing.InOutCubic
    }

    onRotationChanged: if (!root.busy && rotation !== 0 && !rotationReset.running) rotationReset.start()

    NumberAnimation {
      id: rotationReset
      target: ring
      property: "rotation"
      to: 0
      duration: 240
      easing.type: Easing.OutCubic
    }
  }

  // Error badge, bottom-right.
  Rectangle {
    visible: root.errored
    width: Math.max(5, root.iconSize * 0.34)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -root.iconSize * 0.06
    anchors.bottomMargin: -root.iconSize * 0.02
    border.width: 1
    border.color: root.holeColor
  }
}
