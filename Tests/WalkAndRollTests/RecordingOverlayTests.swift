import AVFoundation
import Testing
@testable import WalkAndRoll

@Suite(.serialized)
@MainActor
struct RecordingOverlayTests {
    @Test("Camera and keystroke badges stay fixed while the screen zooms", arguments: [RecordingFrameStyle.plain, .windowFrame])
    func fixedOutputOverlays(style: RecordingFrameStyle) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        var edits = fixture.edits
        edits.frameStyle = style
        let still = try await MP4Export.prepare(fixture.screen, camera: fixture.overlay,
                                                keystrokes: fixture.keystrokes, resolution: .sharper, edits: RecordingEdits(frameStyle: style))
        let zoomed = try await MP4Export.prepare(fixture.screen, camera: fixture.overlay,
            keystrokes: fixture.keystrokes, resolution: .sharper, edits: edits)
        let base = try await TestMedia.frame(still, at: 0.8)
        let changed = try await TestMedia.frame(zoomed, at: 0.8)
        let overlayBounds = style == .windowFrame ? still.contentRect : CGRect(origin: .zero, size: still.video.renderSize)
        let bubble = fixture.overlay.corner.frame(in: overlayBounds.size).offsetBy(dx: overlayBounds.minX, dy: overlayBounds.minY)
        #expect(try TestMedia.meanDifference(base, changed, region: bubble.insetBy(dx: 10, dy: 10)) < 0.1)
        let badge = try #require(RecordingCompositionInstruction.makeBadge(
            fixture.keystrokes[0].label, canvas: overlayBounds.size,
            avoiding: bubble.offsetBy(dx: -overlayBounds.minX, dy: -overlayBounds.minY)
        )).transformed(by: CGAffineTransform(translationX: overlayBounds.minX, y: overlayBounds.minY))
        // Its translucent background picks up some screen differences; a moved badge differs much more.
        #expect(try TestMedia.meanDifference(base, changed, region: badge.extent.insetBy(dx: 2, dy: 2)) < 12)
    }

    @Test("Click rings stay centered on the zoomed screen target", arguments: [RecordingFrameStyle.plain, .windowFrame])
    func clickContentAlignment(style: RecordingFrameStyle) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        var edits = fixture.edits
        edits.frameStyle = style
        let base = try await MP4Export.prepare(fixture.screen, resolution: .sharper, edits: edits)
        let withClick = try await MP4Export.prepare(fixture.screen, clicks: fixture.clicks,
                                                    resolution: .sharper, edits: edits)
        let noRing = try await TestMedia.frame(base, at: 0.8)
        let ring = try await TestMedia.frame(withClick, at: 0.8)
        let instruction = try #require(withClick.video.instructions.first as? RecordingCompositionInstruction)
        let target = CGPoint(x: 0.75 * 640, y: 0.7 * 360).applying(instruction.screenTransform)
            .applying(RecordingGeometry.zoomTransform(in: withClick.contentRect, zoom: edits.zoom(at: 0.8), at: 0.8, frameStyle: style))
        let before = try TestMedia.pixels(noRing), after = try TestMedia.pixels(ring)
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for row in 0..<ring.height {
            for column in 0..<ring.width {
                let index = (row * ring.width + column) * 4
                if abs(Int(after[index]) - Int(before[index])) > 30 {
                    sumX += Double(column)
                    sumY += Double(ring.height - 1 - row)
                    count += 1
                }
            }
        }
        try #require(count > 50, "The click ring must actually be visible")
        #expect(abs(sumX / count - target.x) < 2)
        #expect(abs(sumY / count - target.y) < 2)
    }

    @Test("Camera visibility follows its offset in every corner",
          arguments: CameraCorner.allCases, [-0.5, 0.5])
    func cameraTimeline(corner: CameraCorner, offset: Double) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let overlay = CameraOverlay(url: fixture.camera, offset: CMTime(seconds: offset, preferredTimescale: 600), corner: corner)
        let prepared = try await MP4Export.prepare(fixture.screen, camera: overlay, resolution: .sharper,
            edits: RecordingEdits(zooms: [ZoomEffect(start: 0, duration: 3, magnification: 3, focalPoint: .zero)]))
        let bubble = corner.frame(in: fixture.size)
        for seconds in [0.1, 1.0, 2.9] {
            let frame = try await TestMedia.frame(prepared, at: seconds)
            let pixels = try TestMedia.pixels(frame)
            let index = ((frame.height - 1 - Int(bubble.midY)) * frame.width + Int(bubble.midX)) * 4
            let visible = pixels[index] > 180 && pixels[index + 1] < 80 && pixels[index + 2] > 140
            let expected = seconds >= max(0, offset) && seconds < min(3, offset + 3)
            #expect(visible == expected, "Camera visibility at \(seconds) seconds")
        }
    }
}
