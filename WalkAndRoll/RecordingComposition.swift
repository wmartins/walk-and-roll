import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

struct CameraOverlay {
    let url: URL
    let offset: CMTime
    let corner: CameraCorner
}

struct CameraLayer {
    let trackID: CMPersistentTrackID
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
    let mask: CIImage

    init(track: AVAssetTrack, timeRange: CMTimeRange, transform: CGAffineTransform, bubble: CGRect) {
        trackID = track.trackID
        self.timeRange = timeRange
        self.transform = transform
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = bubble
        shape.radius = Float(bubble.width * 0.22)
        mask = shape.outputImage ?? .empty()
    }
}

final class RecordingCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening: Bool
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let screenID: CMPersistentTrackID
    let screenTransform: CGAffineTransform
    let screenSize: CGSize
    let contentRect: CGRect
    let edits: RecordingEdits
    let windowFrame: WindowFrameRendering?
    let camera: CameraLayer?
    let clicks: [ClickHighlight]
    let keystrokes: [KeystrokeBadge]
    let keystrokeDelay: Double

    init(
        timeRange: CMTimeRange, screen: AVAssetTrack, screenSize: CGSize, screenTransform: CGAffineTransform,
        contentRect: CGRect, edits: RecordingEdits,
        camera: CameraLayer?, clicks: [ClickHighlight], keystrokes: [KeystrokeBadge], keystrokeDelay: Double
    ) {
        self.timeRange = timeRange
        screenID = screen.trackID
        self.screenSize = screenSize
        self.screenTransform = screenTransform
        self.contentRect = contentRect
        var snapshot = edits.renderingEdits
        snapshot.zooms = snapshot.resolvedZooms
        self.edits = snapshot
        windowFrame = edits.frameStyle == .windowFrame
            ? WindowFrameRendering(content: contentRect) : nil
        self.camera = camera
        self.clicks = clicks.sorted { $0.seconds < $1.seconds }
        self.keystrokes = keystrokes.sorted { $0.seconds < $1.seconds }
        self.keystrokeDelay = keystrokeDelay.isFinite ? max(0, keystrokeDelay) : 1.5
        containsTweening = !clicks.isEmpty || !keystrokes.isEmpty || !edits.zooms.isEmpty
        requiredSourceTrackIDs = ([screen.trackID] + (camera.map { [$0.trackID] } ?? [])).map { NSNumber(value: $0) }
    }

    // Preferred track transforms use a top-left origin. Core Image uses bottom-left coordinates.
    static func imageTransform(size: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: size).applying(preferred)
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            .concatenating(preferred)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -bounds.minX, ty: bounds.maxY))
    }

    static func makeBadge(_ label: String, canvas: CGSize, avoiding camera: CGRect?) -> CIImage? {
        let edge = min(canvas.width, canvas.height)
        let fontSize = edge * 0.034
        let margin = edge * 0.04
        guard let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) else { return nil }
        let text = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        var line = CTLineCreateWithAttributedString(text)
        let maximumTextWidth = max(1, canvas.width - 2 * margin - 1.5 * fontSize)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > maximumTextWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
            line = CTLineCreateTruncatedLine(line, maximumTextWidth, .end, ellipsis) ?? ellipsis
        }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let width = ceil(textWidth + 1.5 * fontSize)
        let height = ceil(ascent + descent + 0.55 * fontSize)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let box = CGRect(x: 0, y: 0, width: width, height: height)
        let corner = height * 0.24
        bitmap.setFillColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.92)
        bitmap.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
        bitmap.fillPath()
        bitmap.textPosition = CGPoint(x: (width - textWidth) / 2, y: (height - ascent - descent) / 2 + descent)
        CTLineDraw(line, bitmap)

        let x = (canvas.width - width) / 2
        let bottom = box.offsetBy(dx: x, dy: margin)
        let y = camera.map { $0.intersects(bottom) } == true ? canvas.height - height - margin : margin
        return bitmap.makeImage().map {
            CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        }
    }
}

/// Immutable masks and shadow are shared by every frame in a composition.
/// Clip flattened black capture corners without adding a stroke or changing pixels.
struct WindowFrameRendering {
    let mask: CIImage
    let background: CIImage

