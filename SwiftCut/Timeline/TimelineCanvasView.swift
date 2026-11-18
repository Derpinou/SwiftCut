import AppKit
import QuartzCore

/// Ce que la timeline affiche (fourni par SwiftUI à chaque mise à jour).
struct TimelineContent: Equatable {
    var mode: EditMode = .cut
    var edits = EditList()
    var trimRange = TimeRange(0, 0)
    var selection: TimeRange?
    var selectedSegmentID: Segment.ID?
    var aspectRatio: CGFloat = 16.0 / 9.0
    var hasAudio = false

    var isTrimmed: Bool { trimRange.start > 0.0005 || trimRange.end < edits.duration - 0.0005 }
}

/// Timeline : règle, vignettes, tête de lecture, et selon le mode
/// - Rogner : pellicule encadrée par deux poignées, comme sur iPhone ;
/// - Découper : segments, forme d'onde, coupes et sélection.
/// Dessinée à la main pour rester fluide quel que soit le niveau de zoom.
final class TimelineCanvasView: NSView {
    // MARK: Actions remontées au modèle

    var onSeek: ((Double) -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var onSelectionChange: ((TimeRange?) -> Void)?
    var onClick: ((Double) -> Void)?
    var onZoomLevelChange: ((Double) -> Void)?
    var onSplit: ((Double) -> Void)?
    var onDeleteSegment: ((Double) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onTrimBegan: (() -> Void)?
    var onTrimChanged: ((TimeRange, Double) -> Void)?
    var onTrimEnded: (() -> Void)?
    var onSetTrimStart: ((Double) -> Void)?
    var onSetTrimEnd: ((Double) -> Void)?
    var onResetTrim: (() -> Void)?

    // MARK: Données

    var thumbnails: ThumbnailStore? {
        didSet { thumbnails?.onUpdate = { [weak self] in self?.needsDisplay = true } }
    }
    private(set) var content = TimelineContent()
    private var waveform: Waveform?
    private var playhead: Double = 0
    private var isPlaying = false

    // MARK: Vue (zoom et défilement)

    private var zoomLevel: Double = 0
    private var scrollOffset: CGFloat = 0

    // MARK: Géométrie

    static let rulerHeight: CGFloat = 22
    static let trackTop: CGFloat = 28
    static let thumbHeight: CGFloat = 56
    static let waveHeight: CGFloat = 30
    static let stripHeight: CGFloat = 60
    static let handleWidth: CGFloat = 13
    static let scrollerHeight: CGFloat = 5
    static let maxPixelsPerSecond: Double = 600
    static let minimumTrim: Double = 0.1
    private let inset: CGFloat = 14

    static func preferredHeight(hasAudio: Bool, mode: EditMode) -> CGFloat {
        switch mode {
        case .trim: trackTop + stripHeight + 22
        case .cut: trackTop + thumbHeight + (hasAudio ? waveHeight : 0) + 18
        }
    }

    private var isTrimMode: Bool { content.mode == .trim }
    private var trackHeight: CGFloat {
        isTrimMode ? Self.stripHeight : Self.thumbHeight + (content.hasAudio ? Self.waveHeight : 0)
    }
    private var trackBottom: CGFloat { Self.trackTop + trackHeight }
    private var usableWidth: CGFloat { max(1, bounds.width - inset * 2) }
    private var duration: Double { max(content.edits.duration, 0.001) }
    private var maxZoom: Double { max(1, Self.maxPixelsPerSecond * duration / Double(usableWidth)) }
    private var zoomFactor: Double { pow(maxZoom, zoomLevel) }
    private var contentWidth: CGFloat { usableWidth * CGFloat(zoomFactor) }
    private var pixelsPerSecond: CGFloat { contentWidth / CGFloat(duration) }
    private var maxScroll: CGFloat { max(0, contentWidth - usableWidth) }

    private func x(for time: Double) -> CGFloat {
        inset + CGFloat(time) * pixelsPerSecond - scrollOffset
    }

    private func unclampedTime(at x: CGFloat) -> Double {
        Double((x - inset + scrollOffset) / pixelsPerSecond)
    }

    private func time(at x: CGFloat) -> Double {
        min(max(unclampedTime(at: x), 0), content.edits.duration)
    }

    // MARK: Couleurs

    private enum Palette {
        static let background = NSColor(white: 0.105, alpha: 1)
        static let ruler = NSColor(white: 0.135, alpha: 1)
        static let rulerText = NSColor(white: 1, alpha: 0.55)
        static let tick = NSColor(white: 1, alpha: 0.22)
        static let segment = NSColor(white: 0.2, alpha: 1)
        static let segmentBorder = NSColor(white: 1, alpha: 0.14)
        static let waveBackground = NSColor(calibratedRed: 0.09, green: 0.2, blue: 0.16, alpha: 1)
        static let wave = NSColor(calibratedRed: 0.38, green: 0.84, blue: 0.64, alpha: 0.95)
        static let accent = NSColor.brand
        static let playhead = NSColor(calibratedRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    }

    // MARK: Calques superposés (évitent de tout redessiner pendant la lecture)

    private let playheadLayer = CALayer()
    private let playheadLine = CALayer()
    private let playheadHead = CAShapeLayer()
    private let hoverLine = CALayer()
    private let hoverLabel = CATextLayer()

    // MARK: Interaction

    private enum Drag {
        case none
        case scrub
        case pendingClick(start: CGPoint, time: Double)
        case select(anchor: Double)
        case trim(isStart: Bool, grab: CGFloat)
        case scroller(grab: CGFloat)
    }

    private var drag: Drag = .none
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var autoscrollTimer: Timer?
    private var lastDragPoint: CGPoint = .zero

    private var isInteracting: Bool {
        if case .none = drag { return false }
        return true
    }

    private var isDraggingTrim: Bool {
        if case .trim = drag { return true }
        return false
    }

    // MARK: - Initialisation

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Depuis macOS 14, une vue peut dessiner hors de ses limites : on l'interdit.
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas pris en charge") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupLayers() {
        let noAnimation: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
                                               "frame": NSNull(), "contents": NSNull(), "path": NSNull()]
        playheadLine.backgroundColor = Palette.playhead.cgColor
        playheadLine.actions = noAnimation
        playheadHead.fillColor = Palette.playhead.cgColor
        playheadHead.actions = noAnimation
        playheadLayer.actions = noAnimation
        playheadLayer.addSublayer(playheadLine)
        playheadLayer.addSublayer(playheadHead)
        playheadLayer.shadowColor = NSColor.black.cgColor
        playheadLayer.shadowOpacity = 0.5
        playheadLayer.shadowRadius = 2
        playheadLayer.shadowOffset = .zero

        hoverLine.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
        hoverLine.actions = noAnimation
        hoverLine.isHidden = true

        hoverLabel.actions = noAnimation
        hoverLabel.isHidden = true
        hoverLabel.fontSize = 10
        hoverLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        hoverLabel.foregroundColor = NSColor.black.cgColor
        hoverLabel.backgroundColor = NSColor(white: 0.92, alpha: 1).cgColor
        hoverLabel.cornerRadius = 4
        hoverLabel.alignmentMode = .center

        layer?.addSublayer(hoverLine)
        layer?.addSublayer(hoverLabel)
        layer?.addSublayer(playheadLayer)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [playheadLayer, playheadLine, playheadHead, hoverLine, hoverLabel] {
            sublayer.contentsScale = scale
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scrollOffset = clampScroll(scrollOffset)
        updateOverlayLayers()
    }

    // MARK: - Mises à jour depuis SwiftUI

    func update(content newContent: TimelineContent) {
        guard newContent != content else { return }
        content = newContent
        scrollOffset = clampScroll(scrollOffset)
        needsDisplay = true
        updateOverlayLayers()
    }

    func update(waveform newWaveform: Waveform?) {
        guard newWaveform?.id != waveform?.id else { return }
        waveform = newWaveform
        needsDisplay = true
    }

    func update(zoomLevel newLevel: Double) {
        guard abs(newLevel - zoomLevel) > 1e-9 else { return }
        setZoomLevel(newLevel, anchorX: nil)
    }

    func update(playhead newPlayhead: Double, isPlaying playing: Bool) {
        let moved = abs(newPlayhead - playhead) > 1e-7
        playhead = newPlayhead
        isPlaying = playing
        if moved, !isInteracting {
            revealPlayhead()
        }
        updateOverlayLayers()
    }

    // MARK: - Zoom et défilement

    private func clampScroll(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), maxScroll)
    }

