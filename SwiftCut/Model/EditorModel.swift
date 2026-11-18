import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

/// Deux façons de couper la vidéo.
enum EditMode: String, CaseIterable, Identifiable {
    /// Comme sur iPhone : on garde un seul passage, encadré par deux poignées.
    case trim
    /// Montage libre : on scinde et on supprime autant de passages que voulu.
    case cut

    var id: Self { self }

    var title: String {
        switch self {
        case .trim: "Rogner"
        case .cut: "Découper"
        }
    }

    var systemImage: String {
        switch self {
        case .trim: "timeline.selection"
        case .cut: "scissors"
        }
    }
}

/// État de l'éditeur : vidéo ouverte, montage, lecture, sélection et export.
@MainActor
@Observable
final class EditorModel {
    static let shared = EditorModel()

    // MARK: Média

    private(set) var media: MediaInfo?
    private(set) var isLoading = false
    var errorMessage: String?
    var notice: String?

    // MARK: Montage

    /// Mode Rogner par défaut ; conservé d'une vidéo à l'autre pendant la session.
    private(set) var mode: EditMode = .trim
    private(set) var edits = EditList()
    /// Passage gardé en mode Rogner (temps de la timeline).
    private(set) var trimRange = TimeRange(0, 0)
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Contenu au moment de l'ouverture ou du dernier export réussi.
    private var savedEdits = EditList()
    private var savedCrop = CropRect.full
    private var savedBlurs: [BlurRegion] = []

    // MARK: Recadrage

    /// Zone de l'image gardée à l'export (toute l'image par défaut).
    private(set) var crop = CropRect.full
    /// Vrai pendant l'édition du cadre (outil Recadrer ouvert).
    private(set) var isCropping = false
    private(set) var cropAspect: CropAspect = .free

    // MARK: Flous

    /// Zones floutées ou pixelisées.
    private(set) var blurs: [BlurRegion] = []
    /// Vrai pendant l'édition des zones (outil Flouter ouvert).
    private(set) var isBlurring = false
    var selectedBlurID: BlurRegion.ID?

    /// Plage sélectionnée sur la timeline (glisser, ou touches I / O).
    var selection: TimeRange?
    /// Segment sélectionné d'un clic.
    var selectedSegmentID: Segment.ID?

    // MARK: Lecture

    @ObservationIgnored let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var playbackRate: Float = 0

    // MARK: Timeline

    /// 0 = toute la vidéo visible, 1 = zoom maximal.
    var zoomLevel: Double = 0
    @ObservationIgnored let thumbnails = ThumbnailStore()
    private(set) var waveform: Waveform?

    // MARK: Fenêtres et feuilles

    var isExportSheetPresented = false
    var isShortcutsHelpPresented = false
    var exportSettings = ExportSettings.load()
    var exportJob: ExportJob?
    var pendingOpenURL: URL?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let menuState = MenuState()
    @ObservationIgnored private var pendingExportSettings: ExportSettings?

    // MARK: Interne

    private struct Snapshot {
        let edits: EditList
        let trimRange: TimeRange
        let crop: CropRect
        let blurs: [BlurRegion]
        let playhead: Double
        let selection: TimeRange?
        let selectedSegmentID: Segment.ID?
    }

