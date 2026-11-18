import AVFoundation
import AVKit
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
    var edits = RecordingEdits(frameStyle: .windowFrame) {
        didSet {
            if edits.renderingEdits != oldValue.renderingEdits { rebuild() }
        }
    }
    var resolution: RecordingResolution { didSet { rebuild() } }
    var includesCamera = true { didSet { rebuild() } }
    var selectedZoomID: UUID?
    var addingZoom = false
    var hasCamera: Bool { camera != nil }
    var selectedZoom: ZoomEffect? { edits.zooms.first { $0.id == selectedZoomID } }

    #if DEBUG
    private(set) var isDesignPreview = false

    private init(designScenario: String) {
        source = URL(fileURLWithPath: "/dev/null")
        camera = nil
        clicks = []
        keystrokes = []
        keystrokeDelay = 1.5
        resolution = .sharper
        isDesignPreview = true
        duration = 11.1
        time = 1
        isPreparing = designScenario == "preparing"
        let sourceSize = designScenario == "portrait" ? CGSize(width: 720, height: 1080) : CGSize(width: 1800, height: 1264)
        let layout = resolution.layout(for: sourceSize, frameStyle: edits.frameStyle)
        canvas = layout.canvas
        contentRect = layout.content
        if ["zooms", "adding", "overlap"].contains(designScenario) {
            edits.zooms = [
                ZoomEffect(start: 1, duration: 3, focalPoint: CGPoint(x: 0.25, y: 0.3)),
                ZoomEffect(start: designScenario == "overlap" ? 2 : 6, duration: 3, magnification: 2.5, focalPoint: CGPoint(x: 0.8, y: 0.6))
            ]
            selectedZoomID = edits.zooms.first?.id
        }
        addingZoom = designScenario == "adding"
        if designScenario == "error" { error = "The recording couldn’t be loaded. Try preparing the preview again." }
    }

    static func designPreview(_ scenario: String) -> RecordingPreview {
        RecordingPreview(designScenario: scenario)
    }
    #endif

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
        #if DEBUG
        if isDesignPreview { isPreparing = false; return }
        #endif
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
                                                       zoom: edits.zoom(at: time), seconds: time, frameStyle: edits.frameStyle),
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

    func renameSelected(_ name: String) {
        guard let index = edits.zooms.firstIndex(where: { $0.id == selectedZoomID }) else { return }
        edits.zooms[index].name = name
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
    var cameraNotes: [String] = []
    var inputMessage: String? = nil
    var capturedKeystrokeCount: Int? = nil
    @State private var zoomHelpExpanded = false
    @FocusState private var editingZoomName: Bool

    private var canPlaceZoom: Bool {
        !preview.isPreparing && preview.error == nil && preview.duration - preview.time >= 1 / 30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review recording").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("Preview your video and guide viewers with zooms.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            GeometryReader { geometry in
                let wide = geometry.size.width >= 940
                // Keep the player view alive when the inspector moves below it.
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    playbackArea
                        .padding(wide ? 20 : 16)
                        .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil)
                        .frame(height: wide ? nil : max(210, min(420, geometry.size.height * 0.56)))
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: wide ? 1 : nil, height: wide ? nil : 1)
                        .accessibilityHidden(true)
                    inspector.frame(width: wide ? 300 : nil)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            if editingZoomName { editingZoomName = false }
            else { cancelPlacement() }
        }
        .onChange(of: preview.selectedZoomID) { _, _ in editingZoomName = false }
    }

    private var playbackArea: some View {
        VStack(spacing: 12) {
            videoCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if preview.addingZoom && preview.error == nil {
                placementPrompt
            }
            playbackControls
        }
    }

    private var videoCanvas: some View {
        GeometryReader { geometry in
            let fit = RecordingGeometry.fittedRect(source: preview.canvas, canvas: geometry.size)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                previewImage
                    .frame(width: fit.width, height: fit.height)
                    .overlay {
                        if preview.addingZoom && canPlaceZoom {
                            Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                                .contentShape(Rectangle())
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
                if let error = preview.error {
                    ViewThatFits(in: .vertical) {
                        previewProblem(error, detailed: true)
                        previewProblem(error, detailed: false)
                    }
                    .frame(maxWidth: 360)
                    .padding(12)
                } else if preview.isPreparing {
                    ProgressView("Updating preview…")
                        .controlSize(.small)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording preview")
        .accessibilityHint(preview.addingZoom ? "Click the footage to choose a focal point, or use the Use Center button." : "Shows your recording with the current effects.")
    }

    @ViewBuilder private var previewImage: some View {
        #if DEBUG
        if preview.isDesignPreview {
            RecordingPreviewPlaceholder()
        } else {
            PreviewPlayer(player: preview.player)
        }
        #else
        PreviewPlayer(player: preview.player)
        #endif
    }

    private func previewProblem(_ error: String, detailed: Bool) -> some View {
        VStack(spacing: 10) {
            Text("Preview unavailable").font(.headline)
            if detailed {
                Text(error).font(.callout).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits {
                HStack { recoveryButtons }
                VStack { recoveryButtons }
            }
        }
        .padding(detailed ? 20 : 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var recoveryButtons: some View {
        Button("Retry Preview") { preview.rebuild() }
        if preview.hasCamera && preview.includesCamera {
            Button("Preview Without Camera") { preview.includesCamera = false }
        }
    }

    private var placementPrompt: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a focal point").font(.headline)
                Text("Click the video where viewers should look.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Use Center") { preview.addZoom(at: CGPoint(x: 0.5, y: 0.5)); NSCursor.arrow.set() }
                .disabled(!canPlaceZoom)
                .accessibilityHint("Place a zoom at the center of the visible footage.")
            Button("Cancel") { cancelPlacement() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button { preview.togglePlayback() } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20, height: 20)
            }
            .keyboardShortcut(editingZoomName ? nil : KeyboardShortcut(.space, modifiers: []))
            .accessibilityLabel(preview.isPlaying ? "Pause preview" : "Play preview")
            .help("Play or pause (Space)")
            Slider(value: Binding(get: { preview.time }, set: { preview.seek(to: $0) }),
                   in: 0...max(1 / 30, preview.duration))
                .accessibilityLabel("Playback position in seconds")
            Text("\(timestamp(preview.time)) / \(timestamp(preview.duration))")
                .monospacedDigit().font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel("\(preview.time.formatted(.number.precision(.fractionLength(1)))) of \(preview.duration.formatted(.number.precision(.fractionLength(1)))) seconds")
        }
        .disabled(preview.isPreparing || preview.error != nil)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = preview.error {
                    inspectorSection("Preview") { featureNotice(error) }
                }
                zoomSection
                appearanceSection
                exportSection
                if capturedKeystrokeCount != nil || inputMessage != nil {
                    inspectorSection("Recording details") {
                        if let count = capturedKeystrokeCount {
                            Text("\(count) keystrokes captured").font(.callout)
                        }
                        if let inputMessage { featureNotice(inputMessage) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Zooms").font(.headline).accessibilityAddTraits(.isHeader)
                Text("\(preview.edits.zooms.count)").foregroundStyle(.secondary)
                Spacer()
                Button {
                    preview.seek(to: preview.time)
                    preview.addingZoom = true
                } label: {
                    Label("Add Zoom", systemImage: "plus")
                }
                .disabled(!canPlaceZoom || preview.addingZoom)
                .help("Add a zoom at \(timestamp(preview.time))")
            }
            if preview.edits.zooms.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bring a detail into focus").fontWeight(.medium)
                    Text("Pause or scrub to a moment, then add a zoom.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(orderedZooms.enumerated()), id: \.element.id) { index, zoom in
                        zoomRow(zoom, number: index + 1)
                    }
                }
                if let zoom = preview.selectedZoom {
                    selectedZoomControls(zoom)
                } else {
                    Text("Select a zoom to adjust its duration and magnification.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("How zooms work", isExpanded: $zoomHelpExpanded) {
                Text("Zooms ease in and out. A later zoom shortens the earlier one, including its ease-out. At the same start time, the newest zoom wins.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var orderedZooms: [ZoomEffect] { preview.edits.zooms.sorted { $0.start < $1.start } }

    private func zoomRow(_ zoom: ZoomEffect, number: Int) -> some View {
        let selected = preview.selectedZoomID == zoom.id
        let title = zoomTitle(zoom, number: number)
        return Button { preview.selectZoom(zoom.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.tail).help(title)
                    Text("\(timestamp(zoom.start)) · \(decimal(zoom.duration)) s")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text("\(decimal(zoom.magnification))×").monospacedDigit().foregroundStyle(.secondary)
                if selected {
                    Image(systemName: "checkmark").font(.callout).accessibilityHidden(true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), starts at \(decimal(zoom.start)) seconds, duration \(decimal(zoom.duration)) seconds, \(decimal(zoom.magnification)) times magnification")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help("Select and seek to this zoom")
    }

    private func selectedZoomControls(_ zoom: ZoomEffect) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 2)
            HStack {
                Text("Selected zoom").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Remove", role: .destructive) { preview.removeSelected() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove selected zoom")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout).foregroundStyle(.secondary)
                TextField("Zoom name", text: Binding(
                    get: { preview.selectedZoom?.name ?? "" },
                    set: { preview.renameSelected($0) }
                ), prompt: Text("Zoom \((orderedZooms.firstIndex { $0.id == zoom.id } ?? 0) + 1)"))
                .textFieldStyle(.roundedBorder)
                .focused($editingZoomName)
                .onSubmit { editingZoomName = false }
                .accessibilityLabel("Zoom name")
            }
            VStack(spacing: 6) {
                valueLabel("Duration", value: "\(decimal(zoom.duration)) s")
                Slider(value: Binding(get: { preview.selectedZoom?.duration ?? 1 }, set: { preview.updateSelected(duration: $0) }),
                       in: (1 / 30)...max(1 / 30, preview.duration - zoom.start))
                    .accessibilityLabel("Zoom duration in seconds")
            }
            VStack(spacing: 6) {
                valueLabel("Magnification", value: "\(decimal(zoom.magnification))×")
                Slider(value: Binding(get: { preview.selectedZoom?.magnification ?? 2 }, set: { preview.updateSelected(magnification: $0) }), in: 1.1...4)
                    .accessibilityLabel("Zoom magnification")
            }
            if let resolved = preview.edits.resolvedZooms.first(where: { $0.id == zoom.id }) {
                if resolved.duration < zoom.duration {
                    featureNotice("The next zoom starts at \(timestamp(zoom.start + resolved.duration)), so this zoom ends there.")
                }
            } else {
                featureNotice("A newer zoom starts at the same time and takes priority over this one.")
            }
        }
    }

    private var appearanceSection: some View {
        inspectorSection("Appearance") {
            Text("Frame").font(.callout).foregroundStyle(.secondary)
            Picker("Video frame", selection: $preview.edits.frameStyle) {
                ForEach(RecordingFrameStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(preview.edits.frameStyle.explanation)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if preview.hasCamera {
                Divider().padding(.vertical, 4)
                inspectorToggle("Recorded camera", detail: "Include the recorded camera bubble.", isOn: $preview.includesCamera)
            }
            ForEach(cameraNotes, id: \.self) { featureNotice($0) }
        }
    }

    private var exportSection: some View {
        inspectorSection("Export") {
            Text("Resolution").font(.callout).foregroundStyle(.secondary)
            Picker("Export resolution", selection: $preview.resolution) {
                ForEach(RecordingResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(preview.isPreparing ? "Updating output…" : preview.error != nil ? "Output size unavailable" : "\(Int(preview.canvas.width)) × \(Int(preview.canvas.height)) pixels")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text("MP4 · H.264 · 30 fps").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inspectorToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(title).accessibilityHint(detail)
    }

    private func valueLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func featureNotice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cancelPlacement() {
        preview.addingZoom = false
        NSCursor.arrow.set()
    }

    private func zoomTitle(_ zoom: ZoomEffect, number: Int) -> String {
        let name = zoom.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Zoom \(number)" : name
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value > 0 && value < 0.1 ? 2 : 1)))
    }

    private func timestamp(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        let tenths = Int((safe * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

#if DEBUG
private struct RecordingPreviewPlaceholder: View {
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            VStack(alignment: .leading, spacing: 20) {
                Text("Walk & Roll").font(.title.weight(.semibold))
                Text("Generated preview content").font(.headline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.2 + Double(index) * 0.15))
                            .frame(height: 70)
                    }
                }
                Text("Your screen stays sharp. Effects stay editable.").font(.body)
            }
            .padding(32)
        }
    }
}

struct RecordingEditorPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            RecordingPreviewView(preview: .designPreview("empty"))
                .frame(width: 1040, height: 680).previewDisplayName("No zooms · Wide")
            RecordingPreviewView(preview: .designPreview("zooms"))
                .frame(width: 1040, height: 680).preferredColorScheme(.dark).previewDisplayName("Selected zoom · Dark")
            RecordingPreviewView(preview: .designPreview("adding"))
                .frame(width: 640, height: 620).previewDisplayName("Place zoom · Narrow")
            RecordingPreviewView(preview: .designPreview("overlap"))
                .frame(width: 1040, height: 500).previewDisplayName("Overlapping zooms · Short")
            RecordingPreviewView(preview: .designPreview("portrait"))
                .frame(width: 1040, height: 680).previewDisplayName("Portrait footage")
            RecordingPreviewView(preview: .designPreview("preparing"))
                .frame(width: 640, height: 500).previewDisplayName("Preparing")
            RecordingPreviewView(preview: .designPreview("error"))
                .frame(width: 1040, height: 680).previewDisplayName("Preview recovery")
        }
    }
}
#endif

private struct PreviewPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
