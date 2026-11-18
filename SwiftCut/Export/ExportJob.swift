import AppKit
import Observation

/// Une exportation en cours ou terminée, observée par la feuille de progression.
@MainActor
@Observable
final class ExportJob: Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let outputURL: URL
    let settings: ExportSettings
    /// Durée de la vidéo exportée (secondes).
    let duration: Double
    private(set) var state: State = .running
    private(set) var progress: Double = 0
    private(set) var startDate = Date()
    private(set) var endDate: Date?
    private(set) var fileSize: Int64?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var exporter: VideoExporter?

    init(outputURL: URL, settings: ExportSettings, duration: Double) {
        self.outputURL = outputURL
        self.settings = settings
        self.duration = duration
    }

    var isRunning: Bool { state == .running }

    /// Temps restant estimé (secondes), une fois la progression significative.
    func remainingTime(now: Date = Date()) -> TimeInterval? {
        guard state == .running, progress > 0.03 else { return nil }
        let elapsed = now.timeIntervalSince(startDate)
        return elapsed * (1 - progress) / progress
    }

    func start(exporter: VideoExporter, completion: @escaping @MainActor (Bool) -> Void) {
        self.exporter = exporter
        startDate = Date()
        let throttle = ProgressThrottle { [weak self] value in
            Task { @MainActor in
                guard let self, self.state == .running else { return }
                self.progress = max(self.progress, value)
            }
        }
        task = Task { [weak self] in
            do {
                try await exporter.run { throttle.report($0) }
                guard let self else { return }
                self.progress = 1
                self.fileSize = (try? self.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                self.endDate = Date()
                self.state = .finished
                completion(true)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            } catch is CancellationError {
                self?.state = .cancelled
                completion(false)
            } catch {
                self?.state = .failed(error.localizedDescription)
                completion(false)
                if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
            }
        }
    }

    func cancel() {
        exporter?.cancel()
        task?.cancel()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func openFile() {
        NSWorkspace.shared.open(outputURL)
    }
}

/// Limite la fréquence des mises à jour de progression envoyées à l'interface.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue = -1.0
    private var lastTime: CFAbsoluteTime = 0
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ value: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let shouldSend = lock.withLock { () -> Bool in
            guard value - lastValue >= 0.004 || now - lastTime > 0.25 || value >= 1 else { return false }
            lastValue = value
            lastTime = now
            return true
        }
        if shouldSend { handler(value) }
    }
}
