import AVFoundation
import SwiftUI

@main
struct WalkAndRollApp: App {
    @NSApplicationDelegateAdaptor(WalkAndRollAppDelegate.self) private var appDelegate
    @State private var recorder = Recorder()

    var body: some Scene {
        Window("Walk & Roll", id: "recorder") {
            RecorderView(recorder: recorder)
        }
        .defaultSize(width: 560, height: 740)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class WalkAndRollAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Command Line Tools builds package the catalog artwork as an .icns file.
        guard Bundle.main.url(forResource: "Assets", withExtension: "car") == nil,
              let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

private struct RecorderView: View {
    @Bindable var recorder: Recorder
    @State private var confirmingDiscard = false
    @State private var exportOptionsExpanded = false
    @State private var keystrokeOptionsExpanded = true

    private var isCapturing: Bool {
        [.starting, .recording, .stopping].contains(recorder.phase)
    }

    var body: some View {
        Group {
            if let preview = recorder.preview {
                editor(preview)
            } else {
                setup
            }
        }
        .onDisappear {
            recorder.closeCameraPreview()
            recorder.preview?.pause()
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { recorder.discard() }
        }
    }

    private var setup: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(isCapturing ? "Your recording" : "New recording")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(isCapturing ? "When you’re done, stop to preview and edit." : "Choose what to capture. Make it your own.")
                            .foregroundStyle(.secondary)
                    }
                    sourceSection
                    if isCapturing {
                        captureSummary
                    } else {
                        audioSection
                        cameraSection
                        inputSection
                        Text("Recordings are processed and saved on your Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            setupActions
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity,
               minHeight: 360, idealHeight: min(740, (NSScreen.main?.visibleFrame.height ?? 840) - 100), maxHeight: .infinity)
    }

    private var sourceSection: some View {
        section("Source") {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "macwindow")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recorder.sourceName ?? "Choose a window or display")
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(recorder.sourceName ?? "Select one window or an entire display using the macOS sharing picker.")
                        .accessibilityLabel(recorder.sourceName ?? "No recording source selected")
                    if let application = recorder.sourceApplicationName {
                        Text(application)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if recorder.sourceName == nil {
                        Text("Select what your viewers will see.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let size = recorder.sourcePixelSize {
                        Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pixels")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isCapturing {
                    Button(recorder.sourceName == nil ? "Choose Source…" : "Change…") { recorder.chooseSource() }
                        .keyboardShortcut("o", modifiers: .command)
                        .disabled(!recorder.canSetUp)
                        .accessibilityLabel(recorder.sourceName == nil ? "Choose recording source" : "Change recording source")
                }
            }
            if !isCapturing {
                Divider().padding(.vertical, 4)
                DisclosureGroup(isExpanded: $exportOptionsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Export resolution")
                            Spacer(minLength: 12)
                            Picker("Export resolution", selection: $recorder.resolution) {
                                ForEach(RecordingResolution.allCases) { resolution in
                                    Text(resolution.rawValue).tag(resolution)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Text("Original capture keeps native detail up to 4K. You can also change export resolution in preview.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let size = recorder.sourcePixelSize, size.width < 1920 && size.height < 1080 {
                            Text("For more detail, enlarge the source window or use a Retina display.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack {
                        Text("Export options")
                        Spacer()
                        Text(recorder.resolution == .sharper ? "Native, up to 4K" : "1080p")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!recorder.canSetUp)
            }
        }
    }

    private var audioSection: some View {
        section("Audio") {
            featureToggle("Microphone", detail: "Your voice, using the Mac’s default input.", isOn: $recorder.microphone)
            if let message = recorder.microphoneMessage {
                notice(message)
            } else if recorder.microphone {
                Text(AVCaptureDevice.default(for: .audio).map { "Input: \($0.localizedName)" }
                     ?? "No microphone found. Connect an input device or turn Microphone off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            featureToggle("System audio", detail: "Sound from the shared app or display.", isOn: $recorder.systemAudio)
            if let message = recorder.systemAudioMessage { notice(message) }
        }
        .disabled(!recorder.canSetUp)
    }

    private var cameraSection: some View {
        section("Camera") {
            featureToggle("Camera bubble", detail: "Include yourself in a corner of the video.", isOn: Binding(
                get: { recorder.cameraEnabled },
                set: { recorder.setCameraEnabled($0) }
            ))
            .disabled(!recorder.canSetUp || recorder.cameraPreparing)
            if recorder.cameraPreparing {
                ProgressView("Starting camera…").controlSize(.small)
                    .padding(.top, 8)
            } else if recorder.cameraEnabled {
                HStack(alignment: .center, spacing: 16) {
                    cameraPreview
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .accessibilityLabel("Live camera preview")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bubble position")
                        Picker("Bubble position", selection: $recorder.cameraCorner) {
                            ForEach(CameraCorner.allCases) { corner in
                                Text(corner.rawValue).tag(corner)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Text("Stays in this corner, even when you zoom.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 12)
                .disabled(!recorder.canSetUp)
            }
            cameraMessages
        }
    }

    @ViewBuilder private var cameraPreview: some View {
        #if DEBUG
        if recorder.isSetupPreview {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
            }
        } else {
            CameraPreview(session: recorder.cameraSession)
        }
        #else
        CameraPreview(session: recorder.cameraSession)
        #endif
    }

    private var inputSection: some View {
        section("Input effects") {
            featureToggle("Show click highlights", detail: "Draw a brief ring where you click.", isOn: $recorder.showClickHighlights)
                .disabled(!recorder.canSetUp)
            Divider().padding(.vertical, 4)
            featureToggle("Show keystrokes", detail: "Display shortcuts or typing as badges.", isOn: Binding(
                get: { recorder.showKeystrokes },
                set: { recorder.setKeystrokesEnabled($0); keystrokeOptionsExpanded = true }
            ))
            .disabled(!recorder.canSetUp)
            if recorder.showKeystrokes {
                // Keep privacy information visible even when detailed controls are collapsed.
                if recorder.keystrokeMode == .allKeys {
                    notice("Typed text will be visible in the video.")
                } else {
                    Text("Only Command and Control shortcuts appear.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup("Keystroke options", isExpanded: $keystrokeOptionsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Include")
                            Spacer(minLength: 12)
                            Picker("Include", selection: $recorder.keystrokeMode) {
                                ForEach(KeystrokeMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        if recorder.keystrokeMode == .allKeys {
                            Stepper(value: $recorder.keystrokeGroupLength, in: 4...24, step: 4) {
                                HStack {
                                    Text("Characters per group")
                                    Spacer()
                                    Text("\(recorder.keystrokeGroupLength)").monospacedDigit()
                                }
                            }
                            .accessibilityLabel("Characters per group")
                            .accessibilityValue("\(recorder.keystrokeGroupLength) characters per group")
                        }
                        HStack {
                            Text("Fade after")
                            Spacer(minLength: 12)
                            Picker("Fade after", selection: $recorder.keystrokeDelay) {
                                Text("1 second").tag(1.0)
                                Text("1.5 seconds").tag(1.5)
                                Text("2 seconds").tag(2.0)
                                Text("3 seconds").tag(3.0)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    .padding(.top, 10)
                }
                .disabled(!recorder.canSetUp)
                Text("Requires Input Monitoring. In a window recording, only input to the captured app appears.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = recorder.shortcutMessage { notice(message) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }

    private func featureToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private func notice(_ message: String) -> some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var audioSummary: String {
        switch (recorder.microphone, recorder.systemAudio) {
        case (true, true): "Microphone and system audio"
        case (true, false): "Microphone only"
        case (false, true): "System audio only"
        case (false, false): "No audio"
        }
    }

    private var captureSummary: some View {
        section("Included in this recording") {
            summaryRow("Audio", value: audioSummary)
            summaryRow("Camera bubble", value: recorder.cameraEnabled ? recorder.cameraCorner.rawValue : "Off")
            summaryRow("Click highlights", value: recorder.showClickHighlights ? "On" : "Off")
            summaryRow("Keystrokes", value: recorder.showKeystrokes ? recorder.keystrokeMode.rawValue : "Off")
            if recorder.showKeystrokes {
                Text("\(recorder.capturedKeystrokeCount) keystrokes captured")
                    .font(.callout).foregroundStyle(.secondary)
                if recorder.keystrokeMode == .allKeys { notice("Typed text is visible in the video.") }
            }
            cameraMessages
            if let message = recorder.shortcutMessage { notice(message) }
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    @ViewBuilder private var cameraMessages: some View {
        if let message = recorder.cameraMessage { notice(message) }
        if recorder.presenterOverlayActive {
            notice("macOS Presenter Overlay is active. Turn it off in the screen-sharing menu to use Walk & Roll’s camera bubble.")
        }
    }

    private var readiness: String {
        if recorder.phase == .picking { return "Choose one window or display in the macOS picker." }
        if recorder.cameraPreparing { return "Waiting for the camera to finish starting…" }
        if recorder.phase != .ready { return "Choose a source to start recording." }
        return "\(audioSummary) · Camera \(recorder.cameraEnabled ? "on" : "off")"
    }

    private var setupActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = recorder.message,
               isCapturing || (message != recorder.microphoneMessage && message != recorder.systemAudioMessage) {
                notice(message)
            }
            HStack(spacing: 16) {
                switch recorder.phase {
                case .starting:
                    ProgressView().controlSize(.small).accessibilityLabel("Starting recording")
                    Text("Starting recording…")
                    Spacer()
                    Button("Start Recording") {}.disabled(true)
                case .recording:
                    Image(systemName: "record.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recording").fontWeight(.semibold)
                        if let start = recorder.startedAt {
                            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                                Text(elapsed(since: start)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Elapsed time")
                                    .accessibilityValue(elapsed(since: start))
                            }
                        }
                    }
                    Spacer()
                    Button("Stop Recording") { recorder.stop() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(".", modifiers: .command)
                case .stopping:
                    ProgressView().controlSize(.small).accessibilityLabel("Finishing recording")
                    Text("Finishing recording…")
                    Spacer()
                    Button("Stop Recording") {}.disabled(true)
                default:
                    VStack(alignment: .leading, spacing: 3) {
                        if recorder.phase == .ready && !recorder.cameraPreparing {
                            Text("Ready to record").fontWeight(.medium)
                        }
                        Text(readiness).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Start Recording") { recorder.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(recorder.phase != .ready || recorder.cameraPreparing)
                        .help(readiness)
                }
            }
            .controlSize(.large)
        }
    }

    private func editor(_ preview: RecordingPreview) -> some View {
        VStack(spacing: 0) {
            RecordingPreviewView(
                preview: preview,
                cameraNotes: [recorder.cameraMessage,
                              recorder.presenterOverlayActive ? "macOS Presenter Overlay is active. Turn it off in the screen-sharing menu to use Walk & Roll’s camera bubble." : nil].compactMap { $0 },
                inputMessage: recorder.shortcutMessage,
                capturedKeystrokeCount: recorder.showKeystrokes ? recorder.capturedKeystrokeCount : nil
            )
            .disabled(recorder.phase != .pendingSave)
            .allowsHitTesting(recorder.phase == .pendingSave)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = recorder.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = recorder.savedURL {
                    HStack {
                        Text("Last saved: \(url.lastPathComponent)")
                            .lineLimit(1).truncationMode(.middle)
                            .help(url.path)
                        Spacer(minLength: 12)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                editorControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, idealWidth: 1040, maxWidth: .infinity,
               minHeight: 480, idealHeight: 760, maxHeight: .infinity)
        .background {
            #if DEBUG
            if !recorder.isSetupPreview { EditorWindowLayout() }
            #else
            EditorWindowLayout()
            #endif
        }
    }

    @ViewBuilder private var editorControls: some View {
        switch recorder.phase {
        case .pendingSave, .choosingSaveLocation:
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Edits stay available until you discard or quit.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Discard…") { confirmingDiscard = true }
                    Button("Save MP4…") { recorder.save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .controlSize(.large)
                if recorder.canSaveWithoutCamera {
                    Button("Save Without Camera…") { recorder.save(withoutCamera: true) }
                }
            }
            .disabled(recorder.phase == .choosingSaveLocation)
        case .exporting:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Saving MP4…").fontWeight(.medium)
                        Spacer()
                        Text(recorder.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: recorder.progress).controlSize(.small)
                        .accessibilityLabel("MP4 export progress")
                }
                Button("Cancel Export") { recorder.cancelExport() }
            }
        default: EmptyView()
        }
    }

    private func elapsed(since start: ContinuousClock.Instant) -> String {
        let seconds = start.duration(to: .now).components.seconds
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}

#if DEBUG
struct RecorderSetupPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            RecorderView(recorder: Recorder.renderFixture("empty"))
                .frame(width: 560, height: 740).previewDisplayName("No source · Light")
            RecorderView(recorder: Recorder.renderFixture("selected"))
                .frame(width: 560, height: 740).preferredColorScheme(.dark).previewDisplayName("Long title · Dark")
            RecorderView(recorder: Recorder.renderFixture("expanded"))
                .frame(width: 560, height: 1000).previewDisplayName("Camera and all keystrokes")
            RecorderView(recorder: Recorder.renderFixture("permissions"))
                .frame(width: 560, height: 1000).previewDisplayName("Optional permissions denied")
            RecorderView(recorder: Recorder.renderFixture("devices"))
                .frame(width: 440, height: 640).previewDisplayName("Camera unavailable · Narrow")
            RecorderView(recorder: Recorder.renderFixture("compact"))
                .frame(width: 440, height: 460).previewDisplayName("Small window · Scroll")
            RecorderView(recorder: Recorder.renderFixture("cameraStarting"))
                .frame(width: 560, height: 740).previewDisplayName("Waiting for camera")
            RecorderView(recorder: Recorder.renderFixture("starting"))
                .frame(width: 560, height: 540).previewDisplayName("Starting")
            RecorderView(recorder: Recorder.renderFixture("recording"))
                .frame(width: 560, height: 540).previewDisplayName("Recording")
            RecorderView(recorder: Recorder.renderFixture("stopping"))
                .frame(width: 560, height: 540).previewDisplayName("Stopping")
        }
    }
}
#endif

// Apply a comfortable review size once per recording; later resizing belongs to the user.
private struct EditorWindowLayout: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorWindowLayoutView { EditorWindowLayoutView() }
    func updateNSView(_ view: EditorWindowLayoutView, context: Context) {}
}

private final class EditorWindowLayoutView: NSView {
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !applied, let window else { return }
        applied = true
        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen else { return }
            let visible = screen.visibleFrame
            let content = CGRect(origin: .zero, size: CGSize(
                width: max(640, min(1040, visible.width - 80)),
                height: max(480, min(760, visible.height - 100))
            ))
            let size = window.frameRect(forContentRect: content).size
            let previous = window.frame
            let origin = CGPoint(
                x: max(visible.minX, min(visible.maxX - size.width, previous.midX - size.width / 2)),
                y: max(visible.minY, min(visible.maxY - size.height, previous.maxY - size.height))
            )
            window.setFrame(CGRect(origin: origin, size: size), display: true)
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session)
    }

    func updateNSView(_ view: CameraPreviewView, context: Context) {}

    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) {
        view.detach()
    }
}

private final class CameraPreviewView: NSView {
    private let session: AVCaptureSession
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        self.session = session
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            detach()
            return
        }
        preview.session = session
        if preview.superlayer == nil { layer?.addSublayer(preview) }
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func detach() {
        preview.session = nil
        preview.removeFromSuperlayer()
    }
}
