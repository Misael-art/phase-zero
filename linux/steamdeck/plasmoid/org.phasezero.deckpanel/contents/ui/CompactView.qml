import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

RowLayout {
    id: compact
    signal panelFound(var panel)

    property string cpuText: "—"
    property string ramText: "—"
    property string diskText: "—"
    property bool diskWarn: false

    spacing: Kirigami.Units.smallSpacing

    function scan() {
        const win = Window.window
        if (win && win.opacityMode !== undefined) {
            compact.panelFound(win)
        }
    }

    Component.onCompleted: scan()

    Timer {
        interval: 500
        running: true
        repeat: true
        property int tries: 0
        onTriggered: {
            compact.scan()
            tries += 1
            if (tries > 8) {
                running = false
            }
        }
    }

    PC3.Label {
        text: "CPU " + compact.cpuText
        font.pointSize: Kirigami.Theme.smallFont.pointSize
    }
    PC3.Label {
        text: "RAM " + compact.ramText
        font.pointSize: Kirigami.Theme.smallFont.pointSize
    }
    PC3.Label {
        text: "Disco " + compact.diskText
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        color: compact.diskWarn ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
    }
}
