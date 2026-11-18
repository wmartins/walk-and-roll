import AppKit
import AVFoundation
import CoreImage
import Testing
@testable import WalkAndRoll

struct MediaFixture {
    let directory: URL
    let screen: URL
    let camera: URL
    let size: CGSize

    @MainActor
    init(size: CGSize = CGSize(width: 640, height: 360), frames: Int = 90) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WalkAndRollTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        screen = directory.appendingPathComponent("screen.mp4")
        camera = directory.appendingPathComponent("camera.mp4")
        self.size = size
        do {
            try await TestMedia.makeVideo(at: screen, size: size, frames: frames)
            try await TestMedia.makeVideo(at: camera, size: CGSize(width: 180, height: 180), camera: true)
        } catch {
            remove()
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    var overlay: CameraOverlay {
        CameraOverlay(url: camera, offset: CMTime(seconds: 0.3, preferredTimescale: 600), corner: .bottomRight)
    }
    var edits: RecordingEdits {
        RecordingEdits(zooms: [
            ZoomEffect(start: 0.2, duration: 1.8, magnification: 2, focalPoint: CGPoint(x: 0.8, y: 0.3)),
            ZoomEffect(start: 1.7, duration: 1, magnification: 3, focalPoint: CGPoint(x: 0, y: 1))
        ])
    }
    var clicks: [ClickHighlight] { [ClickHighlight(position: CGPoint(x: 0.75, y: 0.3), seconds: 0.7)] }
    var keystrokes: [KeystrokeBadge] { [KeystrokeBadge(label: "⌘C ×3", seconds: 0.1)] }

    @MainActor
    func preview() -> RecordingPreview {
        RecordingPreview(source: screen, camera: overlay, clicks: clicks, keystrokes: keystrokes,
                         keystrokeDelay: 1.5, resolution: .sharper)
    }
}

@MainActor
enum TestMedia {
    static let context = CIContext()

    static func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for media state")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func makeVideo(at url: URL, size: CGSize, camera: Bool = false, frames: Int = 90, imageOverride: CIImage? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting(), "Video fixture writer could not start")
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        try #require(status == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        let bounds = CGRect(origin: .zero, size: size)
        var image = CIImage(color: CIColor(red: 0.08, green: 0.22, blue: 0.35)).cropped(to: bounds)
        if camera {
            image = CIImage(color: CIColor(red: 0.95, green: 0.05, blue: 0.75)).cropped(to: bounds)
        } else {
            for x in stride(from: 0, to: Int(size.width), by: 32) {
                image = CIImage(color: CIColor(red: 0.15, green: 0.7, blue: 0.65))
                    .cropped(to: CGRect(x: x, y: 0, width: 2, height: Int(size.height))).composited(over: image)
            }
            for y in stride(from: 0, to: Int(size.height), by: 32) {
                image = CIImage(color: CIColor(red: 0.15, green: 0.7, blue: 0.65))
                    .cropped(to: CGRect(x: 0, y: y, width: Int(size.width), height: 2)).composited(over: image)
            }
            let target = CGRect(x: size.width * 0.75 - 4, y: size.height * 0.7 - 4, width: 8, height: 8)
            image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: target).composited(over: image)
        }
        context.render(imageOverride ?? image, to: pixelBuffer)
        for frame in 0..<frames {
            try await waitUntil { input.isReadyForMoreMediaData || writer.status == .failed }
            try #require(writer.status == .writing)
            try #require(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed, "Video fixture did not finish")
    }

    static func frame(_ prepared: MP4Export.Prepared, at seconds: Double) async throws -> CGImage {
        try await sample(prepared, at: seconds).image
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        try await sample(url, at: seconds).image
    }

    static func sample(_ prepared: MP4Export.Prepared, at seconds: Double) async throws -> (image: CGImage, actualTime: CMTime) {
        let generator = AVAssetImageGenerator(asset: prepared.asset)
        generator.videoComposition = prepared.video
        return try await sample(generator, at: seconds)
    }

    static func sample(_ url: URL, at seconds: Double) async throws -> (image: CGImage, actualTime: CMTime) {
        try await sample(AVAssetImageGenerator(asset: AVURLAsset(url: url)), at: seconds)
    }

    private static func sample(_ generator: AVAssetImageGenerator, at seconds: Double) async throws -> (image: CGImage, actualTime: CMTime) {
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    static func saveParityFailure(
        fixture: MediaFixture, output: URL, seconds: Double, difference: Double,
        preview: (image: CGImage, actualTime: CMTime), encoded: (image: CGImage, actualTime: CMTime),
        source: CGImage? = nil, threshold: Double = 9
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["WALK_AND_ROLL_TEST_ARTIFACTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("preview-export-\(seconds)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images = [("preview", preview.image), ("encoded", encoded.image)]
        if let source { images.append(("source", source)) }
        for (name, image) in images {
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        for (name, source) in [("screen.mp4", fixture.screen), ("camera.mp4", fixture.camera), ("export.mp4", output)] {
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        let details = """
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Requested time: \(seconds)
        Preview actual time: \(preview.actualTime.seconds)
        Encoded actual time: \(encoded.actualTime.seconds)
        Preview color space: \(String(describing: preview.image.colorSpace))
        Encoded color space: \(String(describing: encoded.image.colorSpace))
        Mean RGB difference: \(difference) (required: < \(threshold))
        """
        try details.write(to: directory.appendingPathComponent("comparison.txt"), atomically: true, encoding: .utf8)
        print("Saved frame comparison diagnostics to \(directory.path)")
    }

    static func render(_ image: CIImage, in bounds: CGRect) throws -> CGImage {
        try #require(context.createCGImage(image, from: bounds))
    }

    static func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let bitmap = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    static func meanDifference(_ a: CGImage, _ b: CGImage, region: CGRect? = nil) throws -> Double {
        try #require(a.width == b.width && a.height == b.height, "Frame dimensions differ")
        let x = try pixels(a), y = try pixels(b)
        var sum = 0.0, count = 0.0
        for row in 0..<a.height {
            for column in 0..<a.width {
                if let region, !region.contains(CGPoint(x: column, y: a.height - 1 - row)) { continue }
                let offset = (row * a.width + column) * 4
                for channel in 0..<3 {
                    sum += Double(abs(Int(x[offset + channel]) - Int(y[offset + channel])))
                    count += 1
                }
            }
        }
        try #require(count > 0)
        return sum / count
    }
}
