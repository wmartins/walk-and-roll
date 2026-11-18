import AVFoundation
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class RecordingPreview {
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private let source: URL
    @ObservationIgnored private let camera: CameraOverlay?
    @ObservationIgnored private let clicks: [ClickHighlight]
    @ObservationIgnored private let keystrokes: [KeystrokeBadge]
    @ObservationIgnored private let keystrokeDelay: Double
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var playbackObserver: NSKeyValueObservation?
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var seeking = false
    private(set) var duration = 0.0
    private(set) var time = 0.0
    private(set) var isPlaying = false
    private(set) var isPreparing = true
    private(set) var error: String?
    private(set) var canvas = CGSize(width: 16, height: 9)
    private(set) var contentRect = CGRect.zero
    var edits = RecordingEdits() { didSet { rebuild() } }
    var resolution: RecordingResolution { didSet { rebuild() } }
    var includesCamera = true { didSet { rebuild() } }
    var selectedZoomID: UUID?
    var addingZoom = false
    var hasCamera: Bool { camera != nil }
    var selectedZoom: ZoomEffect? { edits.zooms.first { $0.id == selectedZoomID } }

    init(source: URL, camera: CameraOverlay?, clicks: [ClickHighlight], keystrokes: [KeystrokeBadge],
         keystrokeDelay: Double, resolution: RecordingResolution) {
        self.source = source
        self.camera = camera
        self.clicks = clicks
        self.keystrokes = keystrokes
        self.keystrokeDelay = keystrokeDelay
        self.resolution = resolution
        player.actionAtItemEnd = .pause
        playbackObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor [weak self] in self?.isPlaying = playing }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.seeking else { return }
                let current = self.player.currentTime().seconds
                if current.isFinite { self.time = min(self.duration, max(0, current)) }
                self.isPlaying = self.player.rate != 0
            }
        }
        rebuild()
    }

    func rebuild() {
        buildTask?.cancel()
        player.pause()
        isPlaying = false
        isPreparing = true
        error = nil
        let snapshot = edits
        let outputResolution = resolution
        let overlay = includesCamera ? camera : nil
        buildTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Coalesce slider changes without publishing a stale composition.
                try await Task.sleep(for: .milliseconds(100))
                let prepared = try await MP4Export.prepare(
                    source, camera: overlay, clicks: clicks, keystrokes: keystrokes,
                    keystrokeDelay: keystrokeDelay, resolution: outputResolution, edits: snapshot
                )
                try Task.checkCancellation()
                duration = prepared.duration.seconds
                canvas = prepared.video.renderSize
                contentRect = prepared.contentRect
                let item = prepared.playerItem()
                statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let detail = item.error?.localizedDescription ?? "The video couldn’t be played."
                    Task { @MainActor [weak self] in self?.error = detail }
                }
                player.replaceCurrentItem(with: item)
                isPreparing = false
                seek(to: time)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Preview couldn’t load. \(error.localizedDescription)"
                isPreparing = false
            }
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        pause()
        time = min(max(0, duration - 1 / 30), max(0, (seconds * 30).rounded() / 30))
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.seeking = false
            }
        }
    }

    func togglePlayback() {
        guard !isPreparing, error == nil else { return }
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            addingZoom = false
            if time >= duration - 1 / 30 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    func addZoom(at point: CGPoint) {
        guard addingZoom, !isPreparing, error == nil,
              let focal = RecordingGeometry.sourcePoint(at: point, content: contentRect, canvas: canvas,
                                                       zoom: edits.zoom(at: time), seconds: time),
              duration - time >= 1 / 30 else { return }
        player.pause()
        isPlaying = false
        let zoom = ZoomEffect(start: time, duration: min(3, duration - time), focalPoint: focal)
        edits.zooms.append(zoom)
        selectedZoomID = zoom.id
        addingZoom = false
    }

    func selectZoom(_ id: UUID?) {
        selectedZoomID = id
        addingZoom = false
        if let zoom = selectedZoom { seek(to: zoom.start) }
    }

    func updateSelected(duration: Double? = nil, magnification: Double? = nil) {
        guard let index = edits.zooms.firstIndex(where: { $0.id == selectedZoomID }) else { return }
        var updated = edits
        if let duration {
            updated.zooms[index].duration = min(self.duration - updated.zooms[index].start, max(1 / 30, duration))
        }
        if let magnification { updated.zooms[index].magnification = min(4, max(1.1, magnification)) }
        edits = updated
    }

    func removeSelected() {
        edits.zooms.removeAll { $0.id == selectedZoomID }
        selectedZoomID = nil
    }

    func close() {
        buildTask?.cancel()
        buildTask = nil
        player.pause()
        statusObserver = nil
        playbackObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

struct RecordingPreviewView: View {
    @Bindable var preview: RecordingPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview & effects").font(.headline)
            GeometryReader { geometry in
                let fit = RecordingGeometry.fittedRect(source: preview.canvas, canvas: geometry.size)
                ZStack {
                    Color.black
                    PreviewPlayer(player: preview.player)
                        .frame(width: fit.width, height: fit.height)
                        .overlay {
                            if preview.addingZoom {
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active: NSCursor.crosshair.set()
                                        case .ended: NSCursor.arrow.set()
                                        }
                                    }
                                    .gesture(SpatialTapGesture().onEnded { event in
                                        preview.addZoom(at: CGPoint(x: event.location.x / fit.width, y: event.location.y / fit.height))
                                        NSCursor.arrow.set()
                                    })
                            }
                        }
                    if preview.isPreparing { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(height: 300)
            .accessibilityLabel("Recording preview")
            HStack {
                Button { preview.togglePlayback() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
                Slider(value: Binding(get: { preview.time }, set: { preview.seek(to: $0) }),
                       in: 0...max(1 / 30, preview.duration))
                    .accessibilityLabel("Preview position in seconds")
                Text("\(preview.time.formatted(.number.precision(.fractionLength(1)))) / \(preview.duration.formatted(.number.precision(.fractionLength(1)))) s")
                    .monospacedDigit().font(.caption)
            }
            .disabled(preview.isPreparing || preview.error != nil)
            if let error = preview.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Retry Preview") { preview.rebuild() }
                    if preview.hasCamera && preview.includesCamera {
                        Button("Preview Without Camera") { preview.includesCamera = false }
                    }
                }
            }
            HStack {
                Button(preview.addingZoom ? "Cancel Add Zoom" : "Add Zoom at Playhead") {
                    preview.seek(to: preview.time)
                    preview.addingZoom.toggle()
                }
                .disabled(preview.isPreparing || preview.error != nil || preview.duration - preview.time < 1 / 30)
                Text(preview.addingZoom ? "Click a focal point in the footage." : "Seek, then add a zoom and click its focal point.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !preview.edits.zooms.isEmpty {
                Picker("Zoom", selection: Binding(get: { preview.selectedZoomID }, set: { preview.selectZoom($0) })) {
                    Text("Select a zoom").tag(nil as UUID?)
                    ForEach(preview.edits.zooms.sorted { $0.start < $1.start }) { zoom in
                        Text("\(zoom.start.formatted(.number.precision(.fractionLength(1)))) s · \(zoom.duration.formatted(.number.precision(.fractionLength(1)))) s · \(zoom.magnification.formatted(.number.precision(.fractionLength(1))))×")
                            .tag(Optional(zoom.id))
                    }
                }
            }
            if let zoom = preview.selectedZoom {
                HStack {
                    Text("Duration")
                    Slider(value: Binding(get: { preview.selectedZoom?.duration ?? 1 }, set: { preview.updateSelected(duration: $0) }),
                           in: (1 / 30)...max(1 / 30, preview.duration - zoom.start))
                        .accessibilityLabel("Zoom duration in seconds")
                    Text("\(zoom.duration.formatted(.number.precision(.fractionLength(1)))) s").monospacedDigit()
                    Button("Remove Zoom", role: .destructive) { preview.removeSelected() }
                }
                HStack {
                    Text("Magnification")
                    Slider(value: Binding(get: { preview.selectedZoom?.magnification ?? 2 }, set: { preview.updateSelected(magnification: $0) }), in: 1.1...4)
                        .accessibilityLabel("Zoom magnification")
                    Text("\(zoom.magnification.formatted(.number.precision(.fractionLength(1))))×").monospacedDigit()
                }
                Text("Zooms ease in and out. A later zoom shortens the earlier zoom, including its ease-out. At the same time, the newest zoom wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Blurred backdrop (16:9 frame)", isOn: $preview.edits.blurredBackdrop)
            Picker("Export resolution", selection: $preview.resolution) {
                ForEach(RecordingResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            if preview.hasCamera {
                Toggle("Include recorded camera", isOn: $preview.includesCamera)
            }
            Text("Original media stays available until you discard the recording or quit the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PreviewPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PreviewPlayerView { PreviewPlayerView(player: player) }
    func updateNSView(_ view: PreviewPlayerView, context: Context) {}
}

private final class PreviewPlayerView: NSView {
    private let video = AVPlayerLayer()
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        video.player = player
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = bounds
        CATransaction.commit()
    }
}
