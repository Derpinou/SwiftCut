import AppKit

/// Raccourcis à une touche (Espace, flèches, J/K/L, I/O, ⌫…), gérés hors des menus
/// pour ne jamais voler une frappe à un champ de texte.
@MainActor
final class KeyboardMonitor {
    static let shared = KeyboardMonitor()
    private var monitor: Any?

    func install(editor: EditorModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { Self.handle(event, editor: editor) }
            return handled ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, editor: EditorModel) -> Bool {
        guard let window = editor.window, event.window === window,
              window.attachedSheet == nil, editor.media != nil else { return false }
        if let text = window.firstResponder as? NSText, text.isEditable { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isDisjoint(with: [.command, .option, .control]) else { return false }
        let shift = flags.contains(.shift)

        switch event.keyCode {
        case 49: // Espace
            if !event.isARepeat { editor.togglePlayPause() }
        case 123: // ←
            shift ? editor.seek(to: editor.currentTime - 1) : editor.step(frames: -1)
        case 124: // →
            shift ? editor.seek(to: editor.currentTime + 1) : editor.step(frames: 1)
        case 126: // ↑
            editor.jumpToPreviousCut()
        case 125: // ↓
            editor.jumpToNextCut()
        case 115: // Début
            editor.goToStart()
        case 119: // Fin
            editor.goToEnd()
        case 51, 117: // ⌫, ⌦
            guard !event.isARepeat else { break }
            editor.isBlurring ? editor.deleteSelectedBlur() : editor.deleteSelection()
        case 53: // Échap
            if editor.isCropping {
                editor.cancelCropping()
            } else if editor.isBlurring {
                editor.selectedBlurID == nil ? editor.finishBlurring() : (editor.selectedBlurID = nil)
            } else {
                editor.clearSelection()
            }
        case 36, 76: // Entrée
            if editor.isCropping {
                editor.finishCropping()
            } else if editor.isBlurring {
                editor.finishBlurring()
            } else {
                return false
            }
        default:
            guard let key = event.charactersIgnoringModifiers?.lowercased(), !event.isARepeat else { return false }
            switch key {
            case "j": editor.shuttle(forward: false)
            case "k": editor.pause()
            case "l": editor.shuttle(forward: true)
            case "i": editor.markIn()
            case "o": editor.markOut()
            case "b": editor.splitAtPlayhead()
            case "c": editor.toggleCropping()
            case "f": editor.toggleBlurring()
            case "?": editor.isShortcutsHelpPresented = true
            default: return false
            }
        }
        return true
    }
}
