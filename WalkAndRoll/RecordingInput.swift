import AppKit
import Carbon
import ScreenCaptureKit

enum KeystrokeMode: String, CaseIterable, Identifiable {
    case commandsOnly = "Commands only"
    case allKeys = "All keystrokes"

    var id: Self { self }
}

enum KeystrokeInput: Equatable {
    case text(String)
    case key(String)

    static func read(_ event: CGEvent, mode: KeystrokeMode) -> Self? {
        guard event.type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
        let isCommand = !event.flags.intersection([.maskCommand, .maskControl]).isEmpty
        if mode == .commandsOnly || isCommand {
            return KeystrokeBadge.label(for: event).map(Self.key)
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if code == kVK_Space, !event.flags.contains(.maskAlternate) { return .text("␣") }
        if let key = KeystrokeBadge.specialKeys[code] {
            return .key(KeystrokeBadge.modifiers(for: event.flags) + key)
        }
        guard let text = NSEvent(cgEvent: event)?.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && $0.properties.generalCategory != .privateUse }) else { return nil }
        return .text(text)
    }
}

struct KeystrokeGrouper {
    private var text = ""
    private var repeatedKey: String?
    private var keyPressCount = 0
    private var lastTime: Double?
    private var sourcePID: pid_t?

    mutating func append(
        _ input: KeystrokeInput, at seconds: Double, source: pid_t?,
        maximumCharacters: Int, pause: Double
    ) -> KeystrokeBadge {
        let sameBurst = lastTime.map { seconds >= $0 && seconds < $0 + pause } == true
            && source == sourcePID
        let label: String
        switch input {
        case let .text(characters):
            let limit = max(1, maximumCharacters)
            let continuation = sameBurst && repeatedKey == nil && text.count + characters.count <= limit
            text = (continuation ? text : "") + String(characters.suffix(limit))
            repeatedKey = nil
            keyPressCount = 0
            label = text
        case let .key(key):
            keyPressCount = sameBurst && repeatedKey == key ? keyPressCount + 1 : 1
            repeatedKey = key
            text = ""
            label = keyPressCount > 1 ? "\(key) ×\(keyPressCount)" : key
        }
        lastTime = seconds
        sourcePID = source
        return KeystrokeBadge(label: label, seconds: seconds)
    }

    mutating func reset() {
        text = ""
        repeatedKey = nil
        keyPressCount = 0
        lastTime = nil
        sourcePID = nil
    }
}

struct ClickHighlight: Sendable {
    /// Position in the recorded frame, normalized to 0...1 with the origin at the top left.
    let position: CGPoint
    let seconds: Double
}

struct KeystrokeBadge: Sendable {
    let label: String
    let seconds: Double
    static let fadeDuration = 0.35

    static func label(for event: CGEvent) -> String? {
        let flags = event.flags
        guard event.type == .keyDown, !flags.intersection([.maskCommand, .maskControl]).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let key = keyLabel(event) else { return nil }

        return modifiers(for: flags) + key
    }

    static func modifiers(for flags: CGEventFlags) -> String {
        var modifiers = ""
        if flags.contains(.maskCommand) { modifiers += "⌘" }
        if flags.contains(.maskControl) { modifiers += "⌃" }
        if flags.contains(.maskAlternate) { modifiers += "⌥" }
        if flags.contains(.maskShift) { modifiers += "⇧" }
        return modifiers
    }

    static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    private static func keyLabel(_ event: CGEvent) -> String? {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let name = specialKeys[code] { return name }
        // Translate using the current layout without changing the text input state.
        let modifiers: NSEvent.ModifierFlags = event.flags.contains(.maskCommand) ? .command : []
        guard let characters = NSEvent(cgEvent: event)?.characters(byApplyingModifiers: modifiers),
              characters.count == 1, characters.first?.isWhitespace == false,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && $0.properties.generalCategory != .privateUse }) else { return nil }
        return characters.uppercased()
    }
}

enum ShortcutScope {
    case display
    case window(owner: pid_t)

    init?(filter: SCContentFilter) {
        if filter.style == .display {
            self = .display
            return
        }
        guard filter.style == .window else { return nil }
        let owner: pid_t?
        if #available(macOS 15.2, *) {
            let windows = filter.includedWindows
            let owners = Set(windows.compactMap { $0.owningApplication?.processID })
            if owners.count == 1, windows.allSatisfy({ $0.owningApplication != nil }) {
                owner = owners.first
            } else {
                owner = Self.owner(ofWindowAt: filter.contentRect)
            }
        } else {
            // Older picker filters expose bounds but no window ID. Require an unambiguous match.
            owner = Self.owner(ofWindowAt: filter.contentRect)
        }
        guard let owner, owner > 0 else { return nil }
        self = .window(owner: owner)
    }

    func allowsShortcuts(frontmostPID: pid_t?) -> Bool {
        switch self {
        case .display: true
        case let .window(owner): frontmostPID == owner
        }
    }

    private static func owner(ofWindowAt rect: CGRect) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let matches = windows.filter { info in
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary) == rect
        }
        guard matches.count == 1 else { return nil }
        return matches.first?[kCGWindowOwnerPID as String] as? pid_t
    }
}

