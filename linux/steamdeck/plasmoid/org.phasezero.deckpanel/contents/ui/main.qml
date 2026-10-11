import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.ksysguard.sensors as Sensors
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property var deckMap: ({"groups": [], "note": ""})
    property string shortcutError: ""
    property var panelWindow: null

    readonly property bool panelEditMode: {
        const containment = Plasmoid.containment
        if (!containment || !containment.corona) {
            return false
        }
        return containment.corona.editMode === true
    }
    readonly property bool opacityReady: panelWindow !== null
    readonly property bool opacityStyleSupported: {
        if (!panelWindow) {
            return false
        }
        if (panelWindow.adaptiveOpacityEnabled === undefined) {
            return true
        }
        return panelWindow.adaptiveOpacityEnabled === true
    }
    readonly property int opacityMode: panelWindow && panelWindow.opacityMode !== undefined ? panelWindow.opacityMode : -1

    preferredRepresentation: compactRepresentation
    Plasmoid.icon: "input-gamepad"
    Plasmoid.status: (Plasmoid.configuration.hideOutsideEdit && !panelEditMode)
                     ? PlasmaCore.Types.HiddenStatus
                     : PlasmaCore.Types.PassiveStatus
    toolTipMainText: "PhaseZero Deck"
    toolTipSubText: "CPU " + cpuText + "  RAM " + ramText + "  Disco " + diskText

    function percentOf(sensor) {
        const value = Number(sensor.value)
        if (!Number.isFinite(value)) {
            return -1
        }
        return value
    }

    function percentText(sensor) {
        const value = percentOf(sensor)
        if (value < 0) {
            return "—"
        }
        return Math.round(value) + "%"
    }

    function formatBytes(value) {
        const number = Number(value)
        if (!Number.isFinite(number) || number < 0) {
            return ""
        }
        const units = ["B", "KiB", "MiB", "GiB", "TiB"]
        let size = number
        let index = 0
        while (size >= 1024 && index < units.length - 1) {
            size /= 1024
            index += 1
        }
        const digits = index === 0 ? 0 : 1
        return size.toFixed(digits) + " " + units[index]
    }

    readonly property real cpuPercent: percentOf(cpuSensor)
    readonly property real ramPercent: percentOf(ramSensor)
    readonly property real diskPercent: percentOf(diskSensor)
    readonly property string cpuText: percentText(cpuSensor)
    readonly property string ramText: percentText(ramSensor)
    readonly property string diskText: percentText(diskSensor)
    readonly property string diskFree: formatBytes(diskFreeSensor.value)
    readonly property bool diskWarn: diskPercent >= 90

    function loadShortcuts() {
        const xhr = new XMLHttpRequest()
        const url = Qt.resolvedUrl("../data/deck-shortcuts.json")
        xhr.open("GET", url)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) {
                return
            }
            if (xhr.status !== 200 && xhr.status !== 0) {
                root.shortcutError = "Mapa de atalhos indisponível."
                return
            }
            try {
                root.deckMap = JSON.parse(xhr.responseText)
                root.shortcutError = ""
            } catch (error) {
                root.shortcutError = "Mapa de atalhos ilegível."
            }
        }
        xhr.send()
    }

    function setOpacityMode(mode) {
        if (!opacityReady || !opacityStyleSupported) {
            return
        }
        panelWindow.opacityMode = mode
    }

    function setHideOutsideEdit(hide) {
        Plasmoid.configuration.hideOutsideEdit = hide
    }

    Component.onCompleted: loadShortcuts()

    Sensors.Sensor {
        id: cpuSensor
        sensorId: "cpu/all/usage"
        enabled: true
        updateRateLimit: 2000
    }
    Sensors.Sensor {
        id: ramSensor
        sensorId: "memory/physical/usedPercent"
        enabled: true
        updateRateLimit: 2000
    }
    Sensors.Sensor {
        id: diskSensor
        sensorId: "disk/all/usedPercent"
        enabled: true
        updateRateLimit: 2000
    }
    Sensors.Sensor {
        id: diskFreeSensor
        sensorId: "disk/all/free"
        enabled: true
        updateRateLimit: 2000
    }

    compactRepresentation: CompactView {
        cpuText: root.cpuText
        ramText: root.ramText
        diskText: root.diskText
        diskWarn: root.diskWarn
        onPanelFound: function(panel) {
            root.panelWindow = panel
        }
    }

    fullRepresentation: FullView {
        deck: root.deckMap
        opacityReady: root.opacityReady
        opacityStyleSupported: root.opacityStyleSupported
        opacityMode: root.opacityMode
        hideOutsideEdit: Plasmoid.configuration.hideOutsideEdit
        cpuText: root.cpuText
        ramText: root.ramText
        diskText: root.diskText
        diskFree: root.diskFree
        cpuPercent: root.cpuPercent
        ramPercent: root.ramPercent
        diskPercent: root.diskPercent
        diskWarn: root.diskWarn
        shortcutError: root.shortcutError
        onOpacityRequested: function(mode) {
            root.setOpacityMode(mode)
        }
        onHideRequested: function(hide) {
            root.setHideOutsideEdit(hide)
        }
    }
}
