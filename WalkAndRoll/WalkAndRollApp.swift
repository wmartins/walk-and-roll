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
        .windowResizability(.contentSize)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            source
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Resolution", selection: $recorder.resolution) {
                    ForEach(RecordingResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                if let size = recorder.sourcePixelSize {
                    Text("Source \(Int(size.width.rounded())) × \(Int(size.height.rounded())) pixels")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if size.width < 1920 && size.height < 1080 {
                        Text("Enlarge the window or use a Retina display to capture more detail.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Microphone", isOn: $recorder.microphone)
                Toggle("System audio", isOn: $recorder.systemAudio)
                Toggle("Show click highlights", isOn: $recorder.showClickHighlights)
                Toggle("Show keystrokes", isOn: Binding(
                    get: { recorder.showKeystrokes },
                    set: { recorder.setKeystrokesEnabled($0) }
                ))
                if recorder.showKeystrokes {
                    Picker("Include", selection: $recorder.keystrokeMode) {
                        ForEach(KeystrokeMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    if recorder.keystrokeMode == .allKeys {
                        Stepper(
                            "Characters per group  \(recorder.keystrokeGroupLength)",
                            value: $recorder.keystrokeGroupLength, in: 4...24, step: 4
                        )
                        Text("Typed text appears in the video.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Fade after", selection: $recorder.keystrokeDelay) {
                        Text("1 second").tag(1.0)
                        Text("1.5 seconds").tag(1.5)
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                    }
                }
                Toggle("Camera", isOn: Binding(
                    get: { recorder.cameraEnabled },
                    set: { recorder.setCameraEnabled($0) }
                ))
                .disabled(recorder.cameraPreparing)
            }
            .disabled(!recorder.canSetUp)

            if recorder.cameraPreparing {
                ProgressView("Starting camera…").controlSize(.small)
            } else if recorder.cameraEnabled && recorder.canSetUp {
                HStack(alignment: .top, spacing: 16) {
                    CameraPreview(session: recorder.cameraSession)
                        .frame(width: 124, height: 124)
                        .clipShape(RoundedRectangle(cornerRadius: 27))
                        .accessibilityLabel("Live camera preview")
                    Picker("Bubble position", selection: $recorder.cameraCorner) {
                        ForEach(CameraCorner.allCases) { corner in
                            Text(corner.rawValue).tag(corner)
                        }
                    }
                }
            }

            if let message = recorder.cameraMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.presenterOverlayActive {
                Text("macOS Presenter Overlay is active. Turn it off in the screen-sharing menu to use Walk & Roll’s camera bubble.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = recorder.shortcutMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            controls

            if recorder.showKeystrokes,
               recorder.phase == .recording || recorder.phase == .pendingSave || recorder.phase == .choosingSaveLocation {
                Text("\(recorder.capturedKeystrokeCount) keystrokes captured")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = recorder.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = recorder.savedURL {
                HStack {
                    Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .font(.callout)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { recorder.closeCameraPreview() }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) { recorder.discard() }
        }
    }

    private var source: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recorder.sourceName ?? "Recording source")
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let application = recorder.sourceApplicationName {
                        Text(application)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } icon: {
                Image(systemName: "macwindow")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(recorder.sourceName ?? "Recording source")
            Button(recorder.sourceName == nil ? "Choose Source…" : "Change Source…") {
                recorder.chooseSource()
            }
            .disabled(!recorder.canSetUp)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .idle, .ready, .picking:
            HStack {
                if recorder.phase == .picking {
                    Text("Choose one window or display.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start Recording") { recorder.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.phase != .ready || recorder.cameraPreparing)
            }
        case .starting:
            ProgressView("Starting recording…").controlSize(.small)
        case .recording:
            HStack {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                if let start = recorder.startedAt {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text(elapsed(since: start))
                            .monospacedDigit()
                            .accessibilityLabel("Elapsed time")
                            .accessibilityValue(elapsed(since: start))
                    }
                }
                Spacer()
                Button("Stop Recording") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
            }
        case .stopping:
            ProgressView("Finishing recording…").controlSize(.small)
        case .pendingSave, .choosingSaveLocation:
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Text("Recording ready to save")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Discard") { confirmingDiscard = true }
                    Button("Save MP4…") { recorder.save() }
                        .buttonStyle(.borderedProminent)
                }
                if recorder.canSaveWithoutCamera {
                    Button("Save Without Camera…") { recorder.save(withoutCamera: true) }
                }
            }
            .disabled(recorder.phase == .choosingSaveLocation)
        case .exporting:
            HStack {
                ProgressView("Exporting MP4…", value: recorder.progress)
                    .controlSize(.small)
                Button("Cancel Export") { recorder.cancelExport() }
            }
        }
    }

    private func elapsed(since start: ContinuousClock.Instant) -> String {
        let seconds = start.duration(to: .now).components.seconds
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
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
