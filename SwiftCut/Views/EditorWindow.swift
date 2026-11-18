import SwiftUI

/// Contenu de la fenêtre principale.
struct EditorWindow: View {
    @Environment(EditorModel.self) private var editor
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var editor = editor
        ZStack {
            if let media = editor.media {
                EditorView(media: media, isDropTargeted: isDropTargeted)
            } else {
                WelcomeView(isDropTargeted: isDropTargeted)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(white: 0.085))
        .overlay(alignment: .top) { NoticeBanner(message: editor.notice) }
        .overlay {
            if editor.isLoading {
                ProgressView("Chargement de la vidéo…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            editor.requestOpen(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .navigationTitle(editor.media?.url.lastPathComponent ?? "SwiftCut")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $editor.isExportSheetPresented, onDismiss: editor.exportSheetDidDismiss) {
            if let media = editor.media {
                ExportSheet(media: media, settings: editor.exportSettings)
            }
        }
        .background {
            Color.clear.sheet(item: $editor.exportJob) { job in
                ExportProgressView(job: job)
            }
        }
        .background {
            Color.clear.sheet(isPresented: $editor.isShortcutsHelpPresented) {
                ShortcutsHelpView()
            }
        }
        .alert("Oups", isPresented: errorBinding) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .confirmationDialog("Ouvrir une autre vidéo ?", isPresented: pendingOpenBinding, titleVisibility: .visible) {
            Button("Ouvrir sans exporter", role: .destructive) {
                if let url = editor.pendingOpenURL { editor.open(url) }
            }
            Button("Annuler", role: .cancel) { editor.pendingOpenURL = nil }
        } message: {
            Text("Les coupes en cours n'ont pas été exportées : elles seront perdues.")
        }
        .tint(.brand)
        .background(WindowAccessor { window in editor.window = window })
        .onAppear { KeyboardMonitor.shared.install(editor: editor) }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                editor.presentOpenPanel()
            } label: {
                Label("Ouvrir", systemImage: "folder")
            }
            .help("Ouvrir une vidéo (⌘O)")
        }
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(get: { editor.mode }, set: { editor.setMode($0) })) {
                ForEach(EditMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .disabled(editor.media == nil)
            .help("Rogner (⌘1) : garder un seul passage, comme sur iPhone · Découper (⌘2) : supprimer plusieurs passages")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { editor.isCropping },
                                 set: { $0 ? editor.beginCropping() : editor.finishCropping() })) {
                Label("Recadrer", systemImage: "crop")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .disabled(editor.media == nil)
            .help("Recadrer l'image, comme sur iPhone (C)")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: Binding(get: { editor.isBlurring },
                                 set: { $0 ? editor.beginBlurring() : editor.finishBlurring() })) {
                Label("Flouter", systemImage: "eye.slash")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .disabled(editor.media == nil)
            .help("Flouter ou pixeliser des zones de la vidéo (F)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                editor.showExportSheet()
            } label: {
                Label("Exporter", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(editor.media == nil || editor.isExporting)
            .help("Exporter la vidéo montée (⌘E)")
        }
    }

    private var subtitle: String {
        guard let media = editor.media else { return "" }
        var parts = ["\(Int(media.displaySize.width)) × \(Int(media.displaySize.height))",
                     Fmt.frameRate(media.frameRate),
                     media.videoCodecName]
        if let audio = media.audioCodecName { parts.append(audio) }
        if let size = media.fileSize { parts.append(Fmt.fileSize(size)) }
        if editor.isCropped {
            parts.append("recadré en \(Int(editor.croppedSize.width)) × \(Int(editor.croppedSize.height))")
        }
        if !editor.blurs.isEmpty {
            parts.append(editor.blurs.count > 1 ? "\(editor.blurs.count) flous" : "1 flou")
        }
        return parts.joined(separator: " · ")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })
    }

    private var pendingOpenBinding: Binding<Bool> {
        Binding(get: { editor.pendingOpenURL != nil }, set: { if !$0 { editor.pendingOpenURL = nil } })
    }
}

/// Vidéo, barre d'outils, timeline et pied de fenêtre.
private struct EditorView: View {
    @Environment(EditorModel.self) private var editor
    let media: MediaInfo
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            VideoPreview(media: media)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
                            .overlay {
                                Label("Déposez pour ouvrir cette vidéo", systemImage: "arrow.down.circle.fill")
                                    .font(.title3.weight(.semibold))
                            }
                            .padding(12)
                    }
                }
            if editor.isCropping {
                Divider()
                CropBar()
                    .background(Color(white: 0.1))
            } else if editor.isBlurring {
                Divider()
                BlurBar()
                    .background(Color(white: 0.1))
            }
            Divider()
            ControlBar()
                .background(Color(white: 0.12))
            TimelinePanel(media: media)
            Divider()
            StatusFooter(media: media)
                .background(Color(white: 0.12))
        }
    }
}

/// Message temporaire en haut de la fenêtre.
private struct NoticeBanner: View {
    let message: String?

    var body: some View {
        Group {
            if let message {
                Label(message, systemImage: "info.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: message)
    }
}
