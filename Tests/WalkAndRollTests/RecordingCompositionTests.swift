import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Testing
@testable import WalkAndRoll

@Suite(.serialized)
@MainActor
struct RecordingCompositionTests {
    @Test("Preview and encoded frames match throughout zoom transitions and overlaps")
    func previewExportParity() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let prepared = try await MP4Export.prepare(
            fixture.screen, camera: fixture.overlay, clicks: fixture.clicks,
            keystrokes: fixture.keystrokes, resolution: .sharper, edits: fixture.edits
        )
        let output = fixture.file("edited.mp4")
        try await MP4Export.save(
            fixture.screen, camera: fixture.overlay, clicks: fixture.clicks,
            keystrokes: fixture.keystrokes, resolution: .sharper, edits: fixture.edits, to: output
        ) { _ in }
        // Before, during ease-in/hold/ease-out, at the overlapping start, and after the effects.
        for seconds in [0.0, 0.4, 0.8, 1.5, 1.7, 1.9, 2.3, 2.8] {
            let preview = try await TestMedia.sample(prepared, at: seconds)
            let encoded = try await TestMedia.sample(output, at: seconds)
            let difference = try TestMedia.meanDifference(preview.image, encoded.image)
            // Allow H.264 and color-conversion differences, not a different framing or timeline.
            #expect(difference < 9, "Frame mismatch at \(seconds) seconds; preview time \(preview.actualTime.seconds), encoded time \(encoded.actualTime.seconds)")
            if difference >= 9 {
                try TestMedia.saveParityFailure(fixture: fixture, output: output, seconds: seconds,
                    difference: difference, preview: preview, encoded: encoded)
            }
        }
    }

    @Test("Both export resolutions preserve Plain and Window Frame across source shapes",
          arguments: ["landscape", "portrait", "narrow"], ["native", "1080p"])
    func sourceShapesAndFrames(shape: String, outputMode: String) async throws {
        let sizes = ["landscape": CGSize(width: 640, height: 360), "portrait": CGSize(width: 240, height: 640),
                     "narrow": CGSize(width: 96, height: 640)]
        let fixture = try await MediaFixture(size: try #require(sizes[shape]))
        defer { fixture.remove() }
        let resolution: RecordingResolution = outputMode == "native" ? .sharper : .fullHD
        for style in RecordingFrameStyle.allCases {
            let edits = RecordingEdits(zooms: [
                ZoomEffect(start: 0.2, duration: 2, magnification: 2, focalPoint: CGPoint(x: 1, y: 0))
            ], frameStyle: style)
            let prepared = try await MP4Export.prepare(fixture.screen, resolution: resolution, edits: edits)
            let output = fixture.file("frame-\(style).mp4")
            try await MP4Export.save(fixture.screen, resolution: resolution, edits: edits, to: output) { _ in }
            let asset = AVURLAsset(url: output)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let (actual, fps) = try await track.load(.naturalSize, .nominalFrameRate)
            let expected: CGSize
            switch (shape, outputMode, style) {
            case ("landscape", "native", .plain): expected = CGSize(width: 640, height: 360)
            case ("portrait", "native", .plain): expected = CGSize(width: 240, height: 640)
            case ("narrow", "native", .plain): expected = CGSize(width: 96, height: 640)
            case ("portrait", "1080p", .plain): expected = CGSize(width: 406, height: 1080)
            case ("narrow", "1080p", .plain): expected = CGSize(width: 162, height: 1080)
            case ("landscape", "native", .windowFrame): expected = CGSize(width: 684, height: 404)
            case ("portrait", "native", .windowFrame): expected = CGSize(width: 268, height: 668)
            case ("narrow", "native", .windowFrame): expected = CGSize(width: 108, height: 652)
            case ("landscape", "1080p", .windowFrame): expected = CGSize(width: 1826, height: 1078)
            case ("portrait", "1080p", .windowFrame): expected = CGSize(width: 432, height: 1078)
            case ("narrow", "1080p", .windowFrame): expected = CGSize(width: 174, height: 1076)
            default: expected = CGSize(width: 1920, height: 1080)
            }
            #expect(actual == expected)
            #expect(abs(fps - 30) < 0.001)
            #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
            let preview = try await TestMedia.frame(prepared, at: 0.8)
            let encoded = try await TestMedia.frame(output, at: 0.8)
            #expect(try TestMedia.meanDifference(preview, encoded) < 9)
        }
    }

    @Test("Previewing and exporting different edits leave both original media files unchanged")
    func nonDestructiveEditing() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let originalScreen = try Data(contentsOf: fixture.screen)
        let originalCamera = try Data(contentsOf: fixture.camera)
        let prepared = try await MP4Export.prepare(fixture.screen, camera: fixture.overlay, edits: fixture.edits)
        _ = try await TestMedia.frame(prepared, at: 0.8)
        try await MP4Export.save(fixture.screen, camera: fixture.overlay, edits: fixture.edits, to: fixture.file("first.mp4")) { _ in }
        var changed = fixture.edits
        changed.frameStyle = .windowFrame
        changed.zooms[0].magnification = 3
        try await MP4Export.save(fixture.screen, camera: fixture.overlay, edits: changed, to: fixture.file("second.mp4")) { _ in }
        #expect(try Data(contentsOf: fixture.screen) == originalScreen)
        #expect(try Data(contentsOf: fixture.camera) == originalCamera)
    }
}