    private func setScrollOffset(_ value: CGFloat) {
        let clamped = clampScroll(value)
        guard abs(clamped - scrollOffset) > 0.01 else { return }
        scrollOffset = clamped
        needsDisplay = true
        updateOverlayLayers()
    }

    private func setZoomLevel(_ level: Double, anchorX: CGFloat?) {
        let newLevel = min(max(level, 0), 1)
        guard abs(newLevel - zoomLevel) > 1e-9 else { return }
        let anchor: CGFloat
        if let anchorX {
            anchor = anchorX
        } else {
            let playheadX = x(for: playhead)
            anchor = (playheadX >= inset && playheadX <= bounds.width - inset) ? playheadX : bounds.midX
        }
        let anchorTime = unclampedTime(at: anchor)
        zoomLevel = newLevel
        scrollOffset = clampScroll(CGFloat(anchorTime) * pixelsPerSecond - (anchor - inset))
        needsDisplay = true
        updateOverlayLayers()
    }

    private func zoom(by factor: Double, anchorX: CGFloat) {
        guard maxZoom > 1.0001 else { return }
        let newFactor = min(max(zoomFactor * factor, 1), maxZoom)
        setZoomLevel(log(newFactor) / log(maxZoom), anchorX: anchorX)
        onZoomLevelChange?(zoomLevel)
    }

