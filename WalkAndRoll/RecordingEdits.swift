import Foundation
import CoreGraphics

enum RecordingFrameStyle: String, CaseIterable, Identifiable, Sendable {
    case windowFrame = "Window Frame"
    case plain = "Plain"

    var id: Self { self }
    var explanation: String {
        switch self {
        case .windowFrame: "Equal margins and a soft shadow on a light background."
        case .plain: "Use the source’s proportions without a background."
        }
    }
}

/// Non-destructive instructions in seconds from the first screen frame.
struct RecordingEdits: Equatable, Sendable {
    var zooms: [ZoomEffect] = []
    var frameStyle: RecordingFrameStyle = .plain

    /// Labels describe edits but do not change the rendered video.
    var renderingEdits: RecordingEdits {
        var result = self
        for index in result.zooms.indices { result.zooms[index].name = "" }
        return result
    }

    /// Later starts truncate earlier zooms, including their ease-out. At equal starts,
    /// the most recently inserted zoom wins. No transforms are stacked.
    var resolvedZooms: [ZoomEffect] {
        let ordered = zooms.enumerated().filter { $0.element.isValid }.sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        return ordered.enumerated().compactMap { index, zoom in
            var result = zoom
            if index + 1 < ordered.count {
                result.duration = min(result.duration, ordered[index + 1].start - result.start)
            }
            return result.duration > 0 ? result : nil
        }
    }

    func zoom(at seconds: Double) -> ZoomEffect? {
        resolvedZooms.last { seconds >= $0.start && seconds < $0.start + $0.duration }
    }
}

struct ZoomEffect: Identifiable, Equatable, Sendable {
    let id: UUID
    var start: Double
    var duration: Double
    var magnification: Double
    /// Oriented screen coordinates, normalized with origin at the top left.
    var focalPoint: CGPoint
    var name: String

    init(id: UUID = UUID(), start: Double, duration: Double = 3, magnification: Double = 2, focalPoint: CGPoint, name: String = "") {
        self.id = id
        self.start = start
        self.duration = duration
        self.magnification = magnification
        self.focalPoint = focalPoint
        self.name = name
    }

    var isValid: Bool {
        start.isFinite && start >= 0 && duration.isFinite && duration > 0
            && magnification.isFinite && magnification >= 1 && magnification <= 4
            && focalPoint.x.isFinite && focalPoint.y.isFinite
    }

    func scale(at seconds: Double) -> CGFloat {
        let age = seconds - start
        guard age >= 0, age < duration else { return 1 }
        let ramp = min(0.4, duration / 2)
        let phase = max(0, min(1, min(age, duration - age) / ramp))
        let eased = phase * phase * (3 - 2 * phase)
        return 1 + CGFloat((magnification - 1) * eased)
    }
}

/// Shared geometry for the compositor and inverse preview hit testing.
enum RecordingGeometry {
    static func fittedRect(source: CGSize, canvas: CGSize) -> CGRect {
        let scale = min(canvas.width / source.width, canvas.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func cornerRadius(in content: CGRect, frameStyle: RecordingFrameStyle) -> CGFloat {
        frameStyle == .windowFrame ? min(content.width, content.height) * 0.035 : 0
    }

    /// Bottom-left Core Image coordinates. Keep a zoom's rounded viewport inside
    /// the rounded source, so flattened black capture corners never enter the crop.
    static func crop(in content: CGRect, zoom: ZoomEffect?, at seconds: Double,
                     frameStyle: RecordingFrameStyle = .plain) -> CGRect {
        let scale = zoom?.scale(at: seconds) ?? 1
        let size = CGSize(width: content.width / scale, height: content.height / scale)
        let focal = zoom?.focalPoint ?? CGPoint(x: 0.5, y: 0.5)
        let center = CGPoint(x: content.minX + min(1, max(0, focal.x)) * content.width,
                             y: content.minY + (1 - min(1, max(0, focal.y))) * content.height)
        let inset = cornerRadius(in: content, frameStyle: frameStyle) * (1 - 1 / scale)
        return CGRect(x: max(content.minX + inset, min(content.maxX - inset - size.width, center.x - size.width / 2)),
                      y: max(content.minY + inset, min(content.maxY - inset - size.height, center.y - size.height / 2)),
                      width: size.width, height: size.height)
    }

    static func zoomTransform(in content: CGRect, zoom: ZoomEffect?, at seconds: Double,
                              frameStyle: RecordingFrameStyle = .plain) -> CGAffineTransform {
        let crop = crop(in: content, zoom: zoom, at: seconds, frameStyle: frameStyle)
        let scale = content.width / crop.width
        return CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
    }

    /// A click in the displayed output frame, normalized with top-left origin.
    /// Reject padding; invert the current zoom so clicking zoomed footage stays accurate.
    static func sourcePoint(at point: CGPoint, content: CGRect, canvas: CGSize,
                            zoom: ZoomEffect?, seconds: Double, frameStyle: RecordingFrameStyle = .plain) -> CGPoint? {
        let output = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        guard output.x >= content.minX, output.x <= content.maxX,
              output.y >= content.minY, output.y <= content.maxY else { return nil }
        let radius = cornerRadius(in: content, frameStyle: frameStyle)
        if radius > 0 {
            let interior = content.insetBy(dx: radius, dy: radius)
            let nearest = CGPoint(x: max(interior.minX, min(interior.maxX, output.x)),
                                  y: max(interior.minY, min(interior.maxY, output.y)))
            guard hypot(output.x - nearest.x, output.y - nearest.y) <= radius else { return nil }
        }
        let source = output.applying(zoomTransform(in: content, zoom: zoom, at: seconds, frameStyle: frameStyle).inverted())
        return CGPoint(x: min(1, max(0, (source.x - content.minX) / content.width)),
                       y: min(1, max(0, 1 - (source.y - content.minY) / content.height)))
    }
}
