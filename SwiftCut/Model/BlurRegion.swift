import CoreImage
import CoreMedia
import Foundation

/// Une zone floutée de la vidéo (mot de passe, e-mail, visage…).
struct BlurRegion: Identifiable, Equatable, Sendable {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case blur, pixelate

        var id: Self { self }

        var title: String {
            switch self {
            case .blur: "Flou"
            case .pixelate: "Pixels"
            }
        }
    }

    /// Plus petit côté d'une zone, en fraction de l'image.
    static let minimumSide = 0.01

    var id = UUID()
    /// Zone dans l'image entière (coordonnées normalisées, origine en haut à gauche).
    var rect: CropRect
    var style: Style = .blur
    /// Force de l'effet, de 0,2 à 1.
    var intensity: Double = 0.7
    /// Période d'affichage en temps de la vidéo source (`nil` = toute la vidéo).
    /// Exprimée dans la source pour rester attachée au contenu quand on coupe.
    var sourceRange: TimeRange?

    func isActive(atSource time: Double) -> Bool {
        guard let sourceRange else { return true }
        return time >= sourceRange.start - 1e-3 && time <= sourceRange.end + 1e-3
    }
}

/// Correspondance temps de la composition → temps de la source, pour une liste de segments.
struct SourceTimeMap: Sendable {
    private let compositionStarts: [Double]
    private let sourceStarts: [Double]

    init(segments: [Segment]) {
        var cursor = 0.0
        var compositionStarts: [Double] = [], sourceStarts: [Double] = []
        for segment in segments {
            compositionStarts.append(cursor)
            sourceStarts.append(segment.sourceStart)
            cursor += segment.duration
        }
        self.compositionStarts = compositionStarts
        self.sourceStarts = sourceStarts
    }

    func sourceTime(at time: Double) -> Double {
        guard !compositionStarts.isEmpty else { return time }
        var index = 0
        while index + 1 < compositionStarts.count, compositionStarts[index + 1] <= time + 1e-6 {
            index += 1
        }
        return sourceStarts[index] + max(0, time - compositionStarts[index])
    }
}

/// Rendu d'une image avec Core Image : flous, puis recadrage et mise à l'échelle.
/// Le même code sert à l'aperçu et à l'export, pour que le résultat soit identique.
struct FrameRenderer: Sendable {
    var blurs: [BlurRegion]
    var timeMap: SourceTimeMap
    /// Zone gardée (toute l'image pour l'aperçu, qui recadre de son côté).
    var crop: CropRect = .full

    func render(_ source: CIImage, compositionTime: CMTime, renderSize: CGSize) -> CIImage {
        let extent = source.extent
        var image = source
        if !blurs.isEmpty {
            let sourceTime = timeMap.sourceTime(at: compositionTime.seconds)
            let clamped = source.clampedToExtent()
            for blur in blurs where blur.isActive(atSource: sourceTime) {
                let area = coreImageRect(blur.rect, in: extent).integral.intersection(extent)
                guard !area.isEmpty else { continue }
                let effect: CIImage
                switch blur.style {
                case .blur:
                    effect = clamped.applyingGaussianBlur(sigma: blur.intensity * extent.height / 30)
                case .pixelate:
                    effect = clamped.applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: max(4, blur.intensity * extent.height / 25),
                        kCIInputCenterKey: CIVector(x: area.minX, y: area.minY),
                    ])
                }
                image = effect.cropped(to: area).composited(over: image)
            }
        }

        // Recadrage puis mise à la taille de rendu, origine ramenée en (0, 0).
        let area = coreImageRect(crop, in: extent)
        var output = image.cropped(to: area)
            .transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
        let scaleX = renderSize.width / area.width, scaleY = renderSize.height / area.height
        if abs(scaleX - 1) > 1e-3 || abs(scaleY - 1) > 1e-3 {
            output = output.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
        }
        return output.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// Rectangle normalisé (origine en haut à gauche) → coordonnées Core Image (origine en bas à gauche).
    private func coreImageRect(_ rect: CropRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + rect.x * extent.width,
               y: extent.minY + (1 - rect.maxY) * extent.height,
               width: rect.width * extent.width,
               height: rect.height * extent.height)
    }
}
