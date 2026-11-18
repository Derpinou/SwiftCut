import Accelerate
import AVFoundation

/// Enveloppe audio simplifiée (niveau crête par tranche de 5 ms), pour l'affichage dans la timeline.
struct Waveform: Sendable, Identifiable {
    let id = UUID()
    let start: Double
    let bucketDuration: Double
    /// Niveaux normalisés entre 0 et 1 (échelle logarithmique).
    let levels: [Float]

    /// Niveau maximal sur une plage de temps source.
    func level(from s0: Double, to s1: Double) -> Float {
        guard !levels.isEmpty else { return 0 }
        let first = Int(((s0 - start) / bucketDuration).rounded(.down))
        let last = Int(((s1 - start) / bucketDuration).rounded(.up))
        let lower = min(max(first, 0), levels.count - 1)
        let upper = min(max(last, lower + 1), levels.count)
        var peak: Float = 0
        for index in lower..<upper where levels[index] > peak {
            peak = levels[index]
        }
        return peak
    }

    static func load(media: MediaInfo) async throws -> Waveform? {
        guard media.hasAudio else { return nil }
        let asset = media.asset
        let tracks = media.audioTracks
        let range = media.sourceRange
        return try await Task.detached(priority: .utility) {
            try read(asset: asset, tracks: tracks, range: range)
        }.value
    }

    private static func read(asset: AVAsset, tracks: [AVAssetTrack], range: TimeRange) throws -> Waveform? {
        let sampleRate = 16_000.0
        let bucketDuration = 0.005
        let samplesPerBucket = Int(sampleRate * bucketDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                       end: CMTime(seconds: range.end, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CancellationError() }

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(range.duration / bucketDuration) + 1)
        var carry: [Float] = []
        var buffer: [Float] = []

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            buffer = carry
            let offset = buffer.count
            buffer.append(contentsOf: repeatElement(0, count: count))
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: base + offset * MemoryLayout<Float>.size)
            }
            let fullBuckets = buffer.count / samplesPerBucket
            buffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                for bucket in 0..<fullBuckets {
                    var peak: Float = 0
                    vDSP_maxmgv(base + bucket * samplesPerBucket, 1, &peak, vDSP_Length(samplesPerBucket))
                    peaks.append(peak)
                }
            }
            carry = Array(buffer[(fullBuckets * samplesPerBucket)...])
        }
        if reader.status == .failed { throw reader.error ?? CancellationError() }
        if !carry.isEmpty {
            var peak: Float = 0
            vDSP_maxmgv(carry, 1, &peak, vDSP_Length(carry.count))
            peaks.append(peak)
        }
        guard !peaks.isEmpty else { return nil }

        // Passage en décibels, puis normalisation sur 45 dB sous le niveau le plus fort.
        let maxPeak = max(peaks.max() ?? 0, 1e-5)
        let maxDB = 20 * log10(maxPeak)
        let floorDB = maxDB - 45
        let levels = peaks.map { peak -> Float in
            let db = 20 * log10(max(peak, 1e-6))
            return min(max((db - floorDB) / (maxDB - floorDB), 0), 1)
        }
        return Waveform(start: range.start, bucketDuration: bucketDuration, levels: levels)
    }
}
