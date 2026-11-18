import AppKit
import AVFoundation
import Carbon
import Observation
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class Recorder: NSObject {
    enum Phase: Equatable {
        case idle, picking, ready, starting, recording, stopping, pendingSave, choosingSaveLocation, exporting
    }

    private(set) var phase = Phase.idle
    private(set) var sourceName: String?
    private(set) var sourceApplicationName: String?
    private(set) var sourcePixelSize: CGSize?
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var message: String?
    private(set) var savedURL: URL?
    private(set) var progress = 0.0
    var microphone = false
    var systemAudio = false
    var showClickHighlights = false
    private(set) var showKeystrokes = false
    var keystrokeMode = KeystrokeMode.commandsOnly
    var keystrokeGroupLength = 12
    var keystrokeDelay = 1.5
    private(set) var shortcutMessage: String?
    private(set) var capturedKeystrokeCount = 0
    var resolution = RecordingResolution.sharper
    var cameraCorner = CameraCorner.bottomRight
    private(set) var cameraEnabled = false
    private(set) var cameraPreparing = false
    private(set) var cameraMessage: String?
    private(set) var presenterOverlayActive = false
    private(set) var canSaveWithoutCamera = false
    private(set) var preview: RecordingPreview?

    var canSetUp: Bool { phase == .idle || phase == .ready }
    var cameraSession: AVCaptureSession { camera.session }

    @ObservationIgnored private let camera = CameraCapture()
    @ObservationIgnored private var screenClock: ScreenRecordingClock?
    @ObservationIgnored private let clickMonitor = RecordingClickMonitor()
    @ObservationIgnored private var clicks: [ClickHighlight] = []
    @ObservationIgnored private let shortcutMonitor = RecordingShortcutMonitor()
    @ObservationIgnored private var shortcutScope: ShortcutScope?
    @ObservationIgnored private var keystrokes: [KeystrokeBadge] = []
    @ObservationIgnored private var keystrokeGrouper = KeystrokeGrouper()
    @ObservationIgnored private var shortcutStatusTask: Task<Void, Never>?
    @ObservationIgnored private var cameraOverlay: CameraOverlay?
    @ObservationIgnored private let picker = SCContentSharingPicker.shared
    @ObservationIgnored private var filter: SCContentFilter?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: SCRecordingOutput?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var stopIssued = false

    override init() {
        super.init()
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
    }

    func chooseSource() {
        guard canSetUp else { return }
        phase = .picking
        message = nil
        picker.isActive = true
        picker.present()
    }

    private func updateSourceDescription(_ filter: SCContentFilter) {
        sourceName = filter.style == .display ? "Display selected" : "Window selected"
        sourceApplicationName = nil
        guard filter.style == .window else { return }
        if #available(macOS 15.2, *) {
            let windows = filter.includedWindows
            let candidates = windows.count == 1 ? windows : windows.filter { $0.frame == filter.contentRect }
            guard candidates.count == 1, let window = candidates.first else { return }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let application = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                sourceName = title
                if let application, !application.isEmpty, application != title {
                    sourceApplicationName = application
                }
            } else if let application, !application.isEmpty {
                sourceName = "\(application) window"
            }
        }
    }

    func start() {
        guard phase == .ready, !cameraPreparing, let filter else { return }
        phase = .starting
        message = nil
        shortcutMessage = nil
        capturedKeystrokeCount = 0
        keystrokeGrouper.reset()
        savedURL = nil
        Task {
            if microphone {
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
                default: allowed = false
                }
                guard allowed else {
                    microphone = false
                    message = "Microphone access is off. Start again to record without it, or enable Walk & Roll in System Settings → Privacy & Security → Microphone."
                    phase = .ready
                    return
                }
            }
            await startCapture(filter)
        }
    }

    func setCameraEnabled(_ enabled: Bool) {
        guard canSetUp, !cameraPreparing else { return }
        cameraEnabled = enabled
        cameraMessage = nil
        guard enabled else {
            camera.stop()
            return
        }

        cameraPreparing = true
        Task {
            defer { cameraPreparing = false }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard cameraEnabled else { return }
            guard allowed else {
                cameraEnabled = false
                cameraMessage = "Camera access is off. You can still record, or enable Walk & Roll in System Settings → Privacy & Security → Camera."
                return
            }
            do {
                try await camera.startPreview()
            } catch {
                cameraEnabled = false
                cameraMessage = "The camera couldn’t start. You can still record."
                camera.stop()
            }
        }
    }

    func setKeystrokesEnabled(_ enabled: Bool) {
        guard canSetUp else { return }
        showKeystrokes = enabled
        shortcutMessage = nil
        if enabled, !CGPreflightListenEventAccess(), !CGRequestListenEventAccess() {
            shortcutMessage = "Allow Walk & Roll under System Settings → Privacy & Security → Input Monitoring, then quit and reopen the app to include keystrokes."
        }
    }

    func closeCameraPreview() {
        guard cameraEnabled, canSetUp || phase == .picking else { return }
        cameraEnabled = false
        camera.stop()
    }

    private func startCapture(_ filter: SCContentFilter) async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkAndRoll-\(UUID().uuidString).mp4")
        recordingURL = url

        let size = filter.contentRect.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            resetSource()
            message = "This source has no visible area. Choose a window or display again."
            return
        }

        let pixelScale = capturePixelScale(for: filter)
        let pixels = CGSize(width: size.width * pixelScale, height: size.height * pixelScale)
        sourcePixelSize = pixels
        // Keep native detail for later zooms even when the selected export is 1080p.
        let outputSize = RecordingResolution.captureSize(for: pixels)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        // Automatic preserves Retina detail without the .best-mode rectangle seen in iTerm2.
        // Nominal captures at one pixel per point, even when a larger output size is requested.
        if filter.style == .window { configuration.captureResolution = .automatic }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.capturesAudio = systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = url
        settings.videoCodecType = .h264
        settings.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: settings, delegate: self)
        self.stream = stream
        self.output = output

        if showKeystrokes {
            if let scope = ShortcutScope(filter: filter) {
                if CGPreflightListenEventAccess() || CGRequestListenEventAccess() {
                    shortcutScope = scope
                } else {
                    shortcutMessage = "To include keystrokes, allow Walk & Roll under System Settings → Privacy & Security → Input Monitoring, then reopen the app. This recording can continue."
                }
            } else {
                shortcutMessage = "The captured window’s app couldn’t be identified. This recording can continue without keystrokes."
            }
        }

        if cameraEnabled || showClickHighlights || shortcutScope != nil {
            let clock = ScreenRecordingClock(tracksClicks: showClickHighlights)
            if (try? stream.addStreamOutput(clock, type: .screen, sampleHandlerQueue: clock.queue)) != nil {
                screenClock = clock
            } else {
                if showClickHighlights { message = "Click highlights couldn’t start. Screen recording can continue." }
                if shortcutScope != nil {
                    shortcutMessage = "Keystrokes couldn’t start. Screen recording can continue."
                }
            }
        }
        if cameraEnabled {
            let cameraURL = url.deletingPathExtension().appendingPathExtension("camera.mov")
            let started = screenClock != nil ? await camera.beginRecording(to: cameraURL) : false
            if !started {
                cameraEnabled = false
                camera.stop()
                cameraMessage = "Camera recording couldn’t start. Screen recording can continue."
            }
        }

        do {
            try stream.addRecordingOutput(output)
            armTimeout(for: stream, message: "Recording did not start. Choose the source and try again.")
            try await stream.startCapture()
            if self.stream !== stream {
                try? await stream.stopCapture()
            }
        } catch {
            guard self.stream === stream else { return }
            failCapture(captureMessage(for: error))
        }
    }

    private func capturePixelScale(for filter: SCContentFilter) -> CGFloat {
        let reported = CGFloat(filter.pointPixelScale)
        let filterScale = reported.isFinite && reported > 0 ? reported : 1
        let displays = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, scale: CGFloat)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (id.uint32Value, screen.backingScaleFactor)
        }

        var source = filter.contentRect
        if #available(macOS 15.2, *) {
            if filter.style == .display, let id = filter.includedDisplays.first?.displayID,
               let display = displays.first(where: { $0.id == id }) {
                return max(filterScale, display.scale)
            }
            if filter.style == .window, let window = filter.includedWindows.first {
                source = window.frame
            }
        }

        // Picker filters can report 1× for a window on a Retina display.
        // Use the display containing the largest visible part of the window.
        var largestArea: CGFloat = 0
        var backingScale = filterScale
        for display in displays {
            let overlap = CGDisplayBounds(display.id).intersection(source)
            guard !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > largestArea {
                largestArea = area
                backingScale = display.scale
            }
        }
        return max(filterScale, backingScale)
    }

    func stop() {
        guard phase == .recording, let stream else { return }
        phase = .stopping
        clickMonitor.stop()
        shortcutMonitor.stop()
        shortcutStatusTask?.cancel()
        shortcutStatusTask = nil
        stopIssued = true
        armTimeout(for: stream, message: "The recording could not be finalized. Choose a source and try again.")
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                guard self.stream === stream else { return }
                message = captureMessage(for: error)
                // If the system stopped the stream concurrently, its output may still finish.
            }
        }
    }

    func save(withoutCamera: Bool = false) {
        guard phase == .pendingSave, let recordingURL else { return }
        preview?.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Walk & Roll \(Date.now.formatted(.iso8601.year().month().day()))"
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        phase = .choosingSaveLocation
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                phase = .pendingSave
                return
            }
            if withoutCamera { preview?.includesCamera = false }
            export(recordingURL, camera: preview?.includesCamera == false ? nil : cameraOverlay, to: destination)
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func discard() {
        guard phase == .pendingSave else { return }
        removeRecording()
        phase = .idle
        message = nil
    }

    private func export(_ source: URL, camera overlay: CameraOverlay?, to destination: URL) {
        phase = .exporting
        message = nil
        progress = 0
        exportTask = Task {
            defer { exportTask = nil }
            do {
                try await MP4Export.save(
                    source, camera: overlay, clicks: clicks, keystrokes: keystrokes,
                    keystrokeDelay: keystrokeDelay, resolution: preview?.resolution ?? resolution,
                    edits: preview?.edits ?? RecordingEdits(), to: destination
                ) { fraction in
                    self.progress = fraction
                }
                savedURL = destination
                phase = .pendingSave
                message = "MP4 saved. You can keep editing and export again, or discard this recording."
            } catch {
                phase = .pendingSave
                if !Task.isCancelled, overlay != nil { canSaveWithoutCamera = true }
                message = Task.isCancelled
                    ? "Export canceled. You can save this recording again."
                    : "Couldn’t save the MP4. \(error.localizedDescription) You can try again."
            }
        }
    }

    private func armTimeout(for stream: SCStream, message: String) {
        timeout?.cancel()
        timeout = Task {
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard self.stream === stream else { return }
            failCapture(self.message ?? message)
        }
    }

    private func clearCapture() {
        clickMonitor.stop()
        shortcutMonitor.stop()
        shortcutStatusTask?.cancel()
        shortcutStatusTask = nil
        shortcutScope = nil
        presenterOverlayActive = false
        timeout?.cancel()
        timeout = nil
        stream = nil
        output = nil
        stopIssued = false
        filter = nil
        sourceName = nil
        sourceApplicationName = nil
        sourcePixelSize = nil
        startedAt = nil
        picker.isActive = false
    }

    private func failCapture(_ explanation: String) {
        if let stream, !stopIssued {
            Task { try? await stream.stopCapture() }
        }
        resetSource()
        message = explanation
    }

    private func resetSource() {
        clearCapture()
        if cameraEnabled { camera.stop() }
        cameraEnabled = false
        screenClock = nil
        removeRecording()
        phase = .idle
    }

    private func removeRecording() {
        preview?.close()
        preview = nil
        savedURL = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        if let cameraOverlay {
            try? FileManager.default.removeItem(at: cameraOverlay.url)
        }
        cameraOverlay = nil
        clicks.removeAll()
        keystrokes.removeAll()
        keystrokeGrouper.reset()
        capturedKeystrokeCount = 0
        shortcutMessage = nil
        canSaveWithoutCamera = false
    }

    private func finishCamera(screenStart: CMTime) async {
        guard cameraEnabled else { return }
        cameraEnabled = false
        let clip = await camera.finishRecording()
        if let clip, screenStart.isNumeric {
            cameraOverlay = CameraOverlay(
                url: clip.url,
                offset: clip.firstFrame - screenStart,
                corner: cameraCorner
            )
        } else {
            if let clip { try? FileManager.default.removeItem(at: clip.url) }
            cameraMessage = "Camera video couldn’t be saved. Your screen recording is ready."
        }
    }

    private func recordClick(_ event: CGEvent) {
        guard phase == .recording, let filter, let screenClock,
              let geometry = screenClock.clickGeometry else { return }
        let point = event.location
        var source = geometry.screenRect
        if #available(macOS 15.2, *) {
            if filter.style == .display, let display = filter.includedDisplays.first {
                source = display.frame
            } else if let window = filter.includedWindows.first {
                guard let bounds = clickedWindowBounds(window.windowID, at: point) else { return }
                source = bounds
            }
        }
        if source.isNull, filter.style == .display { source = filter.contentRect }
        guard let position = geometry.normalizedPosition(of: point, onScreen: source),
              let seconds = screenClock.seconds(for: event) else { return }
        clicks.append(ClickHighlight(position: position, seconds: seconds))
    }

    private func recordShortcut(_ event: CGEvent) {
        guard phase == .recording, !IsSecureEventInputEnabled(), let shortcutScope,
              event.type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        if keystrokeMode == .commandsOnly, event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            keystrokeGrouper.reset()
            return
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard shortcutScope.allowsShortcuts(frontmostPID: frontmostPID) else {
            keystrokeGrouper.reset()
            return
        }
        guard let input = KeystrokeInput.read(event, mode: keystrokeMode) else {
            keystrokeGrouper.reset()
            return
        }
        guard let seconds = screenClock?.seconds(for: event) else {
            return
        }
        keystrokes.append(keystrokeGrouper.append(
            input, at: seconds, source: frontmostPID,
            maximumCharacters: keystrokeGroupLength, pause: keystrokeDelay
        ))
        capturedKeystrokeCount = keystrokes.count
    }

    private func startShortcutMonitoring() {
        guard showKeystrokes else { return }
        guard shortcutScope != nil, screenClock != nil else {
            if shortcutMessage == nil {
                shortcutMessage = "Keystrokes are unavailable because recording setup did not finish."
            }
            return
        }
        shortcutStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, phase == .recording else { return }
                if !CGPreflightListenEventAccess() {
                    shortcutMonitor.stop()
                    shortcutMessage = "Input Monitoring access is off. Screen recording can continue. Allow Walk & Roll in System Settings, then quit and reopen the app."
                    return
                }
                if IsSecureEventInputEnabled() {
                    keystrokeGrouper.reset()
                    shortcutMonitor.stop()
                    shortcutMessage = "Keystrokes are paused because Secure Keyboard Entry is active. macOS blocks shortcut capture while it is enabled."
                } else {
                    if !shortcutMonitor.isRunning,
                       !shortcutMonitor.start(handler: { [weak self] in self?.recordShortcut($0) }) {
                        shortcutMessage = "Keystrokes couldn’t start. Check Input Monitoring in System Settings, then quit and reopen Walk & Roll. Screen recording can continue."
                        return
                    }
                    shortcutMessage = screenClock?.start.isNumeric == true
                        ? nil : "Waiting for the first screen frame to sync keystrokes."
                }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    private func captureMessage(for error: Error) -> String {
        switch (error as? SCStreamError)?.code {
        case .userDeclined, .missingEntitlements:
            return "Screen capture was denied. Choose a source in the macOS picker. If macOS requires it, check System Settings → Privacy & Security → Screen & System Audio Recording."
        case .failedToStartAudioCapture:
            return "System audio couldn’t start. Check Screen & System Audio Recording in System Settings, or try with System audio off."
        case .failedToStartMicrophoneCapture:
            return "Microphone capture couldn’t start. Check your input device and Microphone permissions, or try with Microphone off."
        case .noCaptureSource, .systemStoppedStream:
            return "macOS stopped sharing the source. Check that the window or display is still available."
        case .userStopped:
            return "Sharing stopped in macOS."
        default:
            return "Screen capture ended. \(error.localizedDescription)"
        }
    }
}

