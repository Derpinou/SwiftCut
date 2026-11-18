import AVFoundation
import SwiftUI

/// Affiche la vidéo du lecteur (sans contrôles : la timeline s'en charge).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var onClick: () -> Void

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.player = player
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.onClick = onClick
        if view.player !== player { view.player = player }
    }
}

final class PlayerLayerView: NSView {
    var onClick: (() -> Void)?

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer?.player }
        set { playerLayer?.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas pris en charge") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 { onClick?() }
    }
}
