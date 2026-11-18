import AVFoundation
@preconcurrency import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message), .failed(let message): message
        }
    }
}

/// Exporte la vidéo montée vers un fichier. Toutes les méthodes peuvent être appelées hors du thread principal.
final class VideoExporter: @unchecked Sendable {
    let media: MediaInfo
    let segments: [Segment]
    let settings: ExportSettings
    /// Zone de l'image à garder (`nil` = toute l'image).
    let crop: CropRect?
    /// Zones floutées (coordonnées de l'image entière, durées en temps source).
    let blurs: [BlurRegion]
    let outputURL: URL

    private let lock = NSLock()
    private var cancelled = false
    private var failed = false

    init(media: MediaInfo, segments: [Segment], settings: ExportSettings,
         crop: CropRect? = nil, blurs: [BlurRegion] = [], outputURL: URL) {
        self.media = media
        self.segments = segments
        self.settings = settings
        self.crop = crop
        self.blurs = blurs
        self.outputURL = outputURL
    }

    /// Zone gardée, en pixels de l'image affichée.
    private var cropArea: CGRect { (crop ?? .full).pixelRect(in: media.displaySize) }

    var isCancelled: Bool { lock.withLock { cancelled } }
    private var hasFailed: Bool { lock.withLock { failed } }

    func cancel() { lock.withLock { cancelled = true } }
    private func markFailed() { lock.withLock { failed = true } }

