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
  // Outlines the error badge, so it reads against the shield it overlaps.
  property color holeColor: Color.background
  // off | busy | on | error
  property string state: "off"
  // The bar sets this false. Omarchy fits a bar icon's visible bounds into
  // one icon box, so a ring around the shield would shrink the shield by a
  // third whenever it showed. There the shield alone carries the state.
  property bool showRing: true

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property bool busy: state === "busy"
  readonly property bool on: state === "on"
  readonly property bool errored: state === "error"
  property real ringSweep: on ? 360 : (busy ? 100 : 0)
  readonly property real bodyOpacity: (state === "off") ? 0.55 : 1.0

  // The ring draws in as the connection starts and seals, and withdraws a
  // little faster when it ends. Style.duration() makes both instant when the
  // user has turned animations off.
  Behavior on ringSweep {
    id: sweepBehavior
    NumberAnimation {
      // targetValue is set before the animation starts, so this reads the
      // direction of the change rather than racing the state bindings.
      duration: Style.duration(sweepBehavior.targetValue > 0 ? 280 : 180)
      easing.type: Easing.Bezier
      easing.bezierCurve: Style.easeOut
    }
  }

  // The shield, with the keyhole cut through it as a second subpath, so
  // whatever is behind the icon shows through the hole at any opacity.
  Shape {
    id: shield
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    opacity: root.bodyOpacity
    Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

    readonly property real s: root.iconSize
    // Keyhole: a round head over a stem that widens toward the bottom.
    readonly property real holeX: s * 0.5
    readonly property real holeY: s * 0.40
    readonly property real holeR: s * 0.125
    // Where the stem leaves the head, 35 degrees either side of straight down.
    readonly property real joinDx: holeR * Math.sin(35 * Math.PI / 180)
    readonly property real joinDy: holeR * Math.cos(35 * Math.PI / 180)
    readonly property real stemBottom: s * 0.68
    readonly property real stemHalf: s * 0.095

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.color
      fillRule: ShapePath.OddEvenFill
      startX: shield.s * 0.5
      startY: shield.s * 0.06
      PathLine { x: shield.s * 0.88; y: shield.s * 0.22 }
      PathCubic {
        x: shield.s * 0.5; y: shield.s * 0.96
        control1X: shield.s * 0.9; control1Y: shield.s * 0.7
        control2X: shield.s * 0.72; control2Y: shield.s * 0.88
      }
      PathCubic {
        x: shield.s * 0.12; y: shield.s * 0.22
        control1X: shield.s * 0.28; control1Y: shield.s * 0.88
        control2X: shield.s * 0.1; control2Y: shield.s * 0.7
      }
      PathLine { x: shield.s * 0.5; y: shield.s * 0.06 }

      PathMove { x: shield.holeX - shield.joinDx; y: shield.holeY + shield.joinDy }
      PathArc {
        x: shield.holeX + shield.joinDx; y: shield.holeY + shield.joinDy
        radiusX: shield.holeR; radiusY: shield.holeR
        useLargeArc: true
        direction: PathArc.Clockwise
      }
      PathLine { x: shield.holeX + shield.stemHalf; y: shield.stemBottom }
      PathLine { x: shield.holeX - shield.stemHalf; y: shield.stemBottom }
      PathLine { x: shield.holeX - shield.joinDx; y: shield.holeY + shield.joinDy }
    }
  }

  // Orbiting / sealing ring.
  Shape {
    id: ring
    anchors.centerIn: parent
    width: root.iconSize * 1.5
    height: width
    preferredRendererType: Shape.CurveRenderer
    visible: root.showRing && root.ringSweep > 0.5
    opacity: root.on ? 0.38 : 1.0
    Behavior on opacity { NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic } }

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

    // A steady orbit while connecting, like the shell's own spinners. It
    // stays still when animations are off: a looping animation with no
    // duration would spin flat out. The partial ring still says "busy".
    NumberAnimation on rotation {
      id: orbit
      from: 0
      to: 360
      duration: Style.duration(1100)
      loops: Animation.Infinite
      running: root.showRing && root.busy && !Style.reduceMotion
    }

    onRotationChanged: if (!root.busy && rotation !== 0 && !rotationReset.running) rotationReset.start()

    NumberAnimation {
      id: rotationReset
      target: ring
      property: "rotation"
      to: 0
      duration: Style.duration(240)
      easing.type: Easing.OutCubic
    }
  }

  // Error badge over the shield's lower right. It stays inside the shield's
  // own bounds so the bar doesn't rescale the icon when an error appears,
  // and it is a Shape like the rest of the mark: a small bordered Rectangle
  // smears its border once the bar scales it to a fractional size.
  Shape {
    id: badge
    visible: root.errored
    readonly property real d: Math.max(6, root.iconSize * 0.42)
    width: d
    height: d
    x: root.iconSize * 0.88 - d
    y: root.iconSize * 0.96 - d
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.badgeColor
      strokeColor: root.holeColor
      strokeWidth: 1
      // A Shape pads its bounds by the stroke width over root 2, so this
      // radius keeps the stroked circle's bounds exactly d wide.
      PathAngleArc {
        centerX: badge.d / 2
        centerY: badge.d / 2
        radiusX: badge.d / 2 - Math.SQRT1_2
        radiusY: badge.d / 2 - Math.SQRT1_2
        startAngle: 0
        sweepAngle: 360
      }
    }
  }
}
