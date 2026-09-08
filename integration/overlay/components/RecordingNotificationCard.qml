// Rich Loom recording notification card. Pure presentational component.
// Matches 360px system notification card width with a compact visual hierarchy.

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
  readonly property var cardBorderSpec: Border.surfaceSpec("notifications", "border", Color.notifications.border, Math.max(1, Style.space(2)))

  function imageSource(src) {
    var value = String(src || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  implicitWidth: Style.space(360)
  implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
  radius: cornerRadius
  color: Color.notifications.background
  borderSpec: cardBorderSpec
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

    // Header row: compact title and isolated close button
    Item {
      id: headerRow
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(34)

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.right: closeButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.summary.length > 0 ? root.summary : "Screen recording saved"
        textFormat: Text.PlainText
        color: Color.notifications.text
        font.family: "Noto Sans"
        font.pixelSize: Style.font.title
        font.weight: Font.DemiBold
        elide: Text.ElideRight
        renderType: Text.NativeRendering
      }

      Item {
        id: closeButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(24)
        height: Style.space(24)

        Text {
          anchors.centerIn: parent
          text: "×"
          textFormat: Text.PlainText
          color: closeMouse.containsMouse ? Color.notifications.text : Qt.darker(Color.notifications.text, 1.4)
          font.family: "Noto Sans"
          font.pixelSize: Style.font.heading
          renderType: Text.NativeRendering
        }

        MouseArea {
          id: closeMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton
          onClicked: root.closeRequested()
        }
      }
    }

    // Video preview: fixed 112px tall, aspect preserved without distortion
    Rectangle {
      id: preview
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(10)
      Layout.rightMargin: Style.space(10)
      Layout.preferredHeight: Style.space(112)
      color: Qt.darker(Color.notifications.background, 1.25)
      radius: Math.min(root.cornerRadius, Style.space(6))
      clip: true

      // Intentional placeholder when image is missing or failed to load
      Rectangle {
        anchors.fill: parent
        color: Qt.darker(Color.notifications.background, 1.35)
        visible: !root.resolvedPreviewSource || previewImage.status !== Image.Ready

        Text {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -Style.space(6)
          text: "󰕧"
          textFormat: Text.PlainText
          color: Util.alpha(Color.notifications.text, 0.15)
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          renderType: Text.NativeRendering
        }
      }

      Image {
        id: previewImage
        anchors.fill: parent
        source: root.resolvedPreviewSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
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

      // "Play local video" badge
      Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(8)
        text: "Play local video"
        textFormat: Text.PlainText
        color: "white"
        font.family: "Noto Sans"
        font.pixelSize: Style.font.caption
        font.weight: Font.DemiBold
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
      Layout.leftMargin: Style.space(10)
      Layout.rightMargin: Style.space(10)
      Layout.topMargin: Style.space(8)
      Layout.bottomMargin: Style.space(10)
      Layout.preferredHeight: Style.space(38)
      color: uploadMouse.containsMouse ? Util.alpha(root.accent, 0.18) : Qt.darker(Color.notifications.background, 1.25)
      radius: Math.min(root.cornerRadius, Style.space(6))
      border.width: Math.max(1, Style.space(1))
      border.color: uploadMouse.containsMouse ? root.accent : Color.notifications.border

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
          color: Color.notifications.text
          font.family: "Noto Sans"
          font.pixelSize: Style.font.title
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
          font.family: "Noto Sans"
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
