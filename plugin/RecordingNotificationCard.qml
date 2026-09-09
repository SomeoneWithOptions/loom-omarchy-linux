// Rich Loom recording notification card. Pure presentational component.
// Follows the system card's "macOS" logic: small header (glyph + UPPERCASE
// app + hover close), title semibold, muted secondary text, DM Sans, inner
// radius nested at outer-4. Media and the upload action sit under the title
// where the system card puts its body.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

BorderSurface {
  id: root

  property string summary: ""
  property string image: ""
  property string recordingPath: ""
  property color accent: Color.urgent
  property int cornerRadius: 0

  readonly property bool hovered: hoverTracker.hovered

  signal playRequested()
  signal uploadRequested()
  signal closeRequested()

  readonly property string resolvedPreviewSource: imageSource(image)

  // Same palette derivation as the system card so both stacks read as one
  // surface: card lifted off the drawer, text at full / 62% opacity.
  readonly property color textColor: Color.notifications.text
  readonly property color secondaryColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.62)
  readonly property color cardBg: Qt.lighter(Color.notifications.background, 1.1)
  readonly property color hairline: Qt.rgba(1, 1, 1, 0.09)
  readonly property color inset: Qt.rgba(1, 1, 1, 0.05)
  readonly property int innerRadius: Math.max(10, cornerRadius - 4)
  readonly property int mediaRadius: Style.space(10)

  function imageSource(src) {
    var value = String(src || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  implicitWidth: Style.space(360)
  implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
  radius: innerRadius
  color: cardBg
  borderSpec: Border.flat(root.hairline, Math.max(1, Math.round(Style.space(1))))
  clip: true
  antialiasing: true
  smooth: true

  HoverHandler { id: hoverTracker }

  // Root background right-click dismiss
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.closeRequested()
      }
    }
  }

  ColumnLayout {
    id: mainColumn
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.borderTop
    anchors.leftMargin: root.borderLeft
    anchors.rightMargin: root.borderRight
    spacing: 0

    // Header: glyph + LOOM + hover close, on the system card's grid.
    RowLayout {
      id: headerRow
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(14)
      Layout.topMargin: Style.space(11)
      spacing: Style.space(6)

      Item {
        Layout.preferredWidth: Style.space(18)
        Layout.preferredHeight: Style.space(18)

        Text {
          anchors.centerIn: parent
          text: "󰕧"
          textFormat: Text.PlainText
          color: root.secondaryColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
        }
      }

      Text {
        Layout.fillWidth: true
        text: "LOOM"
        textFormat: Text.PlainText
        color: root.secondaryColor
        font.family: "DM Sans"
        font.pixelSize: Style.font.caption
        font.weight: Font.Medium
        font.letterSpacing: 0.8
        elide: Text.ElideRight
        renderType: Text.NativeRendering
      }

      // Hover close affordance. Space always reserved — opacity only,
      // so hover never shifts layout.
      Item {
        id: closeButton
        Layout.preferredWidth: Style.space(20)
        Layout.preferredHeight: Style.space(20)
        opacity: root.hovered ? 1 : 0

        Text {
          anchors.centerIn: parent
          text: "×"
          textFormat: Text.PlainText
          color: closeMouse.containsMouse ? root.textColor : root.secondaryColor
          font.family: "DM Sans"
          font.pixelSize: Style.font.subtitle
          renderType: Text.NativeRendering
        }

        MouseArea {
          id: closeMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          enabled: root.hovered
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton
          onClicked: root.closeRequested()
        }
      }
    }

    Text {
      id: title
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(16)
      Layout.topMargin: Style.space(5)
      text: root.summary.length > 0 ? root.summary : "Screen recording saved"
      textFormat: Text.PlainText
      color: root.textColor
      font.family: "DM Sans"
      font.pixelSize: Style.font.subtitle
      font.weight: Font.DemiBold
      wrapMode: Text.WordWrap
      elide: Text.ElideRight
      maximumLineCount: 2
      lineHeight: 1.2
      renderType: Text.NativeRendering
    }

    // Video preview: fixed 112px tall, aspect preserved without distortion
    Rectangle {
      id: preview
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(16)
      Layout.topMargin: Style.space(9)
      Layout.preferredHeight: Style.space(112)
      color: root.inset
      radius: root.mediaRadius
      clip: true

      // Intentional placeholder when image is missing or failed to load
      Rectangle {
        anchors.fill: parent
        color: Qt.darker(Color.notifications.background, 1.15)
        radius: parent.radius
        visible: !root.resolvedPreviewSource || previewImage.status !== Image.Ready

        Text {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -Style.space(6)
          text: "󰕧"
          textFormat: Text.PlainText
          color: Util.alpha(root.textColor, 0.15)
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          renderType: Text.NativeRendering
        }
      }

      Image {
        id: previewImage
        anchors.fill: parent
        anchors.margins: 1
        source: root.resolvedPreviewSource
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        mipmap: true
        visible: status === Image.Ready
      }

      // Play button circle overlay
      Rectangle {
        width: Style.space(38)
        height: width
        radius: width / 2
        anchors.centerIn: parent
        color: Util.alpha("#000000", previewMouse.containsMouse ? 0.72 : 0.58)
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha("#ffffff", previewMouse.containsMouse ? 0.35 : 0.15)

        Text {
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: Style.space(2)
          text: "󰐊"
          textFormat: Text.PlainText
          color: "white"
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          renderType: Text.NativeRendering
        }
      }

      // "Play local video" badge — the system card's muted body text, over media.
      Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(9)
        text: "Play local video"
        textFormat: Text.PlainText
        color: "white"
        font.family: "DM Sans"
        font.pixelSize: Style.font.caption
        font.weight: Font.Medium
        font.letterSpacing: 0.8
        style: Text.Outline
        styleColor: Util.alpha("#000000", 0.8)
        renderType: Text.NativeRendering
      }

      MouseArea {
        id: previewMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) {
            root.closeRequested()
          } else {
            root.playRequested()
          }
        }
      }
    }

    // Compact Upload to Loom button
    Rectangle {
      id: uploadAction
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(16)
      Layout.topMargin: Style.space(9)
      Layout.bottomMargin: Style.space(13)
      Layout.preferredHeight: Style.space(38)
      color: uploadMouse.containsMouse ? Util.alpha(root.accent, 0.18) : root.inset
      radius: root.mediaRadius
      border.width: Math.max(1, Math.round(Style.space(1)))
      border.color: uploadMouse.containsMouse ? root.accent : root.hairline

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        spacing: Style.space(10)

        Text {
          text: "󰕒"
          textFormat: Text.PlainText
          color: root.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.icon
          renderType: Text.NativeRendering
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          text: "Upload to Loom"
          textFormat: Text.PlainText
          color: root.textColor
          font.family: "DM Sans"
          font.pixelSize: Style.font.subtitle
          font.weight: Font.DemiBold
          renderType: Text.NativeRendering
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          elide: Text.ElideRight
        }

        Text {
          text: "›"
          textFormat: Text.PlainText
          color: root.accent
          font.family: "DM Sans"
          font.pixelSize: Style.font.heading
          font.weight: Font.DemiBold
          renderType: Text.NativeRendering
          Layout.alignment: Qt.AlignVCenter
        }
      }

      MouseArea {
        id: uploadMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) {
            root.closeRequested()
          } else {
            root.uploadRequested()
          }
        }
      }
    }
  }
}
