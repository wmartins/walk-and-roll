import Foundation
import CoreGraphics

/// Non-destructive instructions in seconds from the first screen frame.
struct RecordingEdits: Equatable, Sendable {
    var zooms: [ZoomEffect] = []
    var blurredBackdrop = false

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

    init(id: UUID = UUID(), start: Double, duration: Double = 3, magnification: Double = 2, focalPoint: CGPoint) {
        self.id = id
        self.start = start
        self.duration = duration
        self.magnification = magnification
        self.focalPoint = focalPoint
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

    /// Bottom-left Core Image coordinates. The crop always stays inside the screen.
    static func crop(in content: CGRect, zoom: ZoomEffect?, at seconds: Double) -> CGRect {
        let scale = zoom?.scale(at: seconds) ?? 1
        let size = CGSize(width: content.width / scale, height: content.height / scale)
        let focal = zoom?.focalPoint ?? CGPoint(x: 0.5, y: 0.5)
        let center = CGPoint(x: content.minX + min(1, max(0, focal.x)) * content.width,
                             y: content.minY + (1 - min(1, max(0, focal.y))) * content.height)
        return CGRect(x: max(content.minX, min(content.maxX - size.width, center.x - size.width / 2)),
                      y: max(content.minY, min(content.maxY - size.height, center.y - size.height / 2)),
                      width: size.width, height: size.height)
    }

    static func zoomTransform(in content: CGRect, zoom: ZoomEffect?, at seconds: Double) -> CGAffineTransform {
        let crop = crop(in: content, zoom: zoom, at: seconds)
        let scale = content.width / crop.width
        return CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY))
    }

    /// A click in the displayed output frame, normalized with top-left origin.
    /// Reject padding; invert the current zoom so clicking zoomed footage stays accurate.
    static func sourcePoint(at point: CGPoint, content: CGRect, canvas: CGSize,
                            zoom: ZoomEffect?, seconds: Double) -> CGPoint? {
        let output = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        guard output.x >= content.minX, output.x <= content.maxX,
              output.y >= content.minY, output.y <= content.maxY else { return nil }
        let source = output.applying(zoomTransform(in: content, zoom: zoom, at: seconds).inverted())
        return CGPoint(x: min(1, max(0, (source.x - content.minX) / content.width)),
                       y: min(1, max(0, 1 - (source.y - content.minY) / content.height)))
    }
}