    /// Lance l'export. `progress` reçoit une valeur entre 0 et 1, depuis n'importe quel thread.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        do {
            try await withTaskCancellationHandler {
                switch settings.format {
                case .m4a:
                    try await exportAudioOnly(progress: progress)
                case .gif:
                    try await exportGIF(progress: progress)
                case .mp4, .mov:
                    if settings.isPassthrough {
                        try await exportPassthrough(progress: progress)
                    } else {
                        try await transcode(progress: progress)
                    }
                }
            } onCancel: {
                self.cancel()
            }
            if isCancelled { throw CancellationError() }
            progress(1)
        } catch {
            removePartialOutput()
            throw error
        }
    }

    /// Supprime le fichier partiel et les fichiers temporaires laissés par AVAssetWriter (« nom.sb-… »).
    private func removePartialOutput() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        let directory = outputURL.deletingLastPathComponent()
        let prefix = outputURL.lastPathComponent + ".sb-"
        let items = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for item in items where item.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(item))
        }
    }

    // MARK: - Copie sans réencodage / audio seul

    private func exportPassthrough(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard crop == nil, blurs.isEmpty else {
            throw ExportError.unsupported("Le recadrage et les flous nécessitent un réencodage : choisissez H.264, HEVC ou ProRes.")
        }
        let built = try CompositionBuilder.make(media: media, segments: segments,
                                                includeAudio: settings.includeAudio)
        try await runExportSession(asset: built.composition,
                                   preset: AVAssetExportPresetPassthrough,
                                   fileType: settings.format.fileType,
                                   progress: progress)
    }

    private func exportAudioOnly(progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try CompositionBuilder.make(media: media, segments: segments,
                                                includeVideo: false, includeAudio: true)
        guard !built.audioTracks.isEmpty else {
            throw ExportError.unsupported("Cette vidéo ne contient pas de piste audio.")
        }
        try await runExportSession(asset: built.composition,
                                   preset: AVAssetExportPresetAppleM4A,
                                   fileType: .m4a,
                                   progress: progress)
    }

    private func runExportSession(asset: AVAsset, preset: String, fileType: AVFileType,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.failed("Impossible de préparer l'export.")
        }
        let compatibleTypes = await session.compatibleFileTypes
        guard compatibleTypes.contains(fileType) else {
            throw ExportError.unsupported(
                "Le flux d'origine ne peut pas être copié tel quel dans ce format. Choisissez un réencodage (H.264 par exemple).")
        }
        session.shouldOptimizeForNetworkUse = true

        let monitor = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: outputURL, as: fileType)
    }

    // MARK: - Réencodage (H.264, HEVC, ProRes)

    private func transcode(progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try CompositionBuilder.make(media: media, segments: segments,
                                                includeAudio: settings.includeAudio)
        guard let videoTrack = built.videoTrack else {
            throw ExportError.failed("Aucune piste vidéo à exporter.")
        }
        let composition = built.composition
        let duration = composition.duration.seconds

        let size = settings.outputSize(for: cropArea.size)
        let fps = settings.frameRate.map { min(Double($0), media.maxFrameRate) } ?? media.maxFrameRate
        // Chemin rapide : pas de redimensionnement, pas de rotation, cadence d'origine.
        let usesCompositor = crop != nil || !blurs.isEmpty
            || size != media.displaySize
            || media.preferredTransform != .identity
            || (settings.frameRate != nil && Double(settings.frameRate!) < media.maxFrameRate - 0.5)

        // Écriture
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.fileType)
        writer.shouldOptimizeForNetworkUse = true

        var videoSettings = settings.videoOutputSettings(size: size, fps: fps)
        if usesCompositor {
            videoSettings[AVVideoColorPropertiesKey] = Self.rec709
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ExportError.unsupported("Ces réglages vidéo ne sont pas pris en charge par l'encodeur de ce Mac.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if settings.includeAudio, !built.audioTracks.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ExportSettings.audioOutputSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        // Lecture
        let reader = try AVAssetReader(asset: composition)
        let videoOutput: AVAssetReaderOutput
        if usesCompositor {
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = try await makeVideoComposition(composition: composition, track: videoTrack,
                                                                     renderSize: size, fps: fps)
            videoOutput = output
        } else {
            videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        }
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool)] = [
            (videoOutput, videoInput, true)
        ]
        if let audioInput {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: built.audioTracks,
                                                          audioSettings: ExportSettings.pcmReadSettings)
            audioOutput.alwaysCopiesSampleData = false
            reader.add(audioOutput)
            pairs.append((audioOutput, audioInput, false))
        }

        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed("Impossible de créer le fichier.")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? ExportError.failed("Impossible de lire la vidéo source.")
        }
        writer.startSession(atSourceTime: .zero)

        await pump(reader: reader, writer: writer, pairs: pairs, duration: duration, progress: progress)

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if hasFailed || reader.status == .failed || writer.status == .failed {
            let error = writer.error ?? reader.error
            reader.cancelReading()
            writer.cancelWriting()
            throw error ?? ExportError.failed("L'encodage a échoué.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.failed("Impossible de finaliser le fichier.")
        }
    }

    /// Transfère les échantillons de chaque sortie du lecteur vers l'entrée correspondante de l'écriture.
    private func pump(reader: AVAssetReader,
                      writer: AVAssetWriter,
                      pairs: [(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool)],
                      duration: Double,
                      progress: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let coordinator = PumpCoordinator(count: pairs.count) { continuation.resume() }
            for (index, pair) in pairs.enumerated() {
                let queue = DispatchQueue(label: "SwiftCut.export.\(index)", qos: .userInitiated)
                let channel = Channel(reader: reader, writer: writer, output: pair.output, input: pair.input)
                let reportsProgress = pair.reportsProgress
                pair.input.requestMediaDataWhenReady(on: queue) { [self] in
                    // Une autre piste a échoué : on clôt celle-ci pour que l'écriture cesse de la solliciter.
                    if coordinator.isFinished(index) {
                        channel.close()
                        return
                    }
                    let reader = channel.reader, output = channel.output, input = channel.input
                    while input.isReadyForMoreMediaData {
                        if isCancelled || hasFailed {
                            channel.close()
                            coordinator.finish(index)
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            channel.close()
                            if reader.status == .failed {
                                markFailed()
                                coordinator.finishAll()
                            } else {
                                coordinator.finish(index)
                            }
                            return
                        }
                        if reportsProgress, duration > 0 {
                            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            if time.isFinite { progress(min(max(time / duration, 0), 1)) }
                        }
                        if !input.append(sample) {
                            markFailed()
                            channel.close()
                            coordinator.finishAll()
                            return
                        }
                    }
                }
            }
        }
    }

    // MARK: - GIF animé

    private func exportGIF(progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try CompositionBuilder.make(media: media, segments: segments, includeAudio: false)
        guard let videoTrack = built.videoTrack else {
            throw ExportError.failed("Aucune piste vidéo à exporter.")
        }
        let composition = built.composition
        let duration = composition.duration.seconds
        let size = settings.outputSize(for: cropArea.size)
        let fps = Double(settings.gifFrameRate)

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await makeVideoComposition(composition: composition, track: videoTrack,
                                                                 renderSize: size, fps: fps)
        reader.add(output)

        let frameCount = max(1, Int((duration * fps).rounded(.up))) + 2
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                                UTType.gif.identifier as CFString,
                                                                frameCount, nil) else {
            throw ExportError.failed("Impossible de créer le fichier GIF.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        guard reader.startReading() else {
            throw reader.error ?? ExportError.failed("Impossible de lire la vidéo source.")
        }

        // Travail bloquant : on le sort du pool de threads de Swift Concurrency.
        let channel = GIFChannel(reader: reader, output: output, destination: destination)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let reader = channel.reader, output = channel.output, destination = channel.destination
                // La composition ne duplique pas les images identiques (écran immobile) :
                // chaque image dure jusqu'à l'horodatage de la suivante.
                var pending: (image: CGImage, time: Double)?
                var writtenCentiseconds = 0
                var count = 0
                func add(_ image: CGImage, until end: Double) {
                    let delay = max(2, Int((end * 100).rounded()) - writtenCentiseconds)
                    writtenCentiseconds += delay
                    let seconds = Double(delay) / 100
                    CGImageDestinationAddImage(destination, image, [
                        kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFDelayTime: seconds,
                            kCGImagePropertyGIFUnclampedDelayTime: seconds,
                        ],
                    ] as CFDictionary)
                    count += 1
                }
                while let sample = output.copyNextSampleBuffer() {
                    if isCancelled {
                        reader.cancelReading()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    autoreleasepool {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard time.isFinite, let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                              let image = Self.makeImage(from: pixelBuffer) else { return }
                        if let previous = pending { add(previous.image, until: time) }
                        pending = (image, time)
                        progress(min(0.95, time / max(duration, 0.001) * 0.95))
                    }
                }
                if reader.status == .failed {
                    continuation.resume(throwing: reader.error ?? ExportError.failed("Lecture interrompue."))
                    return
                }
                if let last = pending { add(last.image, until: duration) }
                guard count > 0, CGImageDestinationFinalize(destination) else {
                    continuation.resume(throwing: ExportError.failed("Impossible d'écrire le GIF."))
                    return
                }
                continuation.resume()
            }
        }
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Composition vidéo (redimensionnement, rotation, cadence)

    private static let rec709: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    private func makeVideoComposition(composition: AVComposition, track: AVMutableCompositionTrack,
                                      renderSize: CGSize, fps: Double) async throws -> AVVideoComposition {
        if !blurs.isEmpty {
            return try await makeFilteredComposition(composition: composition, renderSize: renderSize, fps: fps)
        }
        let duration = composition.duration
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(seconds: 1 / max(fps, 1),
                                                preferredTimescale: CompositionBuilder.timescale)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // Orientation d'origine, puis origine ramenée au coin de la zone gardée, puis mise à l'échelle.
        let oriented = CGRect(origin: .zero, size: media.naturalSize).applying(media.preferredTransform)
        let area = cropArea
        let transform = media.preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX - area.minX, y: -oriented.minY - area.minY))
            .concatenating(CGAffineTransform(scaleX: renderSize.width / area.width,
                                             y: renderSize.height / area.height))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    /// Avec des flous : chaque image passe par Core Image (flous, recadrage, mise à l'échelle),
    /// avec le même rendu que l'aperçu.
    private func makeFilteredComposition(composition: AVComposition, renderSize: CGSize,
                                         fps: Double) async throws -> AVVideoComposition {
        let renderer = FrameRenderer(blurs: blurs, timeMap: SourceTimeMap(segments: segments), crop: crop ?? .full)
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            with: composition,
            applyingCIFiltersWithHandler: { request in
                request.finish(with: renderer.render(request.sourceImage, compositionTime: request.compositionTime,
                                                     renderSize: request.renderSize),
                               context: nil)
            })
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(seconds: 1 / max(fps, 1), preferredTimescale: CompositionBuilder.timescale)
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return videoComposition
    }
}

