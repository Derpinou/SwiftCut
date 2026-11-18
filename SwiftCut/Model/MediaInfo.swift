import AVFoundation
import CoreMedia

enum MediaError: LocalizedError {
    case notPlayable
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .notPlayable: "Ce fichier n'est pas une vidéo lisible par macOS (formats pris en charge : MOV, MP4, M4V…)."
        case .noVideoTrack: "Ce fichier ne contient aucune piste vidéo."
        }
    }
}

/// Informations sur la vidéo source, chargées une fois à l'ouverture.
struct MediaInfo {
    let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTracks: [AVAssetTrack]
    /// Plage temporelle de chaque piste audio (même ordre que `audioTracks`).
    let audioTimeRanges: [CMTimeRange]

    /// Plage utile de la source (celle de la piste vidéo).
    let sourceRange: TimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    /// Taille d'affichage (après rotation éventuelle).
    let displaySize: CGSize
    /// Cadence nominale (moyenne) de la piste vidéo.
    let frameRate: Double
    /// Cadence maximale (les enregistrements d'écran sont à cadence variable).
    let maxFrameRate: Double
    let videoCodecName: String
    let videoCodecType: FourCharCode
    let audioCodecName: String?
    let videoDataRate: Double
    let audioDataRate: Double
    let fileSize: Int64?

    var hasAudio: Bool { !audioTracks.isEmpty }
    var duration: Double { sourceRange.duration }
    var aspectRatio: CGFloat {
        guard displaySize.height > 0 else { return 16.0 / 9.0 }
        return displaySize.width / displaySize.height
    }

    /// Le flux vidéo peut-il être copié tel quel dans un conteneur MP4 ?
    var isVideoMP4Compatible: Bool {
        [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_MPEG4Video,
         FourCharCode(fourCC: "hev1")].contains(videoCodecType)
    }

    static func load(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let isPlayable: Bool, assetDuration: CMTime
        do {
            (isPlayable, assetDuration) = try await asset.load(.isPlayable, .duration)
        } catch let error as AVError where [.fileFormatNotRecognized, .failedToParse, .decoderNotFound].contains(error.code) {
            throw MediaError.notPlayable
        }
        guard isPlayable else { throw MediaError.notPlayable }

        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)

        let (naturalSize, transform, nominalFrameRate, timeRange) =
            try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        let (formats, videoRate, minFrameDuration) =
            try await video.load(.formatDescriptions, .estimatedDataRate, .minFrameDuration)

        var audioCodec: String?
        var audioRate = 0.0
        var audioRanges: [CMTimeRange] = []
        for track in audio {
            let (audioFormats, rate, audioRange) = try await track.load(.formatDescriptions, .estimatedDataRate, .timeRange)
            audioRate += Double(rate)
            audioRanges.append(audioRange)
            if audioCodec == nil, let format = audioFormats.first {
                audioCodec = Self.audioCodecName(CMFormatDescriptionGetMediaSubType(format))
            }
        }

        let codecType = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displaySize = CGSize(width: abs(oriented.width).rounded(), height: abs(oriented.height).rounded())

        var range = TimeRange(timeRange.start.seconds, timeRange.end.seconds)
        if !range.start.isFinite || !range.end.isFinite || range.duration <= 0 {
            range = TimeRange(0, assetDuration.seconds)
        }

        let nominal = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        return MediaInfo(
            url: url,
            asset: asset,
            videoTrack: video,
            audioTracks: audio,
            audioTimeRanges: audioRanges,
            sourceRange: range,
            naturalSize: naturalSize,
            preferredTransform: transform,
            displaySize: displaySize,
            frameRate: nominal,
            maxFrameRate: Self.maximumFrameRate(nominal: nominal, minFrameDuration: minFrameDuration),
            videoCodecName: Self.videoCodecName(codecType),
            videoCodecType: codecType,
            audioCodecName: audioCodec,
            videoDataRate: Double(videoRate),
            audioDataRate: audioRate,
            fileSize: fileSize
        )
    }

    private static func maximumFrameRate(nominal: Double, minFrameDuration: CMTime) -> Double {
        var rate = nominal
        if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            rate = min(max(1 / minFrameDuration.seconds, nominal), max(60, nominal))
        }
        return standardFrameRate(rate)
    }

    /// Ramène une cadence mesurée à la valeur standard la plus proche (29,97, 30, 60…).
    static func standardFrameRate(_ rate: Double) -> Double {
        let standards = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48, 50, 60000.0 / 1001, 60, 90, 100, 120]
        if let closest = standards.min(by: { abs($0 - rate) < abs($1 - rate) }),
           abs(closest - rate) / rate < 0.02 {
            return closest
        }
        return max(1, rate.rounded())
    }

    private static func videoCodecName(_ type: FourCharCode) -> String {
        switch type {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, FourCharCode(fourCC: "hev1"): "HEVC"
        case kCMVideoCodecType_HEVCWithAlpha: "HEVC (alpha)"
        case kCMVideoCodecType_AppleProRes422: "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444: "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ"
        case kCMVideoCodecType_MPEG4Video: "MPEG-4"
        case kCMVideoCodecType_JPEG: "Motion JPEG"
        default: type.fourCCString
        }
    }

    private static func audioCodecName(_ type: FourCharCode) -> String {
        switch type {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "AAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        case kAudioFormatOpus: "Opus"
        default: type.fourCCString
        }
    }
}

extension FourCharCode {
    init(fourCC string: String) {
        self = string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