    /// Garde la tête de lecture visible : page par page en lecture, centrée sinon.
    private func revealPlayhead() {
        guard maxScroll > 0 else { return }
        let px = x(for: playhead)
        let left = inset, right = bounds.width - inset
        if isPlaying {
            if px > right || px < left {
                setScrollOffset(CGFloat(playhead) * pixelsPerSecond - usableWidth * 0.08)
            }
        } else if px < left || px > right {
            setScrollOffset(CGFloat(playhead) * pixelsPerSecond - usableWidth / 2)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            zoom(by: exp(Double(delta) * 0.01), anchorX: point.x)
            return
        }
        guard maxScroll > 0 else {
            super.scrollWheel(with: event)
            return
        }
        var delta = event.scrollingDeltaX
        if abs(event.scrollingDeltaY) > abs(delta) { delta = event.scrollingDeltaY }
        if !event.hasPreciseScrollingDeltas { delta *= 10 }
        setScrollOffset(scrollOffset - delta)
        updateHover()
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + Double(event.magnification) * 1.5, anchorX: point.x)
    }

    // MARK: - Souris

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                            .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func isInTrack(_ point: CGPoint) -> Bool {
        point.y >= Self.trackTop - 4 && point.y <= trackBottom + 4
    }

    private func isInScroller(_ point: CGPoint) -> Bool {
        maxScroll > 0 && point.y > trackBottom + 4
    }

    /// Poignée de rognage sous le pointeur : `true` = début, `false` = fin.
    private func trimHandle(at point: CGPoint) -> Bool? {
        guard isTrimMode, !content.edits.isEmpty,
              point.y >= Self.trackTop - 8, point.y <= trackBottom + 8 else { return nil }
        let inX = x(for: content.trimRange.start), outX = x(for: content.trimRange.end)
        let onStart = point.x >= inX - Self.handleWidth - 4 && point.x <= inX + 6
        let onEnd = point.x >= outX - 6 && point.x <= outX + Self.handleWidth + 4
        if onStart && onEnd { return point.x < (inX + outX) / 2 }
        if onStart { return true }
        if onEnd { return false }
        return nil
    }

    /// Bord de sélection sous le pointeur, renvoie le bord opposé (point d'ancrage).
    private func selectionAnchor(forEdgeNear point: CGPoint) -> Double? {
        guard let selection = content.selection, isInTrack(point) || point.y < Self.trackTop else { return nil }
        let startX = x(for: selection.start), endX = x(for: selection.end)
        if abs(point.x - endX) <= 6 { return selection.start }
        if abs(point.x - startX) <= 6 { return selection.end }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        lastDragPoint = point

        if isInScroller(point) {
            let knob = scrollerKnobRect()
            if knob.contains(point) {
                drag = .scroller(grab: point.x - knob.minX)
            } else {
                drag = .scroller(grab: knob.width / 2)
                moveScroller(to: point.x)
            }
            return
        }

        if isTrimMode {
            if let isStart = trimHandle(at: point) {
                let edge = isStart ? content.trimRange.start : content.trimRange.end
                drag = .trim(isStart: isStart, grab: point.x - x(for: edge))
                onTrimBegan?()
                needsDisplay = true
            } else {
                drag = .scrub
                onScrubBegan?()
                onSeek?(time(at: point.x))
            }
            return
        }

        if event.clickCount == 2, isInTrack(point),
           let placed = content.edits.placedSegments.first(where: { $0.range.contains(time(at: point.x)) }) {
            drag = .none
            onSelectionChange?(placed.range)
            return
        }

        if point.y < Self.trackTop - 4, selectionAnchor(forEdgeNear: point) == nil {
            drag = .scrub
            onScrubBegan?()
            onSeek?(time(at: point.x))
            return
        }

        if let anchor = selectionAnchor(forEdgeNear: point) {
            drag = .select(anchor: anchor)
            onScrubBegan?()
            return
        }

        if event.modifierFlags.contains(.shift) {
            let t = time(at: point.x)
            var anchor = playhead
            if let selection = content.selection {
                anchor = abs(t - selection.start) < abs(t - selection.end) ? selection.end : selection.start
            }
            drag = .select(anchor: anchor)
            onScrubBegan?()
            updateSelection(to: t)
            return
        }

        drag = .pendingClick(start: point, time: time(at: point.x))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        lastDragPoint = point
        handleDrag(at: point)
        updateAutoscroll()
    }

    private func handleDrag(at point: CGPoint) {
        switch drag {
        case .none:
            break
        case .scrub:
            onSeek?(time(at: point.x))
        case .pendingClick(let start, let startTime):
            if abs(point.x - start.x) > 3 {
                drag = .select(anchor: startTime)
                onScrubBegan?()
                updateSelection(to: time(at: point.x))
            }
        case .select:
            updateSelection(to: snappedTime(at: point.x))
        case .trim(let isStart, let grab):
            updateTrim(isStart: isStart, to: snappedTime(at: point.x - grab))
        case .scroller:
            moveScroller(to: point.x)
        }
        hoverPoint = point
        updateOverlayLayers()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        switch drag {
        case .pendingClick(_, let t):
            onSeek?(t)
            onClick?(t)
        case .scrub:
            onScrubEnded?()
        case .select:
            if let selection = content.selection, CGFloat(selection.duration) * pixelsPerSecond < 2 {
                content.selection = nil
                onSelectionChange?(nil)
            }
            onScrubEnded?()
        case .trim:
            onTrimEnded?()
        case .none, .scroller:
            break
        }
        drag = .none
        needsDisplay = true
        updateOverlayLayers()
    }

    private func updateTrim(isStart: Bool, to t: Double) {
        var range = content.trimRange
        let total = content.edits.duration
        if isStart {
            range.start = min(max(t, 0), range.end - Self.minimumTrim)
        } else {
            range.end = max(min(t, total), range.start + Self.minimumTrim)
        }
        content.trimRange = range
        onTrimChanged?(range, isStart ? range.start : range.end)
        needsDisplay = true
    }

    private func updateSelection(to t: Double) {
        guard case .select(let anchor) = drag else { return }
        let range = TimeRange(anchor, t)
        content.selection = range.duration > 0 ? range : nil
        onSelectionChange?(content.selection)
        onSeek?(t)
        needsDisplay = true
    }

    /// Aimante le bord de sélection sur les coupes, le début et la fin (à 6 points près).
    private func snappedTime(at x: CGFloat) -> Double {
        let t = time(at: x)
        let candidates = [0, content.edits.duration] + content.edits.cutPoints
        if let nearest = candidates.min(by: { abs($0 - t) < abs($1 - t) }),
           abs(self.x(for: nearest) - x) <= 6 {
            return nearest
        }
        return t
    }

    private func updateAutoscroll() {
        let outside = lastDragPoint.x < inset || lastDragPoint.x > bounds.width - inset
        var scrollsContent = false
        switch drag {
        case .scrub, .select, .pendingClick, .trim: scrollsContent = true
        default: break
        }
        if maxScroll > 0, outside, scrollsContent {
            guard autoscrollTimer == nil else { return }
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollTick() }
            }
        } else {
            stopAutoscroll()
        }
    }

    private func autoscrollTick() {
        let point = lastDragPoint
        let overshoot = point.x < inset ? point.x - inset : point.x - (bounds.width - inset)
        guard overshoot != 0 else { return stopAutoscroll() }
        let speed = max(min(overshoot * 0.4, 45), -45)
        setScrollOffset(scrollOffset + (abs(speed) < 2 ? (speed < 0 ? -2 : 2) : speed))
        handleDrag(at: point)
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = location(of: event)
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        updateHover()
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: location(of: event))
    }

    private func updateHover() {
        if let hoverPoint { updateCursor(at: hoverPoint) }
        updateOverlayLayers()
    }

    private func updateCursor(at point: CGPoint) {
        if trimHandle(at: point) != nil || selectionAnchor(forEdgeNear: point) != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Barre de défilement

    private func scrollerKnobRect() -> CGRect {
        let y = trackBottom + (isTrimMode ? 11 : 7)
        guard maxScroll > 0 else { return .zero }
        let width = max(28, usableWidth * usableWidth / contentWidth)
        let x = inset + (scrollOffset / maxScroll) * (usableWidth - width)
        return CGRect(x: x, y: y, width: width, height: Self.scrollerHeight)
    }

    private func moveScroller(to pointX: CGFloat) {
        guard case .scroller(let grab) = drag, maxScroll > 0 else { return }
        let knobWidth = scrollerKnobRect().width
        let fraction = (pointX - grab - inset) / max(1, usableWidth - knobWidth)
        setScrollOffset(fraction * maxScroll)
    }

    // MARK: - Menu contextuel

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = location(of: event)
        guard point.y >= Self.trackTop - 4, !content.edits.isEmpty else { return nil }
        let t = time(at: point.x)
        let menu = NSMenu()
        if isTrimMode {
            menu.addItem(ClosureMenuItem(title: "Début du passage ici") { [weak self] in self?.onSetTrimStart?(t) })
            menu.addItem(ClosureMenuItem(title: "Fin du passage ici") { [weak self] in self?.onSetTrimEnd?(t) })
            if content.isTrimmed {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(title: "Garder toute la vidéo") { [weak self] in self?.onResetTrim?() })
            }
            return menu
        }
        menu.addItem(ClosureMenuItem(title: "Scinder ici") { [weak self] in self?.onSplit?(t) })
        if let selection = content.selection, selection.duration > 0 {
            menu.addItem(ClosureMenuItem(title: "Supprimer la sélection (\(Fmt.time(selection.duration)))") { [weak self] in
                self?.onDeleteSelection?()
            })
        }
        menu.addItem(.separator())
        if let placed = content.edits.placedSegments.first(where: { $0.range.contains(t) }) {
            menu.addItem(ClosureMenuItem(title: "Sélectionner ce segment") { [weak self] in
                self?.onSelectionChange?(placed.range)
            })
            if content.edits.segments.count > 1 {
                menu.addItem(ClosureMenuItem(title: "Supprimer ce segment") { [weak self] in
                    self?.onDeleteSegment?(t)
                })
            }
        }
        return menu
    }

    // MARK: - Calques superposés

    private func updateOverlayLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let hasContent = !content.edits.isEmpty
        let px = x(for: playhead)
        let lineBottom = trackBottom + 3
        playheadLayer.isHidden = !hasContent || px < inset - 8 || px > bounds.width - inset + 8
        playheadLayer.frame = CGRect(x: px - 6, y: 0, width: 12, height: bounds.height)
        if isTrimMode {
            playheadHead.isHidden = true
            playheadLine.backgroundColor = NSColor.white.cgColor
            playheadLine.cornerRadius = 2
            playheadLine.frame = CGRect(x: 4, y: Self.trackTop - 6, width: 4, height: Self.stripHeight + 12)
        } else {
            playheadHead.isHidden = false
            playheadLine.backgroundColor = Palette.playhead.cgColor
            playheadLine.cornerRadius = 0
            playheadLine.frame = CGRect(x: 5, y: 8, width: 2, height: lineBottom - 8)
        }
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 0, y: 1))
        head.addLine(to: CGPoint(x: 12, y: 1))
        head.addLine(to: CGPoint(x: 12, y: 9))
        head.addLine(to: CGPoint(x: 6, y: 15))
        head.addLine(to: CGPoint(x: 0, y: 9))
        head.closeSubpath()
        playheadHead.path = head
        playheadHead.frame = CGRect(x: 0, y: 0, width: 12, height: 16)

        if case .trim(let isStart, _) = drag {
            // Temps de la poignée en cours de glissement.
            let edge = isStart ? content.trimRange.start : content.trimRange.end
            hoverLine.isHidden = true
            showTimeLabel(Fmt.time(edge), at: x(for: edge))
        } else if let hoverPoint, hasContent, !isInScroller(hoverPoint), abs(hoverPoint.x - px) > 4,
           hoverPoint.x >= x(for: 0), hoverPoint.x <= x(for: content.edits.duration) {
            hoverLine.isHidden = false
            hoverLine.frame = CGRect(x: hoverPoint.x.rounded() - 0.5, y: Self.trackTop, width: 1, height: trackHeight)
            showTimeLabel(Fmt.time(time(at: hoverPoint.x)), at: hoverPoint.x)
            hoverLabel.isHidden = isInteracting && !isScrubbing
        } else {
            hoverLine.isHidden = true
            hoverLabel.isHidden = true
        }
    }

    private func showTimeLabel(_ text: String, at centerX: CGFloat) {
        hoverLabel.string = text
        let width = CGFloat(text.count) * 6.6 + 10
        let labelX = min(max(centerX - width / 2, 2), bounds.width - width - 2)
        hoverLabel.frame = CGRect(x: labelX, y: 4, width: width, height: 15)
        hoverLabel.isHidden = false
    }

    private var isScrubbing: Bool {
        if case .scrub = drag { return true }
        return false
    }

    // MARK: - Dessin

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dirtyRect = dirtyRect.intersection(bounds)
        Palette.background.setFill()
        dirtyRect.fill()
        guard !content.edits.isEmpty else { return }

        drawRuler(in: context)
        var wanted: [Double] = []
        var tolerance = 0.0
        if isTrimMode {
            drawTrimStrip(context: context, dirtyRect: dirtyRect, wanted: &wanted, tolerance: &tolerance)
        } else {
            for placed in content.edits.placedSegments {
                drawSegment(placed.segment, range: placed.range, context: context, dirtyRect: dirtyRect,
                            wanted: &wanted, tolerance: &tolerance)
            }
            drawCutMarkers(in: context)
            drawSelection(in: context)
            drawEndMarker(in: context)
        }
        drawScroller(in: context)

        if !wanted.isEmpty {
            let requested = wanted
            let requestTolerance = tolerance
            DispatchQueue.main.async { [weak self] in
                self?.thumbnails?.request(times: requested, tolerance: requestTolerance)
            }
        }
    }

    private func drawRuler(in context: CGContext) {
        Palette.ruler.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()

        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let major = steps.first { CGFloat($0) * pixelsPerSecond >= 64 } ?? 7200
        let subdivisions: Int
        if CGFloat(major / 5) * pixelsPerSecond >= 7 {
            subdivisions = [15, 30, 900, 1800].contains(major) ? 3 : 5
        } else if CGFloat(major / 2) * pixelsPerSecond >= 7 {
            subdivisions = 2
        } else {
            subdivisions = 1
        }
        let minor = major / Double(subdivisions)
        let firstIndex = Int((max(0, unclampedTime(at: 0)) / minor).rounded(.down))
        let lastIndex = Int((min(content.edits.duration, unclampedTime(at: bounds.width)) / minor).rounded(.up))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: Palette.rulerText,
        ]
        let ticks = CGMutablePath()
        if firstIndex <= lastIndex {
            for index in firstIndex...lastIndex {
                let t = Double(index) * minor
                guard t <= content.edits.duration + 1e-9 else { break }
                let px = x(for: t).rounded() + 0.5
                let isMajor = index % subdivisions == 0
                let height: CGFloat = isMajor ? 8 : 4
                ticks.move(to: CGPoint(x: px, y: Self.rulerHeight - height))
                ticks.addLine(to: CGPoint(x: px, y: Self.rulerHeight))
                if isMajor {
                    let label = NSAttributedString(string: Fmt.rulerTime(t, step: major), attributes: attributes)
                    if px + 3 + label.size().width <= bounds.width - 2 {
                        label.draw(at: CGPoint(x: px + 3, y: 3))
                    }
                }
            }
        }
        context.setStrokeColor(Palette.tick.cgColor)
        context.setLineWidth(1)
        context.addPath(ticks)
        context.strokePath()
    }

    private func drawSegment(_ segment: Segment, range: TimeRange, context: CGContext, dirtyRect: CGRect,
                             wanted: inout [Double], tolerance: inout Double) {
        let x0 = x(for: range.start), x1 = x(for: range.end)
        guard x1 >= dirtyRect.minX - 2, x0 <= dirtyRect.maxX + 2 else { return }
        var rect = CGRect(x: x0, y: Self.trackTop, width: x1 - x0, height: trackHeight)
        if rect.width > 6 { rect = rect.insetBy(dx: 1, dy: 0) }
        let shape = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)

        context.saveGState()
        context.addPath(shape)
        context.clip()

        Palette.segment.setFill()
        rect.fill()

        let visibleMinX = max(dirtyRect.minX, rect.minX)
        let visibleMaxX = min(dirtyRect.maxX, rect.maxX)
        drawTiles(segment: segment, from: x0, to: x1, height: Self.thumbHeight,
                  visibleMinX: visibleMinX, visibleMaxX: visibleMaxX, context: context,
                  wanted: &wanted, tolerance: &tolerance)

        if content.hasAudio {
            drawWaveform(segment: segment, range: range, rect: rect, visibleMinX: visibleMinX,
                         visibleMaxX: visibleMaxX, context: context)
        }
        context.restoreGState()

        // Contour (doré si le segment est sélectionné).
        context.saveGState()
        if segment.id == content.selectedSegmentID {
            let inner = CGPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(inner)
            context.setStrokeColor(Palette.accent.cgColor)
            context.setLineWidth(2.5)
        } else {
            let inner = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.addPath(inner)
            context.setStrokeColor(Palette.segmentBorder.cgColor)
            context.setLineWidth(1)
        }
        context.strokePath()
        context.restoreGState()
    }

    /// Vignettes d'un segment, calées sur son début pour ne pas « glisser » au défilement.
    private func drawTiles(segment: Segment, from x0: CGFloat, to x1: CGFloat, height: CGFloat,
                           visibleMinX: CGFloat, visibleMaxX: CGFloat, context: CGContext,
                           wanted: inout [Double], tolerance: inout Double) {
        let tileWidth = max(24, height * content.aspectRatio)
        tolerance = max(tolerance, Double(tileWidth / pixelsPerSecond) / 2)
        var index = max(0, Int(((visibleMinX - x0) / tileWidth).rounded(.down)))
        while true {
            let tileX = x0 + CGFloat(index) * tileWidth
            if tileX > visibleMaxX { break }
            let middle = min(tileX + tileWidth / 2, x1 - 1)
            let sourceTime = segment.sourceStart + Double(max(0, middle - x0) / pixelsPerSecond)
            let tileRect = CGRect(x: tileX, y: Self.trackTop, width: tileWidth, height: height)
            if let image = thumbnails?.image(near: sourceTime) {
                drawImage(image, in: tileRect, context: context)
            }
            wanted.append(min(sourceTime, segment.sourceEnd))
            index += 1
        }
        // Fines séparations entre vignettes.
        context.setFillColor(NSColor(white: 0, alpha: 0.25).cgColor)
        var separatorX = x0 + tileWidth
        while separatorX < visibleMaxX {
            if separatorX > visibleMinX {
                context.fill(CGRect(x: separatorX.rounded(), y: Self.trackTop, width: 1, height: height))
            }
            separatorX += tileWidth
        }
    }

    /// Mode Rogner : une pellicule continue, assombrie hors du passage gardé, dans un cadre à poignées.
    private func drawTrimStrip(context: CGContext, dirtyRect: CGRect,
                               wanted: inout [Double], tolerance: inout Double) {
        let top = Self.trackTop, height = Self.stripHeight
        let x0 = x(for: 0), x1 = x(for: content.edits.duration)
        let strip = CGRect(x: x0, y: top, width: x1 - x0, height: height)

        context.saveGState()
        context.addPath(CGPath(roundedRect: strip, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        Palette.segment.setFill()
        strip.fill()
        for placed in content.edits.placedSegments {
            let segmentMinX = x(for: placed.range.start), segmentMaxX = x(for: placed.range.end)
            guard segmentMaxX >= dirtyRect.minX, segmentMinX <= dirtyRect.maxX else { continue }
            context.saveGState()
            context.clip(to: CGRect(x: segmentMinX, y: top, width: segmentMaxX - segmentMinX, height: height))
            drawTiles(segment: placed.segment, from: segmentMinX, to: segmentMaxX, height: height,
                      visibleMinX: max(dirtyRect.minX, segmentMinX), visibleMaxX: min(dirtyRect.maxX, segmentMaxX),
                      context: context, wanted: &wanted, tolerance: &tolerance)
            context.restoreGState()
        }
        // Coupes faites en mode Découper : simple trait.
        context.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
        for cut in content.edits.cutPoints {
            context.fill(CGRect(x: x(for: cut).rounded() - 1, y: top, width: 2, height: height))
        }
        // Hors du passage : assombri.
        let inX = x(for: content.trimRange.start), outX = x(for: content.trimRange.end)
        context.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
        context.fill(CGRect(x: x0, y: top, width: max(0, inX - x0), height: height))
        context.fill(CGRect(x: outX, y: top, width: max(0, x1 - outX), height: height))
        context.restoreGState()

        // Cadre : gris tant que toute la vidéo est gardée, jaune dès qu'on rogne (comme sur iPhone).
        let active = content.isTrimmed || isDraggingTrim
        let frameColor = active ? Palette.accent : NSColor(white: 0.82, alpha: 1)
        let handle = Self.handleWidth, border: CGFloat = 3
        let outer = CGRect(x: inX - handle, y: top - border, width: outX - inX + handle * 2, height: height + border * 2)
        let frame = CGMutablePath()
        frame.addPath(CGPath(roundedRect: outer, cornerWidth: 7, cornerHeight: 7, transform: nil))
        frame.addRect(CGRect(x: inX, y: top, width: max(0, outX - inX), height: height))
        context.addPath(frame)
        context.setFillColor(frameColor.cgColor)
        context.fillPath(using: .evenOdd)

        // Chevrons ‹ ›.
        context.setStrokeColor(NSColor(white: 0, alpha: 0.75).cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let midY = top + height / 2
        for (centerX, direction) in [(inX - handle / 2, CGFloat(1)), (outX + handle / 2, CGFloat(-1))] {
            context.move(to: CGPoint(x: centerX + 2.5 * direction, y: midY - 7))
            context.addLine(to: CGPoint(x: centerX - 2.5 * direction, y: midY))
            context.addLine(to: CGPoint(x: centerX + 2.5 * direction, y: midY + 7))
        }
        context.strokePath()

        // Durée gardée, au-dessus du cadre.
        if active, !isDraggingTrim {
            drawDurationCapsule(content.trimRange.duration, centeredAt: (inX + outX) / 2, maxWidth: outX - inX + 40,
                                context: context)
        }
    }

    private func drawDurationCapsule(_ duration: Double, centeredAt centerX: CGFloat, maxWidth: CGFloat,
                                     context: CGContext) {
        let text = NSAttributedString(string: Fmt.time(duration), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let size = text.size()
        let capsule = CGRect(x: centerX - size.width / 2 - 6, y: 3, width: size.width + 12, height: 15)
        guard capsule.width < maxWidth else { return }
        context.setFillColor(Palette.accent.cgColor)
        context.addPath(CGPath(roundedRect: capsule, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        context.fillPath()
        text.draw(at: CGPoint(x: capsule.minX + 6, y: capsule.minY + (capsule.height - size.height) / 2))
    }

    private func drawWaveform(segment: Segment, range: TimeRange, rect: CGRect,
                              visibleMinX: CGFloat, visibleMaxX: CGFloat, context: CGContext) {
        let waveRect = CGRect(x: rect.minX, y: Self.trackTop + Self.thumbHeight,
                              width: rect.width, height: Self.waveHeight)
        Palette.waveBackground.setFill()
        waveRect.fill()
        context.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
        context.fill(CGRect(x: waveRect.minX, y: waveRect.minY, width: waveRect.width, height: 1))

        guard let waveform else { return }
        let midY = waveRect.midY + 0.5
        let maxAmplitude = (waveRect.height - 6) / 2
        let bars = CGMutablePath()
        let x0 = x(for: range.start)
        var px = visibleMinX.rounded(.down)
        while px < visibleMaxX {
            let s0 = segment.sourceStart + Double(max(0, px - x0) / pixelsPerSecond)
            let s1 = segment.sourceStart + Double(max(0, px + 1 - x0) / pixelsPerSecond)
            let level = waveform.level(from: s0, to: min(s1, segment.sourceEnd))
            let amplitude = max(0.5, CGFloat(level) * maxAmplitude)
            bars.addRect(CGRect(x: px, y: midY - amplitude, width: 1, height: amplitude * 2))
            px += 1
        }
        context.setFillColor(Palette.wave.cgColor)
        context.addPath(bars)
        context.fillPath()
    }

    private func drawCutMarkers(in context: CGContext) {
        context.setFillColor(Palette.accent.cgColor)
        for cut in content.edits.cutPoints {
            let px = x(for: cut)
            guard px > -10, px < bounds.width + 10 else { continue }
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: px - 4, y: Self.rulerHeight))
            marker.addLine(to: CGPoint(x: px + 4, y: Self.rulerHeight))
            marker.addLine(to: CGPoint(x: px, y: Self.rulerHeight + 5))
            marker.closeSubpath()
            context.addPath(marker)
            context.fillPath()
        }
    }

    private func drawSelection(in context: CGContext) {
        guard let selection = content.selection, selection.duration > 0 else { return }
        let x0 = x(for: selection.start), x1 = x(for: selection.end)
        guard x1 >= -10, x0 <= bounds.width + 10 else { return }
        let rect = CGRect(x: x0, y: Self.trackTop - 3, width: max(1, x1 - x0), height: trackHeight + 6)

        context.saveGState()
        context.setFillColor(Palette.accent.withAlphaComponent(0.22).cgColor)
        context.fill(rect)
        // Hachures discrètes : ce passage sera supprimé avec ⌫.
        context.clip(to: rect)
        context.setStrokeColor(Palette.accent.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1)
        var hatchX = rect.minX - rect.height
        while hatchX < rect.maxX {
            context.move(to: CGPoint(x: hatchX, y: rect.maxY))
            context.addLine(to: CGPoint(x: hatchX + rect.height, y: rect.minY))
            hatchX += 7
        }
        context.strokePath()
        context.restoreGState()

        context.setStrokeColor(Palette.accent.cgColor)
        context.setLineWidth(1.5)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.strokePath()

        // Poignées.
        for edgeX in [x0, x1] {
            let handle = CGRect(x: edgeX - 3, y: rect.midY - 13, width: 6, height: 26)
            context.setFillColor(Palette.accent.cgColor)
            context.addPath(CGPath(roundedRect: handle, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            context.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
            context.fill(CGRect(x: edgeX - 0.5, y: rect.midY - 6, width: 1, height: 12))
        }

        // Durée sélectionnée, affichée dans la règle.
        drawDurationCapsule(selection.duration, centeredAt: (x0 + x1) / 2, maxWidth: (x1 - x0) + 40, context: context)
    }

    private func drawEndMarker(in context: CGContext) {
        let px = x(for: content.edits.duration)
        guard px < bounds.width - 1 else { return }
        context.setFillColor(NSColor(white: 1, alpha: 0.3).cgColor)
        context.fill(CGRect(x: px.rounded() + 1, y: Self.trackTop - 4, width: 1, height: trackHeight + 8))
    }

    private func drawScroller(in context: CGContext) {
        guard maxScroll > 0 else { return }
        let knob = scrollerKnobRect()
        let track = CGRect(x: inset, y: knob.minY, width: usableWidth, height: knob.height)
        context.setFillColor(NSColor(white: 1, alpha: 0.07).cgColor)
        context.addPath(CGPath(roundedRect: track, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        context.fillPath()
        context.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
        context.addPath(CGPath(roundedRect: knob, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        context.fillPath()
        // Position de la tête de lecture dans la barre.
        let playheadX = inset + CGFloat(playhead / duration) * usableWidth
        context.setFillColor(Palette.playhead.cgColor)
        context.fill(CGRect(x: playheadX - 0.5, y: knob.minY - 1, width: 1.5, height: knob.height + 2))
    }

    /// Dessine une image dans une vue « retournée » (origine en haut).
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// Élément de menu qui exécute une closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) n'est pas pris en charge") }

    @objc private func invoke() { handler() }
}
