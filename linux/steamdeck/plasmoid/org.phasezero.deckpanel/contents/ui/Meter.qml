import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: meter
    property string title: ""
    property string valueText: "—"
    property real percent: 0
    property bool warn: false
    spacing: 2

    PC3.Label {
        text: meter.title + "  " + meter.valueText
        color: meter.warn ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        elide: Text.ElideRight
        Layout.fillWidth: true
    }

    PC3.ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: 100
        value: Math.max(0, Math.min(100, meter.percent))
    }
}
