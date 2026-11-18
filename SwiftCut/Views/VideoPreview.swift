import SwiftUI

/// Aperçu vidéo : montre la zone recadrée (avec les flous), ou toute l'image pendant le recadrage et les flous.
struct VideoPreview: View {
    @Environment(EditorModel.self) private var editor
    let media: MediaInfo

    var body: some View {
        // Pendant le recadrage ou les flous, on montre toute l'image ; sinon seulement la zone gardée.
        let visible = editor.isCropping || editor.isBlurring ? CropRect.full : editor.crop
        let aspect = media.aspectRatio * visible.width / visible.height
        GeometryReader { geometry in
            // La vidéo entière est agrandie puis décalée pour que la zone gardée remplisse l'aperçu.
            let fullWidth = geometry.size.width / visible.width
            let fullHeight = geometry.size.height / visible.height
            PlayerView(player: editor.player) { editor.togglePlayPause() }
                .frame(width: fullWidth, height: fullHeight)
                .offset(x: -visible.x * fullWidth, y: -visible.y * fullHeight)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        .overlay {
            if editor.isCropping {
                CropOverlay(media: media)
            } else if editor.isBlurring {
                BlurOverlay()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: editor.isCropping || editor.isBlurring)
    }
}

/// Cadre de recadrage façon iPhone : coins épais, grille des tiers, extérieur assombri.
private struct CropOverlay: View {
    @Environment(EditorModel.self) private var editor
    let media: MediaInfo
    @State private var dragOrigin: CropRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let crop = editor.crop
            let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height,
                              width: crop.width * size.width, height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                CropFrame(isDragging: dragOrigin != nil, margin: CropFrame.margin)
                    .frame(width: rect.width + CropFrame.margin * 2, height: rect.height + CropFrame.margin * 2)
                    .offset(x: rect.minX - CropFrame.margin, y: rect.minY - CropFrame.margin)

                // Zones de prise : l'intérieur déplace le cadre, les bords et les coins le redimensionnent.
                grip(.move, in: size)
                    .frame(width: max(0, rect.width - 28), height: max(0, rect.height - 28))
                    .position(x: rect.midX, y: rect.midY)
                grip(.top, in: size)
                    .frame(width: max(0, rect.width - 36), height: 20)
                    .position(x: rect.midX, y: rect.minY)
                grip(.bottom, in: size)
                    .frame(width: max(0, rect.width - 36), height: 20)
                    .position(x: rect.midX, y: rect.maxY)
                grip(.left, in: size)
                    .frame(width: 20, height: max(0, rect.height - 36))
                    .position(x: rect.minX, y: rect.midY)
                grip(.right, in: size)
                    .frame(width: 20, height: max(0, rect.height - 36))
                    .position(x: rect.maxX, y: rect.midY)
                grip(.topLeft, in: size).frame(width: 36, height: 36).position(x: rect.minX, y: rect.minY)
                grip(.topRight, in: size).frame(width: 36, height: 36).position(x: rect.maxX, y: rect.minY)
                grip(.bottomLeft, in: size).frame(width: 36, height: 36).position(x: rect.minX, y: rect.maxY)
                grip(.bottomRight, in: size).frame(width: 36, height: 36).position(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private func grip(_ handle: CropRect.Handle, in size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(pointerStyle(for: handle))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = editor.crop
                            editor.beginCropDrag()
                        }
                        guard let origin = dragOrigin, size.width > 0, size.height > 0 else { return }
                        let delta = CGSize(width: value.translation.width / size.width,
                                           height: value.translation.height / size.height)
                        editor.updateCropDrag(origin.dragging(handle, by: delta, ratio: editor.cropRatio))
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        editor.endCropDrag()
                    }
            )
    }

    private func pointerStyle(for handle: CropRect.Handle) -> PointerStyle {
        switch handle {
        case .move: dragOrigin == nil ? .grabIdle : .grabActive
        case .top: .frameResize(position: .top)
        case .bottom: .frameResize(position: .bottom)
        case .left: .frameResize(position: .leading)
        case .right: .frameResize(position: .trailing)
        case .topLeft: .frameResize(position: .topLeading)
        case .topRight: .frameResize(position: .topTrailing)
        case .bottomLeft: .frameResize(position: .bottomLeading)
        case .bottomRight: .frameResize(position: .bottomTrailing)
        }
    }
}

/// Dessin du cadre (sans interaction). `margin` laisse la place aux coins tracés à l'extérieur.
private struct CropFrame: View {
    static let margin: CGFloat = 6
    let isDragging: Bool
    let margin: CGFloat

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)

            // Grille des tiers, plus visible pendant le geste.
            var grid = Path()
            for step in 1...2 {
                let x = rect.minX + rect.width * CGFloat(step) / 3
                let y = rect.minY + rect.height * CGFloat(step) / 3
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(isDragging ? 0.75 : 0.3)), lineWidth: 0.75)

            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.9)), lineWidth: 1)

            // Coins épais, tracés juste à l'extérieur du cadre.
            let length = min(24, rect.width / 3, rect.height / 3)
            let outer = rect.insetBy(dx: -2, dy: -2)
            var corners = Path()
            for (corner, dx, dy) in [(CGPoint(x: outer.minX, y: outer.minY), 1.0, 1.0),
                                     (CGPoint(x: outer.maxX, y: outer.minY), -1.0, 1.0),
                                     (CGPoint(x: outer.minX, y: outer.maxY), 1.0, -1.0),
                                     (CGPoint(x: outer.maxX, y: outer.maxY), -1.0, -1.0)] {
                corners.move(to: CGPoint(x: corner.x + length * dx, y: corner.y))
                corners.addLine(to: corner)
                corners.addLine(to: CGPoint(x: corner.x, y: corner.y + length * dy))
            }
            context.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .square))
        }
        .allowsHitTesting(false)
    }
}

/// Barre affichée sous la vidéo pendant le recadrage : formats, taille obtenue, validation.
struct CropBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "crop")
                .foregroundStyle(Color.brand)
            HStack(spacing: 4) {
                ForEach(CropAspect.allCases) { aspect in
                    Button(aspect.title) { editor.setCropAspect(aspect) }
                        .buttonStyle(AspectChipStyle(isSelected: editor.cropAspect == aspect))
                }
            }
            Spacer(minLength: 12)
            Text("\(Int(editor.croppedSize.width)) × \(Int(editor.croppedSize.height))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Tout garder") { editor.resetCrop() }
                .disabled(!editor.isCropped)
                .help("Garder toute l'image")
            Button("Annuler") { editor.cancelCropping() }
                .help("Revenir au cadre précédent (Échap)")
            Button("Terminé") { editor.finishCropping() }
                .buttonStyle(.borderedProminent)
                .help("Valider le recadrage (Entrée)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

private struct AspectChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .background(
                Capsule().fill(isSelected ? Color.brand : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .contentShape(Capsule())
    }
}
