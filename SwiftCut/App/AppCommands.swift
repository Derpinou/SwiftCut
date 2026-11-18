import Combine
import SwiftUI

/// État des menus. Les menus SwiftUI (`Commands`) ne suivent pas un modèle `@Observable` :
/// `EditorModel` recopie ici ce dont ils ont besoin.
@MainActor
final class MenuState: ObservableObject {
    struct Values: Equatable {
        var hasMedia = false
        var canExport = false
        var canDelete = false
        var isTrimMode = true
        var isTrimmed = false
        var isCropping = false
        var isCropped = false
        var isBlurring = false
    }

    @Published private(set) var values = Values()

    var hasMedia: Bool { values.hasMedia }
    var canExport: Bool { values.canExport }
    var canDelete: Bool { values.canDelete }
    var isTrimMode: Bool { values.isTrimMode }
    var isTrimmed: Bool { values.isTrimmed }
    var isCropping: Bool { values.isCropping }
    var isCropped: Bool { values.isCropped }
    var isBlurring: Bool { values.isBlurring }

    func update(_ newValues: Values) {
        guard newValues != values else { return }
        values = newValues
        // SwiftUI ne met à jour les éléments de menu qu'à leur ouverture ; sans ce rafraîchissement,
        // un raccourci (⌘E…) pourrait rester bloqué sur l'ancien état « désactivé ».
        DispatchQueue.main.async {
            for item in NSApp.mainMenu?.items ?? [] {
                if let menu = item.submenu { menu.delegate?.menuNeedsUpdate?(menu) }
            }
        }
    }
}

/// Menus de l'application. Les raccourcis à une seule touche sont gérés par `KeyboardMonitor`
/// (ils sont rappelés entre parenthèses dans les titres).
struct AppCommands: Commands {
    let editor: EditorModel
    @ObservedObject var state: MenuState

    private var hasMedia: Bool { state.hasMedia }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ouvrir…") { editor.presentOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Exporter…") { editor.showExportSheet() }
                .keyboardShortcut("e")
                .disabled(!state.canExport)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Annuler") { editor.undo() }
                .keyboardShortcut("z")
            Button("Rétablir") { editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Group {
                if state.isTrimMode {
                    Button("Début du passage à la tête de lecture  (I)") { editor.setTrimStart() }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Fin du passage à la tête de lecture  (O)") { editor.setTrimEnd() }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Button("Garder toute la vidéo") { editor.resetTrim() }
                        .disabled(!state.isTrimmed)
                } else {
                    Button("Scinder à la tête de lecture") { editor.splitAtPlayhead() }
                        .keyboardShortcut("b")
                    Button("Supprimer la sélection  (⌫)") { editor.deleteSelection() }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .disabled(!state.canDelete)
                    Button("Supprimer tout avant la tête de lecture") { editor.deleteBeforePlayhead() }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("Supprimer tout après la tête de lecture") { editor.deleteAfterPlayhead() }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Divider()
                    Button("Marquer le début de la sélection  (I)") { editor.markIn() }
                    Button("Marquer la fin de la sélection  (O)") { editor.markOut() }
                    Button("Tout désélectionner  (Échap)") { editor.clearSelection() }
                }
                Divider()
                Button(state.isCropping ? "Terminer le recadrage  (Entrée)" : "Recadrer l'image  (C)") {
                    editor.toggleCropping()
                }
                Button("Garder toute l'image") { editor.resetCrop() }
                    .disabled(!state.isCropped)
                Button(state.isBlurring ? "Terminer les flous  (Entrée)" : "Flouter des zones  (F)") {
                    editor.toggleBlurring()
                }
            }
            .disabled(!hasMedia)
        }

        CommandMenu("Lecture") {
            Group {
                Button("Lecture / Pause  (Espace)") { editor.togglePlayPause() }
                Divider()
                Button("Image précédente  (←)") { editor.step(frames: -1) }
                Button("Image suivante  (→)") { editor.step(frames: 1) }
                Button("Coupe précédente  (↑)") { editor.jumpToPreviousCut() }
                Button("Coupe suivante  (↓)") { editor.jumpToNextCut() }
                Divider()
                Button("Aller au début") { editor.goToStart() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Aller à la fin") { editor.goToEnd() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .disabled(!hasMedia)
        }

        CommandGroup(before: .toolbar) {
            Toggle("Mode Rogner (comme sur iPhone)", isOn: Binding(
                get: { state.isTrimMode },
                set: { if $0 { editor.setMode(.trim) } }
            ))
            .keyboardShortcut("1")
            Toggle("Mode Découper (plusieurs coupes)", isOn: Binding(
                get: { !state.isTrimMode },
                set: { if $0 { editor.setMode(.cut) } }
            ))
            .keyboardShortcut("2")
            Divider()
            Group {
                Button("Zoom avant") { editor.zoomIn() }
                    .keyboardShortcut("=")
                Button("Zoom arrière") { editor.zoomOut() }
                    .keyboardShortcut("-")
                Button("Afficher toute la timeline") { editor.zoomToFit() }
                    .keyboardShortcut("0")
            }
            .disabled(!hasMedia)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Raccourcis clavier") { editor.isShortcutsHelpPresented = true }
                .keyboardShortcut("/")
        }
    }
}
