import SwiftUI

/// Timeline AppKit intégrée dans SwiftUI.
struct TimelinePanel: View {
    @Environment(EditorModel.self) private var editor
    let media: MediaInfo

    var body: some View {
        TimelineRepresentable(
            editor: editor,
            content: TimelineContent(mode: editor.mode,
                                     edits: editor.edits,
                                     trimRange: editor.trimRange,
                                     selection: editor.selection,
                                     selectedSegmentID: editor.selectedSegmentID,
                                     aspectRatio: media.aspectRatio,
                                     hasAudio: media.hasAudio),
            waveform: editor.waveform,
            zoomLevel: editor.zoomLevel,
            playhead: editor.currentTime,
            isPlaying: editor.isPlaying
        )
        .frame(height: TimelineCanvasView.preferredHeight(hasAudio: media.hasAudio, mode: editor.mode))
    }
}

private struct TimelineRepresentable: NSViewRepresentable {
    let editor: EditorModel
    let content: TimelineContent
    let waveform: Waveform?
    let zoomLevel: Double
    let playhead: Double
    let isPlaying: Bool

    func makeNSView(context: Context) -> TimelineCanvasView {
        let view = TimelineCanvasView(frame: .zero)
        let editor = editor
        view.thumbnails = editor.thumbnails
        view.onSeek = { editor.seek(to: $0) }
        view.onScrubBegan = { editor.beginScrubbing() }
        view.onScrubEnded = { editor.endScrubbing() }
        view.onSelectionChange = { editor.setSelection($0) }
        view.onClick = { editor.selectSegment(at: $0) }
        view.onZoomLevelChange = { editor.zoomLevel = $0 }
        view.onSplit = { editor.split(at: $0) }
        view.onDeleteSegment = { editor.deleteSegment(at: $0) }
        view.onDeleteSelection = { editor.deleteSelection() }
        view.onTrimBegan = { editor.beginTrimming() }
        view.onTrimChanged = { editor.updateTrim($0, preview: $1) }
        view.onTrimEnded = { editor.endTrimming() }
        view.onSetTrimStart = { editor.setTrimStart(at: $0) }
        view.onSetTrimEnd = { editor.setTrimEnd(at: $0) }
        view.onResetTrim = { editor.resetTrim() }
        return view
    }

    func updateNSView(_ view: TimelineCanvasView, context: Context) {
        view.update(content: content)
        view.update(waveform: waveform)
        view.update(zoomLevel: zoomLevel)
        view.update(playhead: playhead, isPlaying: isPlaying)
    }
}