struct CaptureGeometry {
    let screenRect: CGRect
    let contentPixels: CGRect
    let framePixels: CGSize

    func normalizedPosition(of point: CGPoint, onScreen source: CGRect) -> CGPoint? {
        guard source.contains(point), source.width > 0, source.height > 0,
              framePixels.width > 0, framePixels.height > 0 else { return nil }
        let x = contentPixels.minX + (point.x - source.minX) / source.width * contentPixels.width
        let y = contentPixels.minY + (point.y - source.minY) / source.height * contentPixels.height
        let position = CGPoint(x: x / framePixels.width, y: y / framePixels.height)
        guard (0...1).contains(position.x), (0...1).contains(position.y) else { return nil }
        return position
    }
}

final class ScreenRecordingClock: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "WalkAndRoll.screen-clock")
    private let tracksClicks: Bool
    private var firstFrame = CMTime.invalid
    private var geometry: CaptureGeometry?

    init(tracksClicks: Bool) {
        self.tracksClicks = tracksClicks
    }

    var start: CMTime { queue.sync { firstFrame } }
    var clickGeometry: CaptureGeometry? { queue.sync { geometry } }

    func seconds(for event: CGEvent) -> Double? {
        guard let timestamp = Int64(exactly: event.timestamp) else { return nil }
        // CGEvent timestamps and the converted screen timestamps both use time since boot.
        let time = CMTime(value: timestamp, timescale: 1_000_000_000)
        let seconds = (time - start).seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, tracksClicks || !firstFrame.isNumeric,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { return }

        if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue {
            geometry = nil
            return
        }
        guard status == SCFrameStatus.complete.rawValue, let buffer = sample.imageBuffer else { return }

        if !firstFrame.isNumeric, let clock = stream.synchronizationClock {
            firstFrame = clock.convertTime(sample.presentationTimeStamp, to: CMClock.hostTimeClock)
        }
        guard tracksClicks else { return }

        let frame = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let bounds = CGRect(origin: .zero, size: frame)
        let scale = info[.scaleFactor] as? CGFloat ?? 1
        let pixels = Self.rect(.contentRect, in: info)?
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        let content = pixels?.intersection(bounds) ?? bounds
        guard !content.isEmpty else {
            geometry = nil
            return
        }
        geometry = CaptureGeometry(
            screenRect: Self.rect(.screenRect, in: info) ?? .null,
            contentPixels: content, framePixels: frame
        )
    }

    private static func rect(_ key: SCStreamFrameInfo, in info: [SCStreamFrameInfo: Any]) -> CGRect? {
        guard let values = info[key] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: values as CFDictionary)
    }
}

@MainActor
final class RecordingClickMonitor {
    private var global: Any?
    private var local: Any?

    func start(handler: @escaping @MainActor (CGEvent) -> Void) -> Bool {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let observe: (NSEvent) -> Void = { event in
            guard let click = event.cgEvent else { return }
            // AppKit invokes both event monitors on the main thread.
            MainActor.assumeIsolated { handler(click) }
        }
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: observe) else { return false }
        self.global = global
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            observe(event)
            return event
        }
        guard local != nil else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }
}

@MainActor
final class RecordingShortcutMonitor {
    private var source: CFRunLoopSource?
    private var callback: Callback?

    var isRunning: Bool { callback != nil }

    func start(handler: @escaping @MainActor (CGEvent) -> Void) -> Bool {
        stop()
        let callback = Callback(handler)
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
                // The tap is installed on the main run loop.
                MainActor.assumeIsolated {
                    switch type {
                    case .keyDown: callback.handler(event)
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if let tap = callback.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    default: break
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(callback).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        callback.tap = tap
        self.callback = callback
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = callback?.tap { CFMachPortInvalidate(tap) }
        source = nil
        callback = nil
    }

    private final class Callback {
        let handler: @MainActor (CGEvent) -> Void
        var tap: CFMachPort?

        init(_ handler: @escaping @MainActor (CGEvent) -> Void) {
            self.handler = handler
        }
    }
}

/// WindowServer returns updates to the position even when the captured window did not redraw.
func clickedWindowBounds(_ window: CGWindowID, at point: CGPoint) -> CGRect? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    for info in windows {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let values = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: values as CFDictionary),
              bounds.contains(point) else { continue }
        if id == window { return bounds }
        if info[kCGWindowLayer as String] as? Int == 0 { return nil }
    }
    return nil
}