    init(content: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: content.maxX + content.minX, height: content.maxY + content.minY)
        let edge = min(content.width, content.height)
        mask = Self.roundedMask(content, radius: RecordingGeometry.cornerRadius(in: content, frameStyle: .windowFrame)).cropped(to: bounds)
        var backdrop = CIImage(color: CIColor(red: 0.92, green: 0.93, blue: 0.95)).cropped(to: bounds)
        for (opacity, sigma, offset) in [(0.18, edge * 0.017, -edge * 0.005), (0.10, edge * 0.004, -edge * 0.002)] {
            let color = CIFilter.colorMatrix()
            color.inputImage = mask
            color.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            color.gVector = color.rVector
            color.bVector = color.rVector
            color.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
            let shadow = (color.outputImage ?? mask).applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(translationX: 0, y: offset)).cropped(to: bounds)
            backdrop = shadow.composited(over: backdrop)
        }
        background = backdrop
    }

    func composite(_ image: CIImage) -> CIImage {
        Self.blend(image, over: background, mask: mask)
    }

    private static func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = rect
        shape.radius = Float(radius)
        return shape.outputImage ?? .empty()
    }

    private static func blend(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? image
    }
}

/// Sample the original screen pixels at the final scale. Bicubic interpolation
/// keeps enlarged text edges firmer than bilinear interpolation without inventing detail.
enum RecordingImageSampling {
    static func transform(_ image: CIImage, by transform: CGAffineTransform) -> CIImage {
        let scale = hypot(transform.a, transform.b)
        guard scale > 1.0001 else {
            return image.transformed(by: transform, highQualityDownsample: true)
        }
        let orientation = CGAffineTransform(a: transform.a / scale, b: transform.b / scale,
                                            c: transform.c / scale, d: transform.d / scale, tx: 0, ty: 0)
        let resize = CIFilter.bicubicScaleTransform()
        resize.inputImage = image.clampedToExtent().transformed(by: orientation)
        resize.scale = Float(scale)
        resize.aspectRatio = 1
        resize.parameterB = 0
        // Zero outer-lobe weight avoids dark/bright halos around high-contrast UI text.
        resize.parameterC = 0
        let scaled = resize.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(orientation))
        return scaled.transformed(by: CGAffineTransform(translationX: transform.tx, y: transform.ty))
    }
}