    static let minimumTrimDuration = 0.1

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var chaseTime: Double = 0
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var trimSnapshot: Snapshot?
    @ObservationIgnored private var cropDragSnapshot: Snapshot?
    @ObservationIgnored private var cropAtStart = CropRect.full
    @ObservationIgnored private var undoDepthAtCropStart = 0
    @ObservationIgnored private var blurGestureSnapshot: Snapshot?
    @ObservationIgnored private let previewEffects = PreviewEffects()
    @ObservationIgnored private weak var effectsPendingItem: AVPlayerItem?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.syncPlaybackState() }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.syncPlaybackState() }
            },
        ]
        updateMenuState()
    }

    /// Recopie dans `menuState` ce dont les menus ont besoin, à chaque changement.
    private func updateMenuState() {
        let state = withObservationTracking {
            MenuState.Values(hasMedia: media != nil,
                             canExport: media != nil && !isExporting && exportDuration > 0,
                             canDelete: canDelete,
                             isTrimMode: mode == .trim,
                             isTrimmed: isTrimmed,
                             isCropping: isCropping,
                             isCropped: isCropped,
                             isBlurring: isBlurring)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateMenuState() }
        }
        menuState.update(state)
    }

    // MARK: - État dérivé

    var duration: Double { edits.duration }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canDelete: Bool { mode == .cut && ((selection?.duration ?? 0) > 0 || selectedSegmentID != nil) }
    var isExporting: Bool { exportJob?.state == .running }

    /// Vrai si le passage gardé en mode Rogner n'est pas toute la vidéo.
    var isTrimmed: Bool { trimRange.start > 0.0005 || trimRange.end < duration - 0.0005 }
    /// Ce qui sera exporté : le passage encadré en mode Rogner, toute la timeline en mode Découper.
    var exportEdits: EditList { mode == .trim ? edits.trimmed(to: trimRange) : edits }
    var exportDuration: Double { mode == .trim ? trimRange.duration : duration }
    var removedDuration: Double { (media?.duration ?? 0) - exportDuration }
    var hasUnexportedChanges: Bool {
        media != nil && (!exportEdits.hasSameContent(as: savedEdits) || crop != savedCrop || blurs != savedBlurs)
    }

    var isCropped: Bool { !crop.isFull }
    /// Taille en pixels de la zone gardée (avant un éventuel redimensionnement à l'export).
    var croppedSize: CGSize { media.map { crop.pixelRect(in: $0.displaySize).size } ?? .zero }
    /// Proportion imposée par le format choisi, en coordonnées normalisées (`nil` = libre).
    var cropRatio: Double? {
        guard let media, let ratio = cropAspect.pixelRatio(for: media.displaySize) else { return nil }
        return ratio / Double(media.aspectRatio)
    }

    // MARK: - Ouverture

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choisissez une vidéo à éditer"
        panel.prompt = "Ouvrir"
        if let url = media?.url {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.requestOpen(url) }
        }
        if let window, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Ouvre une vidéo, en demandant confirmation si le montage en cours n'a pas été exporté.
    func requestOpen(_ url: URL) {
        guard !isExporting else {
            showNotice("Attendez la fin de l'exportation avant d'ouvrir une autre vidéo.")
            return
        }
        if hasUnexportedChanges {
            pendingOpenURL = url
        } else {
            open(url)
        }
    }

    func open(_ url: URL) {
        pendingOpenURL = nil
        loadTask?.cancel()
        pause()
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let info = try await MediaInfo.load(url: url)
                guard !Task.isCancelled else { return }
                self?.install(info)
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = "Impossible d'ouvrir « \(url.lastPathComponent) ».\n\n\(error.localizedDescription)"
            }
            self?.isLoading = false
        }
    }

    private func install(_ info: MediaInfo) {
        media = info
        edits = EditList(sourceRange: info.sourceRange)
        trimRange = TimeRange(0, edits.duration)
        savedEdits = edits
        crop = .full
        savedCrop = .full
        cropAspect = .free
        isCropping = false
        blurs = []
        savedBlurs = []
        isBlurring = false
        selectedBlurID = nil
        undoStack.removeAll()
        redoStack.removeAll()
        selection = nil
        selectedSegmentID = nil
        zoomLevel = 0
        currentTime = 0
        exportJob = nil
        rebuildPlayerItem(at: 0)
        thumbnails.reset(asset: info.asset, sourceRange: info.sourceRange, aspectRatio: info.aspectRatio)

        waveform = nil
        waveformTask?.cancel()
        waveformTask = Task { [weak self] in
            let result = try? await Waveform.load(media: info)
            guard !Task.isCancelled, let self, self.media?.url == info.url else { return }
            self.waveform = result
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(info.url)
    }

    // MARK: - Lecteur

    private func rebuildPlayerItem(at time: Double) {
        isSeeking = false
        guard let media, !edits.isEmpty,
              let built = try? CompositionBuilder.make(media: media, segments: edits.segments) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.seek(to: self?.currentTime ?? 0) }
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = self.mode == .trim ? self.trimRange.end : self.duration
            }
        }
        player.replaceCurrentItem(with: item)
        applyPlaybackBounds()
        effectsChanged()
        seek(to: time)
    }

    /// En mode Rogner, la lecture s'arrête aux bords du passage gardé.
    private func applyPlaybackBounds() {
        guard let item = player.currentItem else { return }
        let trim = mode == .trim
        item.forwardPlaybackEndTime = trim && trimRange.end < duration - 0.0005
            ? CompositionBuilder.time(trimRange.end) : .invalid
        item.reversePlaybackEndTime = trim && trimRange.start > 0.0005
            ? CompositionBuilder.time(trimRange.start) : .invalid
    }

    private func playerTimeChanged(_ time: CMTime) {
        guard !isSeeking, time.isNumeric else { return }
        let seconds = min(max(time.seconds, 0), duration)
        if abs(seconds - currentTime) > 0.0005 {
            currentTime = seconds
        }
    }

    private func syncPlaybackState() {
        let playing = player.timeControlStatus != .paused
        if isPlaying != playing { isPlaying = playing }
        let rate = playing ? player.rate : 0
        if playbackRate != rate { playbackRate = rate }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play(rate: Float = 1) {
        guard player.currentItem != nil, duration > 0 else { return }
        // Lecture limitée au passage gardé en mode Rogner (depuis son début si on est en dehors).
        let bounds = mode == .trim ? trimRange : TimeRange(0, duration)
        if rate > 0, currentTime < bounds.start - 0.01 || currentTime >= bounds.end - 0.03 { seek(to: bounds.start) }
        if rate < 0, currentTime > bounds.end + 0.01 || currentTime <= bounds.start + 0.03 { seek(to: bounds.end) }
        player.rate = rate
    }

    func pause() {
        player.pause()
    }

    /// Lecture rapide façon J / K / L.
    func shuttle(forward: Bool) {
        guard let item = player.currentItem else { return }
        let current = isPlaying ? player.rate : 0
        var next: Float = forward ? (current <= 0 ? 1 : min(current * 2, 8))
                                  : (current >= 0 ? -1 : max(current * 2, -8))
        if next < 0, !item.canPlayReverse {
            NSSound.beep()
            return
        }
        if next > 2, !item.canPlayFastForward { next = 2 }
        if next < -1, !item.canPlayFastReverse { next = -1 }
        play(rate: next)
    }

    /// Déplacement précis de la tête de lecture, avec rattrapage pour un défilement fluide.
    func seek(to time: Double) {
        let target = min(max(time, 0), duration)
        currentTime = target
        chaseTime = target
        if !isSeeking { performSeek() }
    }

    private func performSeek() {
        guard player.currentItem != nil else {
            isSeeking = false
            return
        }
        isSeeking = true
        let target = chaseTime
        player.seek(to: CompositionBuilder.time(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.chaseTime == target {
                    self.isSeeking = false
                } else {
                    self.performSeek()
                }
            }
        }
    }

    func step(frames: Int) {
        pause()
        let frameDuration = 1 / (media?.maxFrameRate ?? 30)
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    /// Début de la vidéo, ou du passage gardé en mode Rogner.
    func goToStart() {
        seek(to: mode == .trim ? trimRange.start : 0)
    }

    /// Fin de la vidéo, ou du passage gardé en mode Rogner.
    func goToEnd() {
        seek(to: mode == .trim ? trimRange.end : duration)
    }

    /// Repères pour ↑ / ↓ : coupes, ou bords du passage en mode Rogner.
    private var jumpPoints: [Double] {
        let inner = mode == .trim ? [trimRange.start, trimRange.end] : edits.cutPoints
        return Array(Set([0, duration] + inner)).sorted()
    }

    func jumpToPreviousCut() {
        seek(to: jumpPoints.last { $0 < currentTime - 0.01 } ?? 0)
    }

    func jumpToNextCut() {
        seek(to: jumpPoints.first { $0 > currentTime + 0.01 } ?? duration)
    }

    func beginScrubbing() {
        resumeAfterScrub = isPlaying
        pause()
    }

    func endScrubbing() {
        if resumeAfterScrub { play() }
        resumeAfterScrub = false
    }

    // MARK: - Sélection

    func setSelection(_ range: TimeRange?) {
        selection = range
        if range != nil { selectedSegmentID = nil }
    }

    /// Clic sur la timeline : sélectionne le segment cliqué (s'il y a plusieurs segments).
    func selectSegment(at time: Double) {
        selection = nil
        selectedSegmentID = edits.segments.count > 1 ? edits.segment(at: time)?.id : nil
    }

    func clearSelection() {
        selection = nil
        selectedSegmentID = nil
    }

    /// Touche I : début de la sélection (ou du passage en mode Rogner) à la tête de lecture.
    func markIn() {
        if mode == .trim { return setTrimStart() }
        guard media != nil, currentTime < duration - 0.01 else { return NSSound.beep() }
        let end = selection.map { $0.end > currentTime ? $0.end : duration } ?? duration
        setSelection(TimeRange(currentTime, end))
    }

    /// Touche O : fin de la sélection (ou du passage en mode Rogner) à la tête de lecture.
    func markOut() {
        if mode == .trim { return setTrimEnd() }
        guard media != nil, currentTime > 0.01 else { return NSSound.beep() }
        let start = selection.map { $0.start < currentTime ? $0.start : 0 } ?? 0
        setSelection(TimeRange(start, currentTime))
    }

    // MARK: - Montage

    func splitAtPlayhead() {
        guard media != nil else { return }
        guard mode == .cut else {
            return showNotice("Pour scinder la vidéo en plusieurs passages, passez en mode Découper (⌘2).")
        }
        var updated = edits
        guard updated.split(at: currentTime) else {
            showNotice("Placez la tête de lecture à l'intérieur d'un segment pour le scinder.")
            return
        }
        commit(updated, playhead: currentTime, clearSelection: true)
    }

    func split(at time: Double) {
        seek(to: time)
        splitAtPlayhead()
    }

    func deleteSelection() {
        guard media != nil else { return }
        guard mode == .cut else {
            return showNotice("En mode Rogner, seul le passage encadré est exporté. Pour supprimer un passage au milieu, passez en mode Découper (⌘2).")
        }
        if let selection, selection.duration > 0 {
            removeRange(selection)
        } else if let id = selectedSegmentID, let range = edits.range(ofSegment: id) {
            removeRange(range)
        } else {
            showNotice("Sélectionnez d'abord un passage (glissez sur la timeline) ou un segment.")
        }
    }

    func deleteSegment(at time: Double) {
        guard let segment = edits.segment(at: time), let range = edits.range(ofSegment: segment.id) else { return }
        removeRange(range)
    }

    func deleteBeforePlayhead() {
        if mode == .trim { return setTrimStart() }
        guard media != nil, currentTime > 0.01 else { return NSSound.beep() }
        removeRange(TimeRange(0, currentTime))
    }

    func deleteAfterPlayhead() {
        if mode == .trim { return setTrimEnd() }
        guard media != nil, currentTime < duration - 0.01 else { return NSSound.beep() }
        removeRange(TimeRange(currentTime, duration))
    }

    private func removeRange(_ range: TimeRange) {
        var updated = edits
        updated.remove(range)
        guard updated.duration >= 0.05 else {
            showNotice("Impossible de supprimer toute la vidéo.")
            return
        }
        let playhead: Double
        if currentTime <= range.start {
            playhead = currentTime
        } else if currentTime >= range.end {
            playhead = currentTime - range.duration
        } else {
            playhead = range.start
        }
        commit(updated, playhead: playhead, clearSelection: true)
    }

    private func commit(_ updated: EditList, playhead: Double, clearSelection: Bool = false) {
        pushUndo(snapshot())
        if clearSelection {
            selection = nil
            selectedSegmentID = nil
        }
        apply(updated, playhead: playhead)
    }

    private func pushUndo(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func snapshot() -> Snapshot {
        Snapshot(edits: edits, trimRange: trimRange, crop: crop, blurs: blurs, playhead: currentTime,
                 selection: selection, selectedSegmentID: selectedSegmentID)
    }

    private func apply(_ updated: EditList, playhead: Double) {
        pause()
        // Le passage rogné suit la nouvelle durée (il reste « toute la vidéo » s'il l'était).
        let wasWhole = !isTrimmed
        edits = updated
        if wasWhole || trimRange.duration < Self.minimumTrimDuration {
            trimRange = TimeRange(0, updated.duration)
        } else {
            trimRange = trimRange.clamped(to: TimeRange(0, updated.duration)) ?? TimeRange(0, updated.duration)
        }
        if let id = selectedSegmentID, !updated.segments.contains(where: { $0.id == id }) {
            selectedSegmentID = nil
        }
        if let range = selection {
            selection = range.clamped(to: TimeRange(0, updated.duration))
        }
        currentTime = min(max(playhead, 0), updated.duration)
        rebuildPlayerItem(at: currentTime)
    }

    func undo() {
        guard handlesEditCommands else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            return
        }
        guard let previous = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(snapshot())
        restore(previous)
    }

    func redo() {
        guard handlesEditCommands else {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            return
        }
        guard let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(snapshot())
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        apply(snapshot.edits, playhead: snapshot.playhead)
        trimRange = snapshot.trimRange
        crop = snapshot.crop
        blurs = snapshot.blurs
        if let id = selectedBlurID, !blurs.contains(where: { $0.id == id }) { selectedBlurID = nil }
        selection = snapshot.selection
        selectedSegmentID = snapshot.selectedSegmentID
        applyPlaybackBounds()
        effectsChanged()
    }

    // MARK: - Recadrage

    func toggleCropping() {
        isCropping ? finishCropping() : beginCropping()
    }

    /// Ouvre l'outil Recadrer : toute l'image s'affiche avec le cadre par-dessus.
    func beginCropping() {
        guard media != nil, !isCropping else { return }
        if isBlurring { finishBlurring() }
        cropAtStart = crop
        undoDepthAtCropStart = undoStack.count
        isCropping = true
    }

    /// Valide le cadre (bouton Terminé, touche Entrée).
    func finishCropping() {
        isCropping = false
    }

    /// Revient au cadre d'avant l'ouverture de l'outil (bouton Annuler, touche Échap).
    func cancelCropping() {
        guard isCropping else { return }
        crop = cropAtStart
        // Les étapes d'annulation créées pendant cette séance n'ont plus lieu d'être.
        if undoStack.count > undoDepthAtCropStart {
            undoStack.removeLast(undoStack.count - undoDepthAtCropStart)
        }
        isCropping = false
    }

    /// Début d'un glissement sur le cadre (une seule étape d'annulation par geste).
    func beginCropDrag() {
        cropDragSnapshot = snapshot()
    }

    func updateCropDrag(_ rect: CropRect) {
        crop = rect
    }

    func endCropDrag() {
        if let before = cropDragSnapshot, before.crop != crop {
            pushUndo(before)
        }
        cropDragSnapshot = nil
    }

    /// Choisit un format ; le cadre devient le plus grand possible dans cette proportion.
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let ratio = cropRatio else { return }
        let center = CGPoint(x: crop.x + crop.width / 2, y: crop.y + crop.height / 2)
        changeCrop(to: .largest(ratio: ratio, centeredOn: center))
    }

    /// Garde de nouveau toute l'image.
    func resetCrop() {
        cropAspect = .free
        changeCrop(to: .full)
    }

    private func changeCrop(to rect: CropRect) {
        guard rect != crop else { return }
        pushUndo(snapshot())
        crop = rect
    }

    // MARK: - Flous

    var selectedBlur: BlurRegion? { blurs.first { $0.id == selectedBlurID } }

    func toggleBlurring() {
        isBlurring ? finishBlurring() : beginBlurring()
    }

    /// Ouvre l'outil Flouter : toute l'image s'affiche, on y dessine des rectangles.
    func beginBlurring() {
        guard media != nil, !isBlurring else { return }
        if isCropping { finishCropping() }
        isBlurring = true
    }

    func finishBlurring() {
        isBlurring = false
        selectedBlurID = nil
    }

    /// Début d'un geste (dessin, déplacement, réglage) : une seule étape d'annulation par geste.
    func beginBlurGesture() {
        if blurGestureSnapshot == nil { blurGestureSnapshot = snapshot() }
    }

    func endBlurGesture() {
        if let before = blurGestureSnapshot, before.blurs != blurs {
            pushUndo(before)
        }
        blurGestureSnapshot = nil
    }

    /// Nouvelle zone (pendant un geste de dessin). Reprend le style de la zone sélectionnée.
    @discardableResult
    func insertBlur(_ rect: CropRect) -> BlurRegion.ID {
        var region = BlurRegion(rect: rect)
        if let model = selectedBlur ?? blurs.last {
            region.style = model.style
            region.intensity = model.intensity
        }
        blurs.append(region)
        selectedBlurID = region.id
        effectsChanged()
        return region.id
    }

    func updateBlurRect(_ id: BlurRegion.ID, to rect: CropRect) {
        guard let index = blurs.firstIndex(where: { $0.id == id }), blurs[index].rect != rect else { return }
        blurs[index].rect = rect
        effectsChanged()
    }

    /// Retire une zone sans étape d'annulation (dessin trop petit, abandonné).
    func discardBlur(_ id: BlurRegion.ID) {
        blurs.removeAll { $0.id == id }
        if selectedBlurID == id { selectedBlurID = nil }
        effectsChanged()
    }

    func deleteSelectedBlur() {
        guard let id = selectedBlurID else { return NSSound.beep() }
        pushUndo(snapshot())
        blurs.removeAll { $0.id == id }
        selectedBlurID = nil
        effectsChanged()
    }

    func setSelectedBlurStyle(_ style: BlurRegion.Style) {
        modifySelectedBlur(undoable: true) { $0.style = style }
    }

    /// Réglage continu (curseur) : l'annulation est gérée par `beginBlurGesture` / `endBlurGesture`.
    func setSelectedBlurIntensity(_ intensity: Double) {
        modifySelectedBlur(undoable: false) { $0.intensity = min(max(intensity, 0.2), 1) }
    }

    /// La zone sélectionnée apparaît à partir de la tête de lecture.
    func setSelectedBlurStart() {
        guard let media, let source = edits.sourceTime(at: currentTime) else { return }
        modifySelectedBlur(undoable: true) { blur in
            let end = blur.sourceRange?.end ?? media.sourceRange.end
            blur.sourceRange = Self.normalizedRange(TimeRange(source, source < end ? end : media.sourceRange.end),
                                                    in: media.sourceRange)
        }
    }

    /// La zone sélectionnée disparaît à la tête de lecture.
    func setSelectedBlurEnd() {
        guard let media, let source = edits.sourceTime(at: currentTime) else { return }
        modifySelectedBlur(undoable: true) { blur in
            let start = blur.sourceRange?.start ?? media.sourceRange.start
            blur.sourceRange = Self.normalizedRange(TimeRange(source > start ? start : media.sourceRange.start, source),
                                                    in: media.sourceRange)
        }
    }

    func clearSelectedBlurRange() {
        modifySelectedBlur(undoable: true) { $0.sourceRange = nil }
    }

    /// Période d'une zone, en temps de la timeline (« Toute la vidéo » si elle n'est pas limitée).
    func rangeDescription(for blur: BlurRegion) -> String {
        guard let range = blur.sourceRange else { return "Toute la vidéo" }
        let start = edits.timelineTime(forSource: range.start) ?? range.start
        let end = edits.timelineTime(forSource: range.end) ?? range.end
        return "\(Fmt.time(start)) → \(Fmt.time(end))"
    }

    /// Une zone est-elle visible à la tête de lecture ?
    func isBlurVisibleNow(_ blur: BlurRegion) -> Bool {
        blur.isActive(atSource: edits.sourceTime(at: currentTime) ?? 0)
    }

    private static func normalizedRange(_ range: TimeRange, in whole: TimeRange) -> TimeRange? {
        guard range.duration > 0.01 else { return nil }
        let covers = range.start <= whole.start + 0.01 && range.end >= whole.end - 0.01
        return covers ? nil : range
    }

    private func modifySelectedBlur(undoable: Bool, _ change: (inout BlurRegion) -> Void) {
        guard let index = blurs.firstIndex(where: { $0.id == selectedBlurID }) else { return }
        var updated = blurs[index]
        change(&updated)
        guard updated != blurs[index] else { return }
        if undoable { pushUndo(snapshot()) }
        blurs[index] = updated
        effectsChanged()
    }

    /// Met à jour le rendu des flous dans l'aperçu (filtre Core Image sur la lecture).
    private func effectsChanged() {
        previewEffects.renderer = FrameRenderer(blurs: blurs, timeMap: SourceTimeMap(segments: edits.segments))
        guard let item = player.currentItem else { return }
        if blurs.isEmpty {
            if item.videoComposition != nil {
                item.videoComposition = nil
                refreshPreviewFrame()
            }
        } else if item.videoComposition == nil {
            attachEffects(to: item)
        } else {
            refreshPreviewFrame()
        }
    }

    private func attachEffects(to item: AVPlayerItem) {
        guard effectsPendingItem !== item else { return }
        effectsPendingItem = item
        let effects = previewEffects
        Task { [weak self] in
            let composition = try? await AVMutableVideoComposition.videoComposition(
                with: item.asset,
                applyingCIFiltersWithHandler: { request in
                    request.finish(with: effects.renderer.render(request.sourceImage,
                                                                 compositionTime: request.compositionTime,
                                                                 renderSize: request.renderSize),
                                   context: nil)
                })
            guard let self, let composition, self.player.currentItem === item, !self.blurs.isEmpty else { return }
            item.videoComposition = composition
            self.effectsPendingItem = nil
            self.refreshPreviewFrame()
        }
    }

    /// À l'arrêt, l'image affichée n'est recalculée qu'en se repositionnant dessus.
    private func refreshPreviewFrame() {
        if !isPlaying { seek(to: currentTime) }
    }

    // MARK: - Mode et rognage

    func setMode(_ newMode: EditMode) {
        guard newMode != mode else { return }
        pause()
        clearSelection()
        if newMode == .cut, media != nil, isTrimmed {
            // On ne perd rien en changeant de mode : le rognage devient de vraies coupes.
            let updated = edits.trimmed(to: trimRange)
            let playhead = currentTime - trimRange.start
            mode = newMode
            commit(updated, playhead: playhead)
            trimRange = TimeRange(0, updated.duration)
            showNotice("Le rognage a été appliqué à la timeline (⌘Z pour annuler).", beep: false)
        } else {
            mode = newMode
        }
        applyPlaybackBounds()
    }

    /// Début du glissement d'une poignée de rognage (une seule étape d'annulation par geste).
    func beginTrimming() {
        trimSnapshot = snapshot()
        pause()
    }

    /// Pendant le glissement : met à jour le passage et affiche l'image sous la poignée.
    func updateTrim(_ range: TimeRange, preview time: Double) {
        trimRange = validTrim(range)
        seek(to: time)
    }

    func endTrimming() {
        if let before = trimSnapshot, before.trimRange != trimRange {
            pushUndo(before)
        }
        trimSnapshot = nil
        applyPlaybackBounds()
    }

    /// Place le début du passage (touche I) à la tête de lecture ou au temps donné.
    func setTrimStart(at time: Double? = nil) {
        guard media != nil else { return }
        let start = time ?? currentTime
        guard start <= trimRange.end - Self.minimumTrimDuration else {
            return showNotice("Le début doit se trouver avant la fin du passage.")
        }
        changeTrim(to: TimeRange(start, trimRange.end))
    }

    /// Place la fin du passage (touche O) à la tête de lecture ou au temps donné.
    func setTrimEnd(at time: Double? = nil) {
        guard media != nil else { return }
        let end = time ?? currentTime
        guard end >= trimRange.start + Self.minimumTrimDuration else {
            return showNotice("La fin doit se trouver après le début du passage.")
        }
        changeTrim(to: TimeRange(trimRange.start, end))
    }

    /// Garde de nouveau toute la vidéo.
    func resetTrim() {
        guard media != nil else { return }
        changeTrim(to: TimeRange(0, duration))
    }

    private func changeTrim(to range: TimeRange) {
        let range = validTrim(range)
        guard range != trimRange else { return }
        pushUndo(snapshot())
        trimRange = range
        applyPlaybackBounds()
    }

    private func validTrim(_ range: TimeRange) -> TimeRange {
        let start = min(max(range.start, 0), max(0, duration - Self.minimumTrimDuration))
        let end = min(max(range.end, start + Self.minimumTrimDuration), duration)
        return TimeRange(start, end)
    }

    /// Faux si un champ de texte ou une feuille (ex. panneau d'enregistrement) a la main.
    private var handlesEditCommands: Bool {
        guard let window, window.attachedSheet == nil else { return false }
        if let keyWindow = NSApp.keyWindow, keyWindow !== window { return false }
        if let text = window.firstResponder as? NSText, text.isEditable { return false }
        return true
    }

    // MARK: - Zoom

    func zoomIn() { zoomLevel = min(1, zoomLevel + 0.1) }
    func zoomOut() { zoomLevel = max(0, zoomLevel - 0.1) }
    func zoomToFit() { zoomLevel = 0 }

    // MARK: - Export

    func showExportSheet() {
        guard media != nil, exportDuration > 0, !isExporting else { return }
        if isCropping { finishCropping() }
        if isBlurring { finishBlurring() }
        isExportSheetPresented = true
    }

    /// Appelé par la feuille de réglages : le panneau d'enregistrement s'ouvre une fois la feuille fermée.
    func confirmExportSettings(_ settings: ExportSettings) {
        exportSettings = settings
        settings.save()
        pendingExportSettings = settings
        isExportSheetPresented = false
    }

    func exportSheetDidDismiss() {
        guard let settings = pendingExportSettings else { return }
        pendingExportSettings = nil
        presentSavePanel(settings: settings)
    }

    private func presentSavePanel(settings: ExportSettings) {
        guard let media else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = media.url.deletingLastPathComponent()
        let baseName = media.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName) (montage).\(settings.format.fileExtension)"
        panel.message = "Exporter en \(settings.format.title)"
        panel.prompt = "Exporter"

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.startExport(to: url, settings: settings) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func startExport(to url: URL, settings: ExportSettings) {
        guard let media else { return }
        if url.standardizedFileURL.resolvingSymlinksInPath() == media.url.standardizedFileURL.resolvingSymlinksInPath() {
            errorMessage = "Impossible d'écraser la vidéo d'origine pendant son édition. Choisissez un autre nom."
            return
        }
        let exportedEdits = exportEdits
        let exportedCrop = crop
        let exportedBlurs = blurs
        let exporter = VideoExporter(media: media, segments: exportedEdits.segments, settings: settings,
                                     crop: exportedCrop.isFull ? nil : exportedCrop, blurs: exportedBlurs,
                                     outputURL: url)
        let job = ExportJob(outputURL: url, settings: settings, duration: exportedEdits.duration)
        job.start(exporter: exporter) { [weak self] success in
            guard success else { return }
            self?.savedEdits = exportedEdits
            self?.savedCrop = exportedCrop
            self?.savedBlurs = exportedBlurs
        }
        exportJob = job
    }

    // MARK: - Messages

    func showNotice(_ message: String, beep: Bool = true) {
        if beep { NSSound.beep() }
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Rendu des flous partagé entre le modèle (thread principal) et le filtre de l'aperçu (autre thread).
private final class PreviewEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var current = FrameRenderer(blurs: [], timeMap: SourceTimeMap(segments: []))

    var renderer: FrameRenderer {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