/// Une piste à transférer. Utilisée depuis une seule file à la fois.
private final class Channel: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    private var isClosed = false

    init(reader: AVAssetReader, writer: AVAssetWriter, output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.writer = writer
        self.output = output
        self.input = input
    }

    /// Marque l'entrée comme terminée (une seule fois) : sans cela, l'écriture la solliciterait sans fin.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        if writer.status == .writing {
            input.markAsFinished()
        }
    }
}

private final class GIFChannel: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let destination: CGImageDestination

    init(reader: AVAssetReader, output: AVAssetReaderOutput, destination: CGImageDestination) {
        self.reader = reader
        self.output = output
        self.destination = destination
    }
}

/// Attend la fin de toutes les pompes (ou l'arrêt anticipé en cas d'erreur).
private final class PumpCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<Int>
    private var completion: (() -> Void)?

    init(count: Int, completion: @escaping () -> Void) {
        remaining = Set(0..<count)
        self.completion = completion
    }

    func isFinished(_ index: Int) -> Bool {
        lock.withLock { !remaining.contains(index) }
    }

    func finish(_ index: Int) {
        let done: (() -> Void)? = lock.withLock {
            remaining.remove(index)
            guard remaining.isEmpty, let completion else { return nil }
            self.completion = nil
            return completion
        }
        done?()
    }

    func finishAll() {
        let done: (() -> Void)? = lock.withLock {
            remaining.removeAll()
            let completion = self.completion
            self.completion = nil
            return completion
        }
        done?()
    }
}
