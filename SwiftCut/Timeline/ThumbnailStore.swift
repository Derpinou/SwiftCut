import AVFoundation
import CoreGraphics

/// Cache des vignettes de la timeline, générées à la demande selon le niveau de zoom.
@MainActor
final class ThumbnailStore {
    private struct Entry {
        let time: Double
        let image: CGImage
        let isBase: Bool
    }

    private struct Request {
        let time: Double
        let tolerance: Double
        let isBase: Bool
    }

    /// Appelé quand de nouvelles vignettes sont disponibles.
    var onUpdate: (() -> Void)?

    private var generator: AVAssetImageGenerator?
    private var entries: [Entry] = []          // triées par temps
    private var pending: [Request] = []
    private var worker: Task<Void, Never>?
    private var generation = 0

    private static let maxEntries = 1_500
    private static let maxPending = 48

    func reset(asset: AVAsset?, sourceRange: TimeRange, aspectRatio: CGFloat) {
        generation += 1
        worker?.cancel()
        worker = nil
        generator?.cancelAllCGImageGeneration()
        entries.removeAll()
        pending.removeAll()

        guard let asset else {
            generator = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let height: CGFloat = 132
        generator.maximumSize = CGSize(width: min(height * max(aspectRatio, 0.25), 520), height: height)
        self.generator = generator

        // Première passe grossière sur toute la durée.
        let count = Int(min(max(sourceRange.duration / 2, 24), 120))
        let step = sourceRange.duration / Double(count)
        pending = (0..<count).map { index in
            Request(time: sourceRange.start + (Double(index) + 0.5) * step, tolerance: step / 2, isBase: true)
        }
        pumpQueue()
    }

    /// Vignette la plus proche du temps source demandé.
    func image(near time: Double) -> CGImage? {
        guard let index = nearestIndex(to: time) else { return nil }
        return entries[index].image
    }

    /// Demande des vignettes plus précises pour les temps visibles.
    func request(times: [Double], tolerance: Double) {
        guard generator != nil else { return }
        var added = false
        for time in times {
            if let index = nearestIndex(to: time), abs(entries[index].time - time) <= tolerance { continue }
            if pending.contains(where: { abs($0.time - time) <= tolerance }) { continue }
            pending.append(Request(time: time, tolerance: tolerance, isBase: false))
            added = true
        }
        if pending.count > Self.maxPending {
            // On garde les demandes de base puis les plus récentes.
            let base = pending.filter(\.isBase)
            let recent = pending.filter { !$0.isBase }.suffix(Self.maxPending)
            pending = base + recent
        }
        if added { pumpQueue() }
    }

    private func nearestIndex(to time: Double) -> Int? {
        guard !entries.isEmpty else { return nil }
        var low = 0, high = entries.count - 1
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(entries[low - 1].time - time) < abs(entries[low].time - time) {
            return low - 1
        }
        return low
    }

    private func insert(_ entry: Entry) {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].time < entry.time { low = mid + 1 } else { high = mid }
        }
        entries.insert(entry, at: low)
    }

    private func pumpQueue() {
        guard worker == nil, !pending.isEmpty, let generator else { return }
        // Les demandes de base passent en premier, puis les plus récentes (zone visible).
        let batch: [Request]
        if pending.first?.isBase == true {
            batch = Array(pending.prefix(12))
            pending.removeFirst(batch.count)
        } else {
            batch = Array(pending.suffix(6))
            pending.removeLast(batch.count)
        }
        let tolerance = batch.map(\.tolerance).min() ?? 0.1
        let toleranceTime = CMTime(seconds: min(max(tolerance, 0.02), 5), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = toleranceTime
        generator.requestedTimeToleranceAfter = toleranceTime
        let currentGeneration = generation

        worker = Task { [weak self] in
            let times = batch.map { CMTime(seconds: $0.time, preferredTimescale: 600) }
            var results: [(Int, CGImage)] = []
            for await result in generator.images(for: times) {
                if case .success(let requested, let image, _) = result,
                   let index = times.firstIndex(of: requested) {
                    results.append((index, image))
                }
            }
            guard let self, currentGeneration == self.generation else { return }
            self.worker = nil
            if self.entries.count + results.count > Self.maxEntries {
                self.entries.removeAll { !$0.isBase }
            }
            for (index, image) in results {
                // On range la vignette au temps demandé : l'écart reste dans la tolérance.
                self.insert(Entry(time: batch[index].time, image: image, isBase: batch[index].isBase))
            }
            if !results.isEmpty { self.onUpdate?() }
            self.pumpQueue()
        }
    }
}
