import SwiftUI

/// Réglages d'export : format, encodage, résolution, cadence, qualité, son.
struct ExportSheet: View {
    @Environment(EditorModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    let media: MediaInfo
    @State private var settings: ExportSettings

    init(media: MediaInfo, settings: ExportSettings) {
        self.media = media
        _settings = State(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    Picker("Format", selection: $settings.format) {
                        ForEach(ExportSettings.Format.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.format.isVideo {
                        Picker("Encodage", selection: $settings.codec) {
                            ForEach(availableCodecs) { codec in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(codec.title)
                                    Text(codecSubtitle(codec))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(codec)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                } footer: {
                    if let note = formatNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if settings.format.isVideo, !settings.isPassthrough {
                    Section {
                        Picker("Résolution", selection: $settings.resolution) {
                            Text("Originale — \(sizeLabel(sourceSize))").tag(Int?.none)
                            ForEach(resolutionChoices, id: \.self) { value in
                                Text("\(value)p — \(sizeLabel(resolutionPreview(value)))").tag(Int?.some(value))
                            }
                        }
                        Picker("Images par seconde", selection: $settings.frameRate) {
                            Text("Originale — \(Fmt.frameRate(media.maxFrameRate))").tag(Int?.none)
                            ForEach(frameRateChoices, id: \.self) { value in
                                Text("\(value) i/s").tag(Int?.some(value))
                            }
                        }
                        if settings.effectiveCodec != .proRes {
                            Picker("Qualité", selection: $settings.quality) {
                                ForEach(ExportSettings.Quality.allCases) { quality in
                                    Text(quality.title).tag(quality)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    } footer: {
                        if let note = sizeLimitNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if settings.format == .gif {
                    Section {
                        Picker("Largeur", selection: $settings.gifWidth) {
                            ForEach(gifWidthChoices, id: \.self) { width in
                                Text(gifWidthLabel(width)).tag(width)
                            }
                        }
                        Picker("Images par seconde", selection: $settings.gifFrameRate) {
                            ForEach(ExportSettings.gifFrameRateChoices, id: \.self) { value in
                                Text("\(value) i/s").tag(value)
                            }
                        }
                    } footer: {
                        Text(editor.exportDuration > 30
                             ? "Ce GIF dure plus de 30 s : le fichier risque d'être très lourd. Le MP4 est bien plus léger."
                             : "Idéal pour un README, un ticket ou un message. Le GIF ne contient pas de son.")
                            .font(.caption)
                            .foregroundStyle(editor.exportDuration > 30 ? Color.orange : Color.secondary)
                    }
                }

                if settings.format.isVideo {
                    Section {
                        // Sans piste audio, l'interrupteur est éteint sans toucher au réglage mémorisé.
                        Toggle("Inclure le son", isOn: media.hasAudio ? $settings.includeAudio : .constant(false))
                            .disabled(!media.hasAudio)
                    } footer: {
                        if !media.hasAudio {
                            Text("Cette vidéo ne contient pas de son.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if settings.format == .m4a {
                    Section {
                        LabeledContent("Encodage", value: "AAC")
                    } footer: {
                        Text(media.hasAudio
                             ? "Exporte uniquement la bande son du montage."
                             : "Cette vidéo ne contient pas de son : rien à exporter.")
                            .font(.caption)
                            .foregroundStyle(media.hasAudio ? Color.secondary : Color.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()
            footer
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.format) { _, _ in normalizeSettings() }
        .onChange(of: settings.includeAudio) { _, _ in normalizeSettings() }
        .onAppear(perform: normalizeSettings)
    }

    // MARK: - Sous-vues

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.brand)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.brand.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporter la vidéo")
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            if let size = settings.estimatedFileSize(media: media, sourceSize: sourceSize, duration: editor.exportDuration) {
                Label(settings.isPassthrough
                      ? "Taille estimée : ≈ \(Fmt.fileSize(size))"
                      : "Taille estimée : jusqu'à \(Fmt.fileSize(size))",
                      systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("Un enregistrement d'écran peu animé donne souvent un fichier bien plus léger.")
            }
            Spacer()
            Button("Annuler", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Exporter…") {
                editor.confirmExportSettings(settings)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canExport)
        }
        .padding(16)
    }

    // MARK: - Logique

    private var subtitle: String {
        var parts = [Fmt.time(editor.exportDuration)]
        if editor.mode == .trim, editor.isTrimmed { parts.append("passage sélectionné") }
        parts.append(editor.isCropped ? "recadré en \(sizeLabel(sourceSize))" : sizeLabel(sourceSize))
        parts.append(media.videoCodecName)
        return parts.joined(separator: " · ")
    }

    /// Taille de l'image exportée avant redimensionnement : la zone recadrée.
    private var sourceSize: CGSize { editor.croppedSize }

    private var passthroughAvailable: Bool {
        // Copier le flux d'origine ne permet pas de modifier l'image.
        guard !editor.isCropped, editor.blurs.isEmpty else { return false }
        switch settings.format {
        case .mov:
            return true
        case .mp4:
            let audioOK = !settings.includeAudio || !media.hasAudio || media.audioCodecName == "AAC"
            return media.isVideoMP4Compatible && audioOK
        case .gif, .m4a:
            return false
        }
    }

    private var availableCodecs: [ExportSettings.Codec] {
        settings.format.codecs.filter { $0 != .passthrough || passthroughAvailable }
    }

    private var canExport: Bool {
        switch settings.format {
        case .m4a: media.hasAudio
        case .mp4, .mov: availableCodecs.contains(settings.codec)
        case .gif: true
        }
    }

    /// Les réglages mémorisés peuvent ne pas convenir à cette vidéo (résolution plus petite, son absent…).
    private func normalizeSettings() {
        if settings.format.isVideo, !availableCodecs.contains(settings.codec) {
            settings.codec = .h264
        }
        if let resolution = settings.resolution, !resolutionChoices.contains(resolution) {
            settings.resolution = nil
        }
        if let frameRate = settings.frameRate, !frameRateChoices.contains(frameRate) {
            settings.frameRate = nil
        }
        if !gifWidthChoices.contains(settings.gifWidth) {
            settings.gifWidth = gifWidthChoices.last { $0 <= 640 } ?? gifWidthChoices[0]
        }
    }

    private func codecSubtitle(_ codec: ExportSettings.Codec) -> String {
        if codec == .passthrough {
            return "Instantané et sans perte (\(media.videoCodecName) d'origine conservé)"
        }
        return codec.subtitle
    }

    private var formatNote: String? {
        if settings.format.isVideo, editor.isCropped || !editor.blurs.isEmpty {
            let what = editor.isCropped && !editor.blurs.isEmpty ? "recadrée et floutée" : (editor.isCropped ? "recadrée" : "floutée")
            return "L'image est \(what) : elle doit être réencodée, la copie sans réencodage n'est donc pas proposée."
        }
        if settings.format == .mp4, !passthroughAvailable {
            return "La copie sans réencodage n'est pas possible en MP4 pour cette vidéo (\(media.videoCodecName)\(media.audioCodecName.map { " / \($0)" } ?? "")). Elle reste disponible en MOV."
        }
        if settings.isPassthrough {
            return "Les coupes sont exactes dans QuickTime et la plupart des lecteurs ; certains lecteurs web peuvent afficher quelques images en trop autour des coupes."
        }
        return nil
    }

    private var resolutionChoices: [Int] {
        let shortSide = Int(min(sourceSize.width, sourceSize.height))
        return ExportSettings.resolutionChoices.filter { $0 < shortSide }
    }

    private var frameRateChoices: [Int] {
        ExportSettings.frameRateChoices.filter { Double($0) < media.maxFrameRate - 0.5 }
    }

    private var gifWidthChoices: [Int] {
        let widths = ExportSettings.gifWidthChoices.filter { CGFloat($0) < sourceSize.width }
        return widths.isEmpty ? [Int(sourceSize.width)] : widths
    }

    private func gifWidthLabel(_ width: Int) -> String {
        var preview = settings
        preview.gifWidth = width
        return "\(width) px — \(sizeLabel(preview.outputSize(for: sourceSize)))"
    }

    private func resolutionPreview(_ value: Int) -> CGSize {
        var preview = settings
        preview.resolution = value
        return preview.outputSize(for: sourceSize)
    }

    private var sizeLimitNote: String? {
        guard settings.effectiveCodec == .h264 else { return nil }
        var unlimited = settings
        unlimited.codec = .hevc
        let limited = settings.outputSize(for: sourceSize)
        let wanted = unlimited.outputSize(for: sourceSize)
        guard limited.width < wanted.width - 2 else { return nil }
        return "Le H.264 est limité à 4096 px : la vidéo sera réduite à \(sizeLabel(limited)). Choisissez HEVC pour conserver la pleine résolution."
    }

    private func sizeLabel(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }
}
