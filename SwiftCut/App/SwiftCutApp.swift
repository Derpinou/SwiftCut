import AppKit
import SwiftUI

@main
struct SwiftCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let editor = EditorModel.shared

    var body: some Scene {
        Window("SwiftCut", id: "main") {
            EditorWindow()
                .environment(editor)
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(editor: editor, state: editor.menuState) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fichier ouvert depuis le Finder, le Dock ou « Ouvrir avec ».
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        EditorModel.shared.requestOpen(url)
    }

    /// On ne quitte pas en fermant la fenêtre si un montage ou un export est en cours :
    /// un clic sur l'icône du Dock la rouvre telle quelle.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let editor = EditorModel.shared
        return !editor.hasUnexportedChanges && !editor.isExporting
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let editor = EditorModel.shared
        if editor.isExporting {
            let alert = NSAlert()
            alert.messageText = "Une exportation est en cours"
            alert.informativeText = "Si vous quittez maintenant, l'exportation sera annulée."
            alert.addButton(withTitle: "Continuer l'exportation")
            alert.addButton(withTitle: "Quitter")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            editor.exportJob?.cancel()
            return .terminateNow
        }
        if editor.hasUnexportedChanges {
            let alert = NSAlert()
            alert.messageText = "Quitter sans exporter ?"
            alert.informativeText = "Les coupes de « \(editor.media?.url.lastPathComponent ?? "la vidéo") » n'ont pas été exportées et seront perdues."
            alert.addButton(withTitle: "Annuler")
            alert.addButton(withTitle: "Quitter")
            alert.buttons.last?.hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }
}
