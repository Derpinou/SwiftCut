import SwiftUI

/// Barre d'outils entre la vidéo et la timeline : montage à gauche, transport au centre, historique et zoom à droite.
struct ControlBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        HStack(spacing: 0) {
            Group {
                if editor.mode == .trim {
                    trimTools
                } else {
                    cutTools
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(Fmt.time(editor.currentTime))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: 78, alignment: .trailing)

                IconButton(systemImage: "backward.end.fill", help: "Aller au début (Début ou ⌘←)") {
                    editor.goToStart()
                }
                IconButton(systemImage: "backward.frame.fill", help: "Image précédente (←)") {
                    editor.step(frames: -1)
                }
                Button {
                    editor.togglePlayPause()
                } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 38, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Lecture / pause (Espace)")
                IconButton(systemImage: "forward.frame.fill", help: "Image suivante (→)") {
                    editor.step(frames: 1)
                }
                IconButton(systemImage: "forward.end.fill", help: "Aller à la fin (Fin ou ⌘→)") {
                    editor.goToEnd()
                }

                Text(Fmt.time(editor.duration))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if editor.isPlaying, abs(editor.playbackRate) != 1, editor.playbackRate != 0 {
                            Text(rateLabel)
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.brand))
                                .foregroundStyle(.black)
                        }
                    }
            }

            HStack(spacing: 6) {
                IconButton(systemImage: "arrow.uturn.backward", help: "Annuler (⌘Z)") { editor.undo() }
                    .disabled(!editor.canUndo)
                IconButton(systemImage: "arrow.uturn.forward", help: "Rétablir (⇧⌘Z)") { editor.redo() }
                    .disabled(!editor.canRedo)

                Divider().frame(height: 18).padding(.horizontal, 4)

                IconButton(systemImage: "minus.magnifyingglass", help: "Zoom arrière (⌘-)") { editor.zoomOut() }
                Slider(value: $editor.zoomLevel, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 90)
                    .help("Zoom de la timeline (pincez ou ⌘ + molette)")
                IconButton(systemImage: "plus.magnifyingglass", help: "Zoom avant (⌘=)") { editor.zoomIn() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// Mode Rogner : placer le début et la fin du passage gardé.
    private var trimTools: some View {
        HStack(spacing: 6) {
            ToolButton(title: "Début ici", systemImage: "arrow.left.to.line",
                       help: "Commencer le passage à la tête de lecture (I)") {
                editor.setTrimStart()
            }
            ToolButton(title: "Fin ici", systemImage: "arrow.right.to.line",
                       help: "Terminer le passage à la tête de lecture (O)") {
                editor.setTrimEnd()
            }
            IconButton(systemImage: "arrow.counterclockwise", help: "Garder toute la vidéo") {
                editor.resetTrim()
            }
            .disabled(!editor.isTrimmed)
        }
    }

    /// Mode Découper : scinder et supprimer des passages.
    private var cutTools: some View {
        HStack(spacing: 6) {
            ToolButton(title: "Scinder", systemImage: "scissors",
                       help: "Scinder à la tête de lecture (⌘B)") {
                editor.splitAtPlayhead()
            }
            ToolButton(title: "Supprimer", systemImage: "trash",
                       help: "Supprimer la sélection ou le segment sélectionné (⌫)") {
                editor.deleteSelection()
            }
            .disabled(!editor.canDelete)

            Divider().frame(height: 18).padding(.horizontal, 4)

            IconButton(systemImage: "arrow.left.to.line",
                       help: "Supprimer tout ce qui précède la tête de lecture (⌥⌘←)") {
                editor.deleteBeforePlayhead()
            }
            IconButton(systemImage: "arrow.right.to.line",
                       help: "Supprimer tout ce qui suit la tête de lecture (⌥⌘→)") {
                editor.deleteAfterPlayhead()
            }
        }
    }

    private var rateLabel: String {
        let rate = editor.playbackRate
        return rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.1f×", rate)
    }
}

/// Bas de fenêtre : résumé du montage et aide contextuelle.
struct StatusFooter: View {
    @Environment(EditorModel.self) private var editor
    let media: MediaInfo

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(hint)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Text(editor.mode == .trim ? "Durée exportée" : "Durée finale")
                    .foregroundStyle(.secondary)
                Text(Fmt.time(editor.exportDuration))
                    .fontWeight(.semibold)
                if editor.removedDuration > 0.005 {
                    Text("(−\(Fmt.time(editor.removedDuration)))")
                        .foregroundStyle(Color.brand)
                }
            }
            .monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private var summary: String {
        if editor.mode == .trim {
            let range = editor.trimRange
            if editor.isTrimmed { return "Passage : \(Fmt.time(range.start)) → \(Fmt.time(range.end))" }
            return editor.edits.segments.count > 1 ? "Tout le montage" : "Toute la vidéo"
        }
        let count = editor.edits.segments.count
        let cuts = max(0, count - 1)
        let segments = count > 1 ? "\(count) segments" : "1 segment"
        return cuts > 0 ? "\(segments) · \(cuts) coupe\(cuts > 1 ? "s" : "")" : segments
    }

    private var hint: String {
        if editor.mode == .trim {
            return editor.isTrimmed
                ? "Seul le passage encadré sera exporté · I / O pour placer le début / la fin"
                : "Faites glisser les poignées pour choisir le passage à exporter · I / O pour placer le début / la fin"
        }
        if let selection = editor.selection, selection.duration > 0 {
            return "⌫ supprime la sélection (\(Fmt.time(selection.duration))) · Échap pour désélectionner"
        }
        if editor.selectedSegmentID != nil {
            return "⌫ supprime le segment sélectionné · Échap pour désélectionner"
        }
        return "Glissez sur la timeline pour sélectionner un passage · I / O pour marquer · ⌘B pour scinder · ? pour l'aide"
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help(help)
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