extension Recorder: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard phase == .picking, stream == nil else { return }
            self.filter = filter
            updateSourceDescription(filter)
            let scale = capturePixelScale(for: filter)
            let pixels = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
            sourcePixelSize = pixels.width.isFinite && pixels.height.isFinite && pixels.width > 0 && pixels.height > 0
                ? pixels : nil
            phase = .ready
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard phase == .picking, stream == nil else { return }
            phase = filter == nil ? .idle : .ready
            if filter == nil { picker.isActive = false }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            guard phase == .picking else { return }
            phase = filter == nil ? .idle : .ready
            if filter == nil { picker.isActive = false }
            message = "The macOS picker couldn’t open. \(error.localizedDescription)"
        }
    }
}

extension Recorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func outputVideoEffectDidStart(for stream: SCStream) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            presenterOverlayActive = true
        }
    }

    nonisolated func outputVideoEffectDidStop(for stream: SCStream) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            presenterOverlayActive = false
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [self] in
            guard output === recordingOutput, phase == .starting else { return }
            timeout?.cancel()
            timeout = nil
            startedAt = .now
            phase = .recording
            if showClickHighlights, screenClock != nil,
               !clickMonitor.start(handler: { [weak self] in self?.recordClick($0) }) {
                message = "Click highlights couldn’t start. Screen recording can continue."
            }
            startShortcutMonitoring()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard output === recordingOutput else { return }
            if phase == .recording || phase == .starting {
                message = "Capture ended. You can save what was recorded."
                if let stream, !stopIssued {
                    Task { try? await stream.stopCapture() }
                }
            }
            phase = .stopping
            let screenStart = screenClock?.start ?? .invalid
            screenClock = nil
            clearCapture()
            await finishCamera(screenStart: screenStart)
            if let recordingURL {
                preview = RecordingPreview(source: recordingURL, camera: cameraOverlay, clicks: clicks,
                                           keystrokes: keystrokes, keystrokeDelay: keystrokeDelay, resolution: resolution)
            }
            phase = .pendingSave
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard output === recordingOutput else { return }
            failCapture(message ?? captureMessage(for: error))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            let explanation = captureMessage(for: error)
            if phase == .starting {
                failCapture(explanation)
            } else {
                message = explanation
                phase = .stopping
                clickMonitor.stop()
                shortcutMonitor.stop()
                shortcutStatusTask?.cancel()
                shortcutStatusTask = nil
                stopIssued = true
                armTimeout(for: stream, message: explanation)
            }
        }
    }
}
