import AVFoundation

/// Construit une composition AVFoundation à partir de la liste des segments conservés.
/// Utilisée à la fois pour l'aperçu (lecteur) et pour l'export.
enum CompositionBuilder {
    /// Échelle de temps commune : compatible 24, 25, 30, 60 et 29,97 i/s.
    static let timescale: CMTimeScale = 60_000

    struct Result {
        let composition: AVMutableComposition
        let videoTrack: AVMutableCompositionTrack?
        let audioTracks: [AVMutableCompositionTrack]
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    static func make(media: MediaInfo,
                     segments: [Segment],
                     includeVideo: Bool = true,
                     includeAudio: Bool = true) throws -> Result {
        let composition = AVMutableComposition()

        var videoTrack: AVMutableCompositionTrack?
        if includeVideo {
            videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
            videoTrack?.preferredTransform = media.preferredTransform
        }

        var audioPairs: [(source: AVAssetTrack, target: AVMutableCompositionTrack, range: CMTimeRange)] = []
        if includeAudio {
            for (source, range) in zip(media.audioTracks, media.audioTimeRanges) {
                guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                audioPairs.append((source, target, range))
            }
        }

        var cursor = CMTime.zero
        for segment in segments where segment.duration > 0 {
            let range = CMTimeRange(start: time(segment.sourceStart), end: time(segment.sourceEnd))
            if let videoTrack {
                try videoTrack.insertTimeRange(range, of: media.videoTrack, at: cursor)
            }
            for pair in audioPairs {
                // La piste audio peut être plus courte (ou décalée) que la vidéo.
                let overlap = range.intersection(pair.range)
                guard overlap.duration > .zero else { continue }
                let offset = overlap.start - range.start
                try pair.target.insertTimeRange(overlap, of: pair.source, at: cursor + offset)
            }
            cursor = cursor + range.duration
        }

        // Une piste audio restée vide gênerait certains exports : on la retire.
        let audioTracks = audioPairs.map(\.target).filter { track in
            if track.segments.isEmpty {
                composition.removeTrack(track)
                return false
            }
            return true
        }

        return Result(composition: composition, videoTrack: videoTrack, audioTracks: audioTracks)
    }
}
