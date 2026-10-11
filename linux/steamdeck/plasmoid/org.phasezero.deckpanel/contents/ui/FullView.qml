import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami

Flickable {
    id: view

    required property var deck
    required property bool opacityReady
    required property bool opacityStyleSupported
    required property int opacityMode
    required property bool hideOutsideEdit
    required property string cpuText
    required property string ramText
    required property string diskText
    required property string diskFree
    required property real cpuPercent
    required property real ramPercent
    required property real diskPercent
    required property bool diskWarn
    required property string shortcutError

    signal opacityRequested(int mode)
    signal hideRequested(bool hide)

    readonly property int modeAdaptive: 0
    readonly property int modeOpaque: 1
    readonly property int modeTranslucent: 2

    contentWidth: width
    clip: true
    implicitWidth: Kirigami.Units.gridUnit * 22
    implicitHeight: Kirigami.Units.gridUnit * 28
    contentHeight: column.implicitHeight

    ColumnLayout {
        id: column
        width: view.width
        spacing: Kirigami.Units.smallSpacing

        Meter {
            title: "CPU"
            valueText: view.cpuText
            percent: view.cpuPercent
            Layout.fillWidth: true
        }
        Meter {
            title: "RAM"
            valueText: view.ramText
            percent: view.ramPercent
            Layout.fillWidth: true
        }
        Meter {
            title: "Disco"
            valueText: view.diskText + (view.diskFree.length > 0 ? " · " + view.diskFree + " livres" : "")
            percent: view.diskPercent
            warn: view.diskWarn
            Layout.fillWidth: true
        }

        PC3.Label {
            visible: view.shortcutError.length > 0
            text: view.shortcutError
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        Repeater {
            model: view.deck && view.deck.groups ? view.deck.groups : []

            ColumnLayout {
                required property var modelData
                spacing: Kirigami.Units.smallSpacing
                Layout.fillWidth: true

                PC3.Label {
                    text: modelData.title
                    font.bold: true
                    Layout.fillWidth: true
                }

                Repeater {
                    model: modelData.items

                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PC3.Label {
                            text: modelData.label
                            font.bold: true
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                            elide: Text.ElideRight
                        }
                        PC3.Label {
                            text: modelData.name + (modelData.keys && modelData.keys !== modelData.name ? " · " + modelData.keys : "")
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }

        PC3.Label {
            text: "Opacidade do painel"
            font.bold: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        RowLayout {
            visible: view.opacityReady && view.opacityStyleSupported
            Layout.fillWidth: true

            PC3.Button {
                text: "Adaptativo"
                checkable: true
                checked: view.opacityMode === view.modeAdaptive
                onClicked: view.opacityRequested(view.modeAdaptive)
            }
            PC3.Button {
                text: "Opaco"
                checkable: true
                checked: view.opacityMode === view.modeOpaque
                onClicked: view.opacityRequested(view.modeOpaque)
            }
            PC3.Button {
                text: "Translúcido"
                checkable: true
                checked: view.opacityMode === view.modeTranslucent
                onClicked: view.opacityRequested(view.modeTranslucent)
            }
        }

        PC3.Label {
            visible: !view.opacityReady || !view.opacityStyleSupported
            text: view.opacityReady
                  ? "O estilo atual do Plasma não oferece opacidade neste painel."
                  : "O widget ainda não alcançou o modo de opacidade deste painel. No modo de edição do painel: Opacidade → Translúcido."
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        PC3.CheckBox {
            text: "Ocultar fora do modo de edição"
            checked: view.hideOutsideEdit
            onToggled: view.hideRequested(checked)
        }

        PC3.Label {
            text: view.deck && view.deck.note ? view.deck.note : ""
            wrapMode: Text.Wrap
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            Layout.fillWidth: true
        }
    }
}