extension RecordingCompositionTests {
    @Test("Window Frame preview and export match with zooms, clicks, camera and keystrokes", arguments: ["native", "1080p"])
    func windowFrameParity(mode: String) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        var edits = fixture.edits
        edits.frameStyle = .windowFrame
        let resolution: RecordingResolution = mode == "native" ? .sharper : .fullHD
        let prepared = try await MP4Export.prepare(fixture.screen, camera: fixture.overlay,
            clicks: fixture.clicks, keystrokes: fixture.keystrokes, resolution: resolution, edits: edits)
        let instruction = try #require(prepared.video.instructions.first as? RecordingCompositionInstruction)
        let content = prepared.contentRect
        let expectedBubble = fixture.overlay.corner.frame(in: content.size).offsetBy(dx: content.minX, dy: content.minY)
        #expect(instruction.camera?.mask.extent == expectedBubble.integral)
        #expect(content.contains(expectedBubble))
        let output = fixture.file("window-frame.mp4")
        try await MP4Export.save(fixture.screen, camera: fixture.overlay, clicks: fixture.clicks,
            keystrokes: fixture.keystrokes, resolution: resolution, edits: edits, to: output) { _ in }
        for time in [0.0, 0.4, 0.8, 1.7, 2.3, 2.8] {
            #expect(try TestMedia.meanDifference(await TestMedia.frame(prepared, at: time),
                await TestMedia.frame(output, at: time)) < 9)
        }
        let held = try await TestMedia.frame(prepared, at: 0.8)
        let changedZoom = try await TestMedia.frame(prepared, at: 2.3)
        #expect(try TestMedia.meanDifference(held, changedZoom, region: expectedBubble.insetBy(dx: 8, dy: 8)) < 1,
                "The camera stays fixed while footage zooms")
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == prepared.video.renderSize)
        #expect(abs(try await track.load(.nominalFrameRate) - 30) < 0.001)
    }

    @Test("Flattened black window corners disappear without removing black content, including edge zooms")
    func roundedCaptureCorners() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let bounds = CGRect(origin: .zero, size: fixture.size)
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = bounds
        mask.radius = Float(fixture.size.height * 0.03)
        let window = CIImage(color: CIColor.white).cropped(to: bounds)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = window
        blend.backgroundImage = CIImage(color: CIColor.black).cropped(to: bounds)
        blend.maskImage = mask.outputImage
        let blackContent = CIImage(color: CIColor.black).cropped(to: CGRect(x: 300, y: 160, width: 40, height: 40))
        let source = fixture.file("rounded-window.mp4")
        try await TestMedia.makeVideo(at: source, size: fixture.size,
            imageOverride: blackContent.composited(over: try #require(blend.outputImage)))
        let plain = try await TestMedia.frame(source, at: 0)
        #expect(try TestMedia.pixels(plain)[0] < 20, "The fixture includes flattened black corners")
        let edits = RecordingEdits(zooms: [ZoomEffect(start: 0.5, duration: 2, magnification: 3,
            focalPoint: CGPoint(x: 0, y: 0))], frameStyle: .windowFrame)
        let prepared = try await MP4Export.prepare(source, resolution: .sharper, edits: edits)
        let output = fixture.file("rounded-frame.mp4")
        try await MP4Export.save(source, resolution: .sharper, edits: edits, to: output) { _ in }
        for time in [0.0, 1.2] {
            let frame = try await TestMedia.frame(prepared, at: time)
            let encoded = try await TestMedia.frame(output, at: time)
            #expect(try TestMedia.meanDifference(frame, encoded) < 4)
            let pixels = try TestMedia.pixels(frame)
            let content = prepared.contentRect
            // Bright footage and the neutral matte must meet without a black crescent.
            var darkest = 255
            for y in Int(content.maxY) - 16 ..< Int(content.maxY) + 4 {
                for x in Int(content.minX) - 4 ..< Int(content.minX) + 24 {
                    let offset = ((frame.height - 1 - y) * frame.width + x) * 4
                    darkest = min(darkest, Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
                }
            }
            #expect(darkest > 150)
            if time == 0 {
                let x = Int(content.midX), y = Int(content.midY)
                let offset = ((frame.height - 1 - y) * frame.width + x) * 4
                #expect(pixels[offset] < 20, "Actual black content is preserved")
            }
        }
    }
}