final class RecordingCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Derive the video profile from Core Video's tags. The similarly named
    // Core Graphics ITU-R 709 space can use a different display transfer curve.
    private let outputColorSpace = CVImageBufferCreateColorSpaceFromAttachments([
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ] as CFDictionary)!.takeRetainedValue()
    // NSCache synchronizes access and may evict images between concurrent render requests.
    nonisolated(unsafe) private let badgeCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    #if compiler(>=6.2)
    typealias Attributes = [String: any Sendable]
    #else
    typealias Attributes = [String: Any]
    #endif

    var sourcePixelBufferAttributes: Attributes? { requiredPixelBufferAttributesForRenderContext }
    let requiredPixelBufferAttributesForRenderContext: Attributes = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? RecordingCompositionInstruction,
              let screen = request.sourceFrame(byTrackID: instruction.screenID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "WalkAndRoll.RecordingCompositor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "A screen frame couldn’t be rendered."
            ]))
            return
        }

        let bounds = CGRect(origin: .zero, size: request.renderContext.size)
        let seconds = (request.compositionTime - instruction.timeRange.start).seconds
        let content = instruction.contentRect
        let original = CIImage(cvPixelBuffer: screen)
        let zoom = instruction.edits.zoom(at: seconds)
        let zoomTransform = RecordingGeometry.zoomTransform(in: content, zoom: zoom, at: seconds, frameStyle: instruction.edits.frameStyle)
        // Combine framing and zoom before resampling, so a 1080p edit can use
        // every available original pixel rather than enlarging a reduced intermediate.
        let sampled = RecordingImageSampling.transform(original, by: instruction.screenTransform.concatenating(zoomTransform))
        // Even output dimensions can leave a fractional pixel at an edge. Extend
        // that edge's own color instead of exposing a dark seam behind the mask.
        var image = (instruction.windowFrame == nil ? sampled : sampled.clampedToExtent()).cropped(to: content)
        for click in activeClicks(instruction.clicks, at: seconds) {
            let point = CGPoint(
                x: click.position.x * instruction.screenSize.width,
                y: (1 - click.position.y) * instruction.screenSize.height
            ).applying(instruction.screenTransform)
            if let ring = ring(at: point, progress: seconds - click.seconds, canvas: bounds.size) {
                image = ring.transformed(by: zoomTransform).cropped(to: content).composited(over: image)
            }
        }

        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        image = instruction.windowFrame?.composite(image) ?? image.composited(over: background)

        if let layer = instruction.camera,
           layer.timeRange.containsTime(request.compositionTime),
           let camera = request.sourceFrame(byTrackID: layer.trackID) {
            let foreground = CIImage(cvPixelBuffer: camera)
                .transformed(by: layer.transform)
                .cropped(to: layer.mask.extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = foreground
            blend.backgroundImage = image
            blend.maskImage = layer.mask
            image = blend.outputImage ?? image
        }

        let overlayBounds = instruction.windowFrame == nil ? bounds : content
        let badgeCamera = instruction.camera?.mask.extent.offsetBy(dx: -overlayBounds.minX, dy: -overlayBounds.minY)
        if let keystroke = activeKeystroke(instruction.keystrokes, at: seconds, delay: instruction.keystrokeDelay),
           let badge = badge(for: keystroke.label, canvas: overlayBounds.size, avoiding: badgeCamera) {
            let age = seconds - keystroke.seconds
            let opacity = min(1, (instruction.keystrokeDelay + KeystrokeBadge.fadeDuration - age) / KeystrokeBadge.fadeDuration)
            let fade = CIFilter.colorMatrix()
            fade.inputImage = badge.transformed(by: CGAffineTransform(translationX: overlayBounds.minX, y: overlayBounds.minY))
            fade.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
            image = (fade.outputImage ?? badge).composited(over: image)
        }

        render(image, to: output, bounds: bounds)
        request.finish(withComposedVideoFrame: output)
    }

    func render(_ image: CIImage, to output: CVPixelBuffer, bounds: CGRect) {
        let renderColorSpace = CVImageBufferGetColorSpace(output)?.takeUnretainedValue() ?? outputColorSpace
        context.render(image, to: output, bounds: bounds, colorSpace: renderColorSpace)
    }

    private static let ringDuration = 0.4

    private func badge(for label: String, canvas: CGSize, avoiding camera: CGRect?) -> CIImage? {
        let key = "\(canvas)/\(String(describing: camera))/\(label)" as NSString
        if let image = badgeCache.object(forKey: key) { return image }
        guard let image = RecordingCompositionInstruction.makeBadge(label, canvas: canvas, avoiding: camera) else { return nil }
        badgeCache.setObject(image, forKey: key, cost: Int(image.extent.width * image.extent.height) * 4)
        return image
    }

    private func activeKeystroke(_ keystrokes: [KeystrokeBadge], at seconds: Double, delay: Double) -> KeystrokeBadge? {
        var lower = 0
        var upper = keystrokes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if keystrokes[middle].seconds <= seconds {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0, seconds - keystrokes[lower - 1].seconds < delay + KeystrokeBadge.fadeDuration else { return nil }
        return keystrokes[lower - 1]
    }

    private func activeClicks(_ clicks: [ClickHighlight], at seconds: Double) -> ArraySlice<ClickHighlight> {
        // Find the first click that has not faded yet without scanning the whole recording.
        var lower = 0
        var upper = clicks.count
        let cutoff = seconds - Self.ringDuration
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if clicks[middle].seconds <= cutoff {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return clicks[lower...].prefix { $0.seconds <= seconds }
    }

    private func ring(at point: CGPoint, progress elapsed: Double, canvas: CGSize) -> CIImage? {
        let progress = elapsed / Self.ringDuration
        let edge = min(canvas.width, canvas.height)
        let radius = edge * (0.012 + 0.026 * progress)
        let lineWidth = max(2, edge * 0.0035)
        let size = Int(ceil(2 * (radius + lineWidth + 2)))
        guard let bitmap = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let center = CGFloat(size) / 2
        let circle = CGRect(x: center - radius, y: center - radius, width: radius * 2, height: radius * 2)
        let opacity = 1 - progress
        bitmap.setStrokeColor(red: 0.09, green: 0.06, blue: 0.03, alpha: opacity * 0.8)
        bitmap.setLineWidth(lineWidth + 2)
        bitmap.strokeEllipse(in: circle)
        bitmap.setStrokeColor(red: 1, green: 0.77, blue: 0.18, alpha: opacity)
        bitmap.setLineWidth(lineWidth)
        bitmap.strokeEllipse(in: circle)
        return bitmap.makeImage().map { ring in
            CIImage(cgImage: ring).transformed(by: CGAffineTransform(
                translationX: point.x - center, y: point.y - center
            ))
        }
    }
}
