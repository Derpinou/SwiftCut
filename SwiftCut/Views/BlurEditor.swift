import SwiftUI

/// Outil Flouter : on dessine des rectangles sur la vidéo, on les déplace et les redimensionne.
struct BlurOverlay: View {
    @Environment(EditorModel.self) private var editor
    @State private var drawingID: BlurRegion.ID?
    @State private var dragOrigin: CropRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                // Fond : glisser dessine une nouvelle zone, un simple clic désélectionne.
                Color.clear
                    .contentShape(Rectangle())
                    .pointerStyle(.rectSelection)
                    .gesture(drawGesture(in: size))

                ForEach(editor.blurs) { blur in
                    let rect = viewRect(blur.rect, in: size)
                    BlurOutline(blur: blur,
                                isSelected: blur.id == editor.selectedBlurID,
                                isVisibleNow: editor.isBlurVisibleNow(blur))
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .pointerStyle(dragOrigin == nil ? .grabIdle : .grabActive)
                        .gesture(dragGesture(blur.id, handle: .move, in: size))
                        .position(x: rect.midX, y: rect.midY)
                }

                if let selected = editor.selectedBlur {
                    grips(for: selected, in: size)
                }
            }
        }
    }

    // MARK: - Poignées de la zone sélectionnée

    @ViewBuilder
    private func grips(for blur: BlurRegion, in size: CGSize) -> some View {
        let rect = viewRect(blur.rect, in: size)
        let corners: [(CropRect.Handle, CGPoint, FrameResizePosition)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY), .topLeading),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY), .topTrailing),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY), .bottomLeading),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY), .bottomTrailing),
        ]
        let edges: [(CropRect.Handle, CGPoint, CGSize, FrameResizePosition)] = [
            (.top, CGPoint(x: rect.midX, y: rect.minY), CGSize(width: max(0, rect.width - 24), height: 14), .top),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY), CGSize(width: max(0, rect.width - 24), height: 14), .bottom),
            (.left, CGPoint(x: rect.minX, y: rect.midY), CGSize(width: 14, height: max(0, rect.height - 24)), .leading),
            (.right, CGPoint(x: rect.maxX, y: rect.midY), CGSize(width: 14, height: max(0, rect.height - 24)), .trailing),
        ]
        ForEach(edges, id: \.0) { handle, point, gripSize, position in
            Color.clear
                .frame(width: gripSize.width, height: gripSize.height)
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: position))
                .gesture(dragGesture(blur.id, handle: handle, in: size))
                .position(point)
        }
        ForEach(corners, id: \.0) { handle, point, position in
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.brand, lineWidth: 2))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: position))
                .gesture(dragGesture(blur.id, handle: handle, in: size))
                .position(point)
        }
    }

    // MARK: - Gestes

    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let rect = normalizedRect(from: value.startLocation, to: value.location, in: size)
                if let drawingID {
                    editor.updateBlurRect(drawingID, to: rect)
                } else if hypot(value.translation.width, value.translation.height) > 4 {
                    editor.beginBlurGesture()
                    drawingID = editor.insertBlur(rect)
                }
            }
            .onEnded { _ in
                guard let id = drawingID else {
                    editor.selectedBlurID = nil
                    return
                }
                if let blur = editor.blurs.first(where: { $0.id == id }),
                   blur.rect.width < BlurRegion.minimumSide || blur.rect.height < BlurRegion.minimumSide {
                    editor.discardBlur(id)
                }
                editor.endBlurGesture()
                drawingID = nil
            }
    }

    private func dragGesture(_ id: BlurRegion.ID, handle: CropRect.Handle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    guard let blur = editor.blurs.first(where: { $0.id == id }) else { return }
                    editor.selectedBlurID = id
                    dragOrigin = blur.rect
                    editor.beginBlurGesture()
                }
                guard let origin = dragOrigin, size.width > 0, size.height > 0 else { return }
                let delta = CGSize(width: value.translation.width / size.width,
                                   height: value.translation.height / size.height)
                editor.updateBlurRect(id, to: origin.dragging(handle, by: delta, ratio: nil,
                                                              minimumSide: BlurRegion.minimumSide))
            }
            .onEnded { _ in
                dragOrigin = nil
                editor.endBlurGesture()
            }
    }

    // MARK: - Coordonnées

    private func viewRect(_ rect: CropRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CropRect {
        guard size.width > 0, size.height > 0 else { return .full }
        let x0 = min(max(min(start.x, end.x) / size.width, 0), 1)
        let x1 = min(max(max(start.x, end.x) / size.width, 0), 1)
        let y0 = min(max(min(start.y, end.y) / size.height, 0), 1)
        let y1 = min(max(max(start.y, end.y) / size.height, 0), 1)
        return CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Contour d'une zone : pointillés si elle n'est pas affichée à cet instant.
private struct BlurOutline: View {
    let blur: BlurRegion
    let isSelected: Bool
    let isVisibleNow: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(isSelected ? Color.brand : Color.white.opacity(isVisibleNow ? 0.9 : 0.5),
                          style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: isVisibleNow ? [] : [5, 4]))
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(isVisibleNow ? 0.02 : 0.08)))
            .overlay(alignment: .topLeading) {
                Label(blur.style.title, systemImage: blur.style == .blur ? "drop.fill" : "square.grid.3x3.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? Color.brand : Color.black.opacity(0.6)))
                    .foregroundStyle(isSelected ? Color.black : Color.white)
                    .padding(4)
                    .fixedSize()
            }
    }
}

/// Barre affichée sous la vidéo pendant l'édition des flous.
struct BlurBar: View {
    @Environment(EditorModel.self) private var editor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Color.brand)
            if let blur = editor.selectedBlur {
                Picker("Style", selection: Binding(get: { blur.style }, set: { editor.setSelectedBlurStyle($0) })) {
                    ForEach(BlurRegion.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                HStack(spacing: 6) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { blur.intensity }, set: { editor.setSelectedBlurIntensity($0) }),
                           in: 0.2...1) { editing in
                        editing ? editor.beginBlurGesture() : editor.endBlurGesture()
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                }
                .help("Intensité")

                Divider().frame(height: 18)

                Label(editor.rangeDescription(for: blur), systemImage: "clock")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Début ici") { editor.setSelectedBlurStart() }
                    .help("La zone apparaît à partir de la tête de lecture")
                Button("Fin ici") { editor.setSelectedBlurEnd() }
                    .help("La zone disparaît à la tête de lecture")
                Button {
                    editor.clearSelectedBlurRange()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(blur.sourceRange == nil)
                .help("Afficher la zone pendant toute la vidéo")
                Button {
                    editor.deleteSelectedBlur()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Supprimer la zone (⌫)")
            } else {
                Text(editor.blurs.isEmpty
                     ? "Dessinez un rectangle sur la vidéo pour flouter une zone (mot de passe, e-mail, visage…)"
                     : "Cliquez une zone pour la régler, ou dessinez-en une nouvelle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Terminé") { editor.finishBlurring() }
                .buttonStyle(.borderedProminent)
                .help("Fermer l'outil (Entrée)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}
