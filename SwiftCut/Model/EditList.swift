import Foundation

/// Plage de temps en secondes (sur la timeline montée ou dans la source).
struct TimeRange: Equatable, Hashable, Codable {
    var start: Double
    var end: Double

    init(_ a: Double, _ b: Double) {
        start = min(a, b)
        end = max(a, b)
    }

    var duration: Double { end - start }

    func contains(_ t: Double) -> Bool { t >= start && t <= end }

    func clamped(to bounds: TimeRange) -> TimeRange? {
        let s = max(start, bounds.start)
        let e = min(end, bounds.end)
        return e > s ? TimeRange(s, e) : nil
    }
}

/// Un morceau conservé de la vidéo source.
struct Segment: Identifiable, Equatable, Codable {
    var id = UUID()
    /// Début dans la vidéo source (secondes).
    var sourceStart: Double
    /// Fin dans la vidéo source (secondes).
    var sourceEnd: Double

    var duration: Double { sourceEnd - sourceStart }
    var sourceRange: TimeRange { TimeRange(sourceStart, sourceEnd) }
}

/// Liste de montage non destructive : la vidéo exportée est la concaténation des segments, dans l'ordre.
/// Tous les temps « timeline » sont exprimés sur la vidéo montée (après suppression des coupes).
struct EditList: Equatable {
    /// En dessous de cette durée, un morceau restant est considéré comme négligeable et supprimé.
    static let minimumSegmentDuration = 1.0 / 120.0

    private(set) var segments: [Segment]

    init(segments: [Segment] = []) {
        self.segments = segments
    }

    init(sourceRange: TimeRange) {
        segments = [Segment(sourceStart: sourceRange.start, sourceEnd: sourceRange.end)]
    }

    var isEmpty: Bool { segments.isEmpty }

    /// Durée totale de la vidéo montée.
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    /// Début de chaque segment sur la timeline montée.
    var segmentStarts: [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(segments.count)
        var cursor = 0.0
        for segment in segments {
            starts.append(cursor)
            cursor += segment.duration
        }
        return starts
    }

    /// Segments accompagnés de leur plage sur la timeline montée.
    var placedSegments: [(segment: Segment, range: TimeRange)] {
        var result: [(Segment, TimeRange)] = []
        result.reserveCapacity(segments.count)
        var cursor = 0.0
        for segment in segments {
            result.append((segment, TimeRange(cursor, cursor + segment.duration)))
            cursor += segment.duration
        }
        return result
    }

    /// Positions des coupes (frontières entre segments) sur la timeline montée.
    var cutPoints: [Double] {
        Array(segmentStarts.dropFirst())
    }

    /// Plages source conservées, en fusionnant les segments contigus.
    /// Sert à savoir si le contenu a réellement changé (une simple scission ne change rien).
    var keptSourceRanges: [TimeRange] {
        var merged: [TimeRange] = []
        for segment in segments {
            if let last = merged.last, abs(last.end - segment.sourceStart) < 1e-6 {
                merged[merged.count - 1].end = segment.sourceEnd
            } else {
                merged.append(segment.sourceRange)
            }
        }
        return merged
    }

    func hasSameContent(as other: EditList) -> Bool {
        let a = keptSourceRanges, b = other.keptSourceRanges
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.start - $1.start) < 1e-6 && abs($0.end - $1.end) < 1e-6 }
    }

    // MARK: - Recherche

    /// Index du segment qui contient le temps `t` de la timeline (le suivant en cas d'égalité sur une coupe).
    func segmentIndex(at t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var cursor = 0.0
        for (index, segment) in segments.enumerated() {
            let end = cursor + segment.duration
            if t < end { return index }
            cursor = end
        }
        return segments.count - 1
    }

    func segment(at t: Double) -> Segment? {
        segmentIndex(at: t).map { segments[$0] }
    }

    func range(ofSegment id: Segment.ID) -> TimeRange? {
        placedSegments.first { $0.segment.id == id }?.range
    }

    /// Temps dans la source correspondant au temps `t` de la timeline.
    func sourceTime(at t: Double) -> Double? {
        guard let index = segmentIndex(at: t) else { return nil }
        let segment = segments[index]
        return min(segment.sourceEnd, segment.sourceStart + max(0, t - segmentStarts[index]))
    }

    /// Temps sur la timeline correspondant à un temps de la source, s'il est conservé.
    func timelineTime(forSource s: Double) -> Double? {
        var cursor = 0.0
        for segment in segments {
            if s >= segment.sourceStart - 1e-9 && s <= segment.sourceEnd + 1e-9 {
                return cursor + (s - segment.sourceStart)
            }
            cursor += segment.duration
        }
        return nil
    }

    // MARK: - Opérations de montage

    /// Scinde le segment situé sous `t`. Renvoie `false` si `t` est trop près d'une coupe existante.
    @discardableResult
    mutating func split(at t: Double) -> Bool {
        guard let index = segmentIndex(at: t) else { return false }
        let start = segmentStarts[index]
        let offset = t - start
        let segment = segments[index]
        guard offset >= Self.minimumSegmentDuration,
              segment.duration - offset >= Self.minimumSegmentDuration else { return false }
        let cut = segment.sourceStart + offset
        var left = segment
        left.sourceEnd = cut
        let right = Segment(sourceStart: cut, sourceEnd: segment.sourceEnd)
        segments.replaceSubrange(index...index, with: [left, right])
        return true
    }

    /// Ne garde que la plage `range` de la timeline (rognage).
    func trimmed(to range: TimeRange) -> EditList {
        var copy = self
        let end = duration
        if range.end < end { copy.remove(TimeRange(range.end, end)) }
        if range.start > 0 { copy.remove(TimeRange(0, range.start)) }
        return copy
    }

    /// Supprime une plage de la timeline (montage « ripple » : la suite se recolle).
    mutating func remove(_ range: TimeRange) {
        guard range.duration > 0 else { return }
        var result: [Segment] = []
        var cursor = 0.0
        for segment in segments {
            let segStart = cursor
            let segEnd = cursor + segment.duration
            cursor = segEnd

            // Pas de chevauchement : on garde tel quel.
            if segEnd <= range.start || segStart >= range.end {
                result.append(segment)
                continue
            }
            // Partie gauche conservée.
            if range.start > segStart {
                var left = segment
                left.sourceEnd = segment.sourceStart + (range.start - segStart)
                if left.duration >= Self.minimumSegmentDuration { result.append(left) }
            }
            // Partie droite conservée.
            if range.end < segEnd {
                let rightStart = segment.sourceStart + (range.end - segStart)
                // Si rien n'a été gardé à gauche, la partie droite garde l'identité du segment.
                let keepsIdentity = range.start <= segStart
                var right = keepsIdentity ? segment : Segment(sourceStart: rightStart, sourceEnd: segment.sourceEnd)
                right.sourceStart = rightStart
                if right.duration >= Self.minimumSegmentDuration { result.append(right) }
            }
        }
        segments = result
    }
}
