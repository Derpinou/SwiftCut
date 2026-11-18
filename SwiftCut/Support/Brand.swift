import AppKit
import SwiftUI

/// Couleur ambrée de SwiftCut (sélection, coupes, actions principales).
/// Fixe, contrairement à `Color.accentColor` qui suit la couleur d'accentuation choisie dans Réglages Système.
extension NSColor {
    static let brand = NSColor(srgbRed: 1, green: 0.69, blue: 0.18, alpha: 1)
}

extension Color {
    static let brand = Color(nsColor: .brand)
}
