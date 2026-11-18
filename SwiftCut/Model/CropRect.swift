import CoreGraphics

/// Zone gardée de l'image, en coordonnées normalisées (0…1, origine en haut à gauche).
struct CropRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
    /// Plus petit côté autorisé, en fraction de l'image.
    static let minimumSide = 0.05

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var isFull: Bool {
        abs(x) < 1e-4 && abs(y) < 1e-4 && abs(width - 1) < 1e-4 && abs(height - 1) < 1e-4
    }

    /// Zone en pixels (entiers) pour une image de taille `size`.
    func pixelRect(in size: CGSize) -> CGRect {
        let minX = (x * size.width).rounded(), minY = (y * size.height).rounded()
        let maxX = min((self.maxX * size.width).rounded(), size.width)
        let maxY = min((self.maxY * size.height).rounded(), size.height)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// Ce que l'on fait glisser : un coin, un bord, ou tout le cadre.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    /// Le cadre après avoir fait glisser `handle` de `delta` (en fraction de l'image).
    /// `ratio` : proportion largeur / hauteur imposée, exprimée en coordonnées normalisées.
    /// `minimumSide` : plus petit côté autorisé (les zones de flou peuvent être plus petites qu'un recadrage).
    func dragging(_ handle: Handle, by delta: CGSize, ratio: Double?, minimumSide side: Double = minimumSide) -> CropRect {
        if handle == .move {
            return CropRect(x: min(max(x + delta.width, 0), 1 - width),
                            y: min(max(y + delta.height, 0), 1 - height),
                            width: width, height: height)
        }
        var minX = x, minY = y, maxX = self.maxX, maxY = self.maxY
        if handle.movesLeft { minX = min(max(x + delta.width, 0), maxX - side) }
        if handle.movesRight { maxX = max(min(self.maxX + delta.width, 1), minX + side) }
        if handle.movesTop { minY = min(max(y + delta.height, 0), maxY - side) }
        if handle.movesBottom { maxY = max(min(self.maxY + delta.height, 1), minY + side) }
        let free = CropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio else { return free }
        return constrained(free, to: ratio, handle: handle)
    }

    /// Ramène `proposed` à la proportion `ratio` en gardant fixe le côté (ou coin) opposé à la poignée.
    private func constrained(_ proposed: CropRect, to ratio: Double, handle: Handle) -> CropRect {
        var width = proposed.width, height = proposed.height
        if handle.isCorner {
            // On suit l'axe sur lequel le pointeur a le plus bougé.
            if abs(width - self.width) >= abs(height - self.height) * ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let availableWidth = handle.movesLeft ? self.maxX : 1 - x
            let availableHeight = handle.movesTop ? self.maxY : 1 - y
            if width > availableWidth { width = availableWidth; height = width / ratio }
            if height > availableHeight { height = availableHeight; width = height * ratio }
            if width < Self.minimumSide || height < Self.minimumSide {
                let scale = max(Self.minimumSide / width, Self.minimumSide / height)
                width *= scale
                height *= scale
            }
            return CropRect(x: handle.movesLeft ? self.maxX - width : x,
                            y: handle.movesTop ? self.maxY - height : y,
                            width: width, height: height)
        }
        if handle.movesLeft || handle.movesRight {
            height = max(width / ratio, Self.minimumSide)
            if height > 1 { height = 1 }
            width = height * ratio
            let centerY = y + self.height / 2
            return CropRect(x: handle.movesLeft ? self.maxX - width : x,
                            y: min(max(centerY - height / 2, 0), 1 - height),
                            width: width, height: height)
        }
        width = max(height * ratio, Self.minimumSide)
        if width > 1 { width = 1 }
        height = width / ratio
        let centerX = x + self.width / 2
        return CropRect(x: min(max(centerX - width / 2, 0), 1 - width),
                        y: handle.movesTop ? self.maxY - height : y,
                        width: width, height: height)
    }

    /// Le plus grand cadre de proportion `ratio` (normalisée) centré au plus près de `center`.
    static func largest(ratio: Double, centeredOn center: CGPoint) -> CropRect {
        var width = 1.0, height = 1.0 / ratio
        if height > 1 {
            height = 1
            width = ratio
        }
        return CropRect(x: min(max(center.x - width / 2, 0), 1 - width),
                        y: min(max(center.y - height / 2, 0), 1 - height),
                        width: width, height: height)
    }
}

/// Formats proposés pour le recadrage, comme sur iPhone.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, wide, tall, classic, classicPortrait, portrait

    var id: Self { self }

    var title: String {
        switch self {
        case .free: "Libre"
        case .original: "Original"
        case .square: "Carré"
        case .wide: "16:9"
        case .tall: "9:16"
        case .classic: "4:3"
        case .classicPortrait: "3:4"
        case .portrait: "4:5"
        }
    }

    /// Proportion largeur / hauteur en pixels (`nil` = libre).
    func pixelRatio(for size: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: size.height > 0 ? size.width / size.height : nil
        case .square: 1
        case .wide: 16.0 / 9
        case .tall: 9.0 / 16
        case .classic: 4.0 / 3
        case .classicPortrait: 3.0 / 4
        case .portrait: 4.0 / 5
        }
    }
}
