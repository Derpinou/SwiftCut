import Foundation

enum Fmt {
    /// « 1:23.45 » ou « 1:02:03.45 ».
    static func time(_ seconds: Double, fraction: Bool = true) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, seconds)
        let hundredths = Int((total * 100).rounded(.down))
        let h = hundredths / 360_000
        let m = (hundredths / 6_000) % 60
        let s = (hundredths / 100) % 60
        let cs = hundredths % 100
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if fraction { text += String(format: ".%02d", cs) }
        return text
    }

    /// Libellé de règle : « 0:05 », « 1:30 » ou « 0:05.5 » selon le pas.
    static func rulerTime(_ seconds: Double, step: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) / 60) % 60
        let s = Int(total) % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if step < 1 {
            let decimals = step < 0.1 ? 2 : 1
            let fraction = total - floor(total)
            let digits = decimals == 2 ? Int((fraction * 100).rounded()) % 100 : Int((fraction * 10).rounded()) % 10
            text += decimals == 2 ? String(format: ".%02d", digits) : ".\(digits)"
        }
        return text
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(1, seconds.rounded())) ?? "\(Int(seconds)) s"
    }

    static func frameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) i/s" : String(format: "%.2f i/s", rounded)
    }
}
