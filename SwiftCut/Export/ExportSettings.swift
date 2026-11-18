import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

/// Réglages choisis dans la fenêtre d'export. Mémorisés d'une session à l'autre.
struct ExportSettings: Codable, Equatable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case mp4, mov, gif, m4a
        var id: Self { self }

        var title: String {
            switch self {
            case .mp4: "MP4"
            case .mov: "MOV"
            case .gif: "GIF"
            case .m4a: "Audio"
            }
        }

        var fileExtension: String { rawValue }

        var contentType: UTType {
            switch self {
            case .mp4: .mpeg4Movie
            case .mov: .quickTimeMovie
            case .gif: .gif
            case .m4a: .mpeg4Audio
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            case .gif: AVFileType(UTType.gif.identifier)
            case .m4a: .m4a
            }
        }

        var codecs: [Codec] {
            switch self {
            case .mp4: [.h264, .hevc, .passthrough]
            case .mov: [.h264, .hevc, .proRes, .passthrough]
            case .gif, .m4a: []
            }
        }

        var isVideo: Bool { self == .mp4 || self == .mov }
    }

    enum Codec: String, Codable, CaseIterable, Identifiable {
        case h264, hevc, proRes, passthrough
        var id: Self { self }

        var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC (H.265)"
            case .proRes: "ProRes 422"
            case .passthrough: "Sans réencodage"
            }
        }

        var subtitle: String {
            switch self {
            case .h264: "Compatible partout"
            case .hevc: "Fichier plus léger, appareils récents"
            case .proRes: "Qualité maximale pour le montage, très lourd"
            case .passthrough: "Instantané et sans perte"
            }
        }
    }

    enum Quality: String, Codable, CaseIterable, Identifiable {
        case low, medium, high
        var id: Self { self }

        var title: String {
            switch self {
            case .low: "Basse"
            case .medium: "Moyenne"
            case .high: "Haute"
            }
        }
    }

    var format: Format = .mp4
    var codec: Codec = .h264
    /// Hauteur cible (côté court) ; `nil` = résolution d'origine.
    var resolution: Int?
    /// Images par seconde ; `nil` = cadence d'origine.
    var frameRate: Int?
    var quality: Quality = .high
    var includeAudio = true
    var gifWidth: Int = 640
    var gifFrameRate: Int = 15

    /// Codec réellement utilisé pour le format courant.
    var effectiveCodec: Codec {
        format.codecs.contains(codec) ? codec : (format.codecs.first ?? .h264)
    }

    var isPassthrough: Bool { format.isVideo && effectiveCodec == .passthrough }

    // MARK: - Choix proposés

    static let resolutionChoices = [2160, 1440, 1080, 720, 540, 480]
    static let frameRateChoices = [60, 50, 30, 25, 24]
    static let gifWidthChoices = [320, 480, 640, 800, 1024, 1280]
    static let gifFrameRateChoices = [10, 15, 20, 25]

    // MARK: - Calculs dépendant de la source

    /// Taille de sortie (dimensions paires) pour une vidéo source donnée.
    func outputSize(for source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1280, height: 720) }
        var scale: CGFloat = 1
        switch format {
        case .gif:
            scale = min(1, CGFloat(gifWidth) / source.width)
        case .mp4, .mov:
            if let resolution {
                scale = min(1, CGFloat(resolution) / min(source.width, source.height))
            }
            if effectiveCodec == .h264 {
                // Limites de l'encodeur H.264 (niveau 5.2) : 4096 px de côté, ~9,4 Mpx.
                let maxSide: CGFloat = 4096
                let maxPixels: CGFloat = 4096 * 2304
                scale = min(scale, maxSide / max(source.width, source.height))
                scale = min(scale, sqrt(maxPixels / (source.width * source.height)))
            }
        case .m4a:
            break
        }
        let even: (CGFloat) -> CGFloat = { max(2, (($0 * scale) / 2).rounded() * 2) }
        if format == .gif {
            return CGSize(width: max(1, (source.width * scale).rounded()),
                          height: max(1, (source.height * scale).rounded()))
        }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    func outputFrameRate(for sourceRate: Double) -> Double {
        switch format {
        case .gif: return Double(gifFrameRate)
        default:
            guard let frameRate else { return sourceRate }
            return min(Double(frameRate), sourceRate)
        }
    }

    /// Débit vidéo cible en bits/s pour H.264 / HEVC.
    func videoBitRate(size: CGSize, fps: Double) -> Int {
        let bitsPerPixel: Double
        switch (effectiveCodec, quality) {
        case (.hevc, .high): bitsPerPixel = 0.075
        case (.hevc, .medium): bitsPerPixel = 0.045
        case (.hevc, .low): bitsPerPixel = 0.025
        case (_, .high): bitsPerPixel = 0.12
        case (_, .medium): bitsPerPixel = 0.07
        case (_, .low): bitsPerPixel = 0.04
        }
        // Au-delà de 30 i/s, les images supplémentaires coûtent moins cher (forte redondance).
        let effectiveFPS = min(fps, 30) + max(0, fps - 30) * 0.5
        let rate = Double(size.width * size.height) * effectiveFPS * bitsPerPixel
        return Int(min(max(rate, 400_000), 80_000_000))
    }

    static let audioBitRate = 192_000

    /// Estimation de la taille du fichier exporté (octets). Pour un réencodage c'est un plafond :
    /// un écran peu animé se compresse bien mieux que le débit visé.
    /// `sourceSize` : taille de l'image à exporter (zone recadrée le cas échéant).
    func estimatedFileSize(media: MediaInfo, sourceSize: CGSize, duration: Double) -> Int64? {
        guard duration > 0 else { return nil }
        let audio = (includeAudio && media.hasAudio) ? Double(Self.audioBitRate) : 0
        switch format {
        case .m4a:
            return media.hasAudio ? Int64(Double(Self.audioBitRate) * duration / 8) : nil
        case .gif:
            // La taille d'un GIF dépend trop du contenu pour être estimée utilement.
            return nil
        case .mp4, .mov:
            let size = outputSize(for: sourceSize)
            let fps = outputFrameRate(for: media.maxFrameRate)
            let videoBits: Double
            switch effectiveCodec {
            case .passthrough:
                videoBits = media.videoDataRate
                let sourceAudio = includeAudio ? media.audioDataRate : 0
                return Int64((videoBits + sourceAudio) * duration / 8)
            case .proRes:
                videoBits = Double(size.width * size.height) * fps * 2.4
            case .h264, .hevc:
                videoBits = Double(videoBitRate(size: size, fps: fps))
            }
            return Int64((videoBits + audio) * duration / 8)
        }
    }

    // MARK: - Réglages AVFoundation

    func videoOutputSettings(size: CGSize, fps: Double) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        switch effectiveCodec {
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitRate(size: size, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitRate(size: size, fps: fps),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ] as [String: Any]
        case .proRes, .passthrough:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        }
        return settings
    }

    static var audioOutputSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitRate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    static var pcmReadSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    // MARK: - Persistance

    private static let defaultsKey = "ExportSettings"

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(ExportSettings.self, from: data)
        else { return ExportSettings() }
        // Couper le son est un choix ponctuel : on ne le reporte pas sur les vidéos suivantes.
        settings.includeAudio = true
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
