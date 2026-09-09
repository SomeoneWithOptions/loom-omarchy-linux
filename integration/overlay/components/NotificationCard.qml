// Variant A — "macOS".
// Apple Notification Center logic: small header (icon + UPPERCASE app + time),
// title semibold, body muted regular. No big left icon slab. DM Sans.
// Keeps outer black drawer untouched; inner radius nests at outer-4.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "../NotificationLogic.js" as NotificationLogic

BorderSurface {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  property string glyph: ""
  property int urgency: 1
  property double timestamp: 0
  property int cornerRadius: 0
  property string fontFamily: ""

  readonly property bool hovered: hoverTracker.hovered

  signal closeRequested()
  signal cardClicked()

  readonly property string smallIconSource: image.length > 0 ? image : iconSource(appIcon)
  readonly property bool hasGlyph: glyph.length > 0
  readonly property bool hasSmallIcon: smallIconSource.length > 0
  readonly property bool summaryStartsWithGlyph: NotificationLogic.summaryStartsWithGlyph(summary)
  readonly property bool singleLineToast: sanitizedBody.length === 0
  readonly property string sanitizedBody: sanitizeBody(body)
  readonly property string styledBody: NotificationLogic.styledBody(body, app, appIcon)
  // Photo/file preview on the right; themed app icons stay in the header.
  readonly property bool hasPhoto: image.length > 0
  readonly property bool showHeaderIcon: !hasPhoto && (hasSmallIcon || hasGlyph)

  readonly property color textColor: Color.notifications.text
  readonly property color secondaryColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.62)
  readonly property color cardBg: Qt.lighter(Color.notifications.background, 1.1)
  readonly property int innerRadius: Math.max(10, cornerRadius - 4)

  function sanitizeBody(s) {
    return NotificationLogic.sanitizeBody(s, app, appIcon)
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function displayApp() {
    var a = String(app || "")
    if (a === "notify-send") return "Script"
    if (a === "omarchy-action") return "System"
    if (a.length === 0) return "Notification"
    return a
  }

  implicitWidth: Style.space(360)
  implicitHeight: mainColumn.implicitHeight + borderTop + borderBottom
  radius: innerRadius
  color: cardBg
  borderSpec: Border.flat(Qt.rgba(1, 1, 1, 0.09), Math.max(1, Math.round(Style.space(1))))
  clip: true
  antialiasing: true
  smooth: true

  HoverHandler { id: hoverTracker }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.closeRequested()
      else root.cardClicked()
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

    // Header: icon + APP + time. Hidden for bare System toasts with glyph prefix.
    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(14)
      Layout.topMargin: Style.space(11)
      spacing: Style.space(6)
      visible: !(root.app === "omarchy-action" && root.summaryStartsWithGlyph)

      Item {
        Layout.preferredWidth: Style.space(18)
        Layout.preferredHeight: Style.space(18)
        visible: root.showHeaderIcon && headerImg.status !== Image.Error

        Image {
          id: headerImg
          anchors.fill: parent
          source: root.smallIconSource
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
          visible: !root.hasGlyph || status === Image.Ready
        }
        Text {
          anchors.centerIn: parent
          visible: root.hasGlyph && headerImg.status !== Image.Ready
          text: root.glyph
          textFormat: Text.PlainText
          color: root.secondaryColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
        }
      }

      Text {
        Layout.fillWidth: true
        text: root.displayApp().toUpperCase()
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
          onClicked: root.closeRequested()
        }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(16)
      Layout.rightMargin: Style.space(16)
      Layout.topMargin: Style.space(5)
      Layout.bottomMargin: Style.space(13)
      spacing: Style.space(12)

      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(3)

        Text {
          Layout.fillWidth: true
          visible: root.summary.length > 0
          text: root.summary
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

        Text {
          Layout.fillWidth: true
          visible: root.sanitizedBody.length > 0
          text: root.styledBody
          textFormat: Text.StyledText
          color: root.secondaryColor
          font.family: "DM Sans"
          font.pixelSize: Style.font.body
          lineHeight: 1.35
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 4
          renderType: Text.NativeRendering
        }
      }

      // Photo preview (screenshots, avatars) — rounded, right side.
      Item {
        Layout.preferredWidth: Style.space(56)
        Layout.preferredHeight: Style.space(56)
        Layout.alignment: Qt.AlignVCenter
        visible: root.hasPhoto && previewImg.status !== Image.Error
        Rectangle {
          anchors.fill: parent
          radius: Style.space(10)
          color: Qt.rgba(1, 1, 1, 0.05)
          Image {
            id: previewImg
            anchors.fill: parent
            anchors.margins: 1
            source: root.image
            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            smooth: true
            mipmap: true
          }
        }
      }
    }
  }
}
