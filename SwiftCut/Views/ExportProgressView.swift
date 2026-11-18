import SwiftUI

/// Feuille affichée pendant et après l'exportation.
struct ExportProgressView: View {
    let job: ExportJob
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            icon
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(job.outputURL.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            switch job.state {
            case .running:
                VStack(spacing: 8) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack {
                            Text("\(Int((job.progress * 100).rounded())) %")
                            Spacer()
                            Text(remainingLabel(now: context.date))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Annuler l'export", role: .cancel) { job.cancel() }
                        .keyboardShortcut(.cancelAction)
                }

            case .finished:
                Text(finishedDetails)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Afficher dans le Finder") { job.revealInFinder() }
                    Button("Ouvrir") { job.openFile() }
                    Spacer()
                    Button("Terminé") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }

            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Fermer") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }

            case .cancelled:
                Text("Le fichier partiel a été supprimé.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Fermer") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(job.isRunning)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .running:
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.brand)
                .symbolEffect(.rotate, options: .repeating)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch job.state {
        case .running: "Exportation en \(job.settings.format.title)…"
        case .finished: "Exportation terminée"
        case .failed: "L'exportation a échoué"
        case .cancelled: "Exportation annulée"
        }
    }

    private var finishedDetails: String {
        var parts: [String] = []
        if let size = job.fileSize { parts.append(Fmt.fileSize(size)) }
        parts.append(Fmt.time(job.duration))
        if let end = job.endDate {
            parts.append("exporté en \(Fmt.duration(end.timeIntervalSince(job.startDate)))")
        }
        return parts.joined(separator: " · ")
    }

    private func remainingLabel(now: Date) -> String {
        guard let remaining = job.remainingTime(now: now) else { return "Estimation…" }
        return remaining < 1 ? "Presque fini…" : "Environ \(Fmt.duration(remaining)) restantes"
    }
}
