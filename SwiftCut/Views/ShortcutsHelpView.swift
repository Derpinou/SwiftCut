import SwiftUI

/// Aide-mémoire des raccourcis clavier (touche ? ou menu Aide).
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(title: String, items: [(keys: String, label: String)])] = [
        ("Modes", [
            ("⌘1", "Rogner : garder un seul passage, comme sur iPhone"),
            ("⌘2", "Découper : supprimer plusieurs passages"),
        ]),
        ("Lecture", [
            ("Espace", "Lecture / pause"),
            ("J  K  L", "Arrière, pause, avant (appuyer plusieurs fois accélère)"),
            ("←  →", "Image précédente / suivante"),
            ("⇧←  ⇧→", "Reculer / avancer d'une seconde"),
            ("↑  ↓", "Coupe ou bord du passage précédent / suivant"),
            ("Début  Fin  ⌘←  ⌘→", "Aller au début / à la fin (du passage en mode Rogner)"),
        ]),
        ("Rogner", [
            ("Poignées", "Faire glisser pour choisir le passage exporté"),
            ("I  O  ou  ⌥⌘←  ⌥⌘→", "Début / fin du passage à la tête de lecture"),
        ]),
        ("Découper", [
            ("I  O", "Marquer le début / la fin de la sélection"),
            ("⌘B  ou  B", "Scinder à la tête de lecture"),
            ("⌫", "Supprimer la sélection ou le segment sélectionné"),
            ("⌥⌘←  ⌥⌘→", "Supprimer tout avant / après la tête de lecture"),
            ("Échap", "Tout désélectionner"),
        ]),
        ("Recadrer", [
            ("C", "Ouvrir / fermer l'outil Recadrer"),
            ("Coins et bords", "Redimensionner le cadre · glisser à l'intérieur pour le déplacer"),
            ("Entrée  Échap", "Valider / annuler le recadrage"),
        ]),
        ("Flouter", [
            ("F", "Ouvrir / fermer l'outil Flouter"),
            ("Glisser sur la vidéo", "Dessiner une zone à flouter · glisser une zone pour la déplacer"),
            ("⌫  Échap  Entrée", "Supprimer la zone · désélectionner · terminer"),
        ]),
        ("Timeline", [
            ("Glisser", "Rogner : déplacer la tête de lecture · Découper : sélectionner un passage"),
            ("Double-clic", "Découper : sélectionner tout un segment"),
            ("Pincer, ⌘ + molette", "Zoomer"),
            ("⌘=  ⌘-  ⌘0", "Zoom avant / arrière / tout afficher"),
            ("⌘Z  ⇧⌘Z", "Annuler / rétablir"),
        ]),
        ("Fichier", [
            ("⌘O", "Ouvrir une vidéo (ou glisser-déposer)"),
            ("⌘E", "Exporter"),
            ("?", "Afficher cette aide"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Raccourcis clavier")
                .font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(groups, id: \.title) { group in
                    GridRow {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                            .padding(.top, 6)
                    }
                    ForEach(group.items, id: \.label) { item in
                        GridRow {
                            Text(item.keys)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                                .gridColumnAlignment(.trailing)
                            Text(item.label)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
