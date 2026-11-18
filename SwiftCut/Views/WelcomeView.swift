import SwiftUI

/// Écran d'accueil : zone de dépôt et bouton d'ouverture.
struct WelcomeView: View {
    @Environment(EditorModel.self) private var editor
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.brand.opacity(isDropTargeted ? 0.25 : 0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "film.stack")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: 8) {
                Text(isDropTargeted ? "Déposez pour ouvrir" : "Glissez une vidéo ici")
                    .font(.system(size: 22, weight: .semibold))
                Text("Enregistrement d'écran, clip MOV ou MP4… Coupez les passages inutiles puis exportez dans le format de votre choix.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button {
                editor.presentOpenPanel()
            } label: {
                Label("Choisir une vidéo…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("MOV · MP4 · M4V — ou glissez un fichier sur l'icône de l'app")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.brand : Color.secondary.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isDropTargeted ? Color.brand.opacity(0.06) : Color.clear)
                )
                .padding(24)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }
}
