import AVFoundation
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
            let preview = try await TestMedia.frame(prepared, at: seconds)
            let encoded = try await TestMedia.frame(output, at: seconds)
            // Allow H.264 and color-conversion differences, not a different framing or timeline.
            #expect(try TestMedia.meanDifference(preview, encoded) < 9, "Frame mismatch at \(seconds) seconds")
        }
    }

    @Test("Both export resolutions preserve framing with and without a backdrop",
          arguments: ["landscape", "portrait", "narrow"], ["native", "1080p"])
    func sourceShapesAndBackdrop(shape: String, outputMode: String) async throws {
        let sizes = ["landscape": CGSize(width: 640, height: 360), "portrait": CGSize(width: 240, height: 640),
                     "narrow": CGSize(width: 96, height: 640)]
        let fixture = try await MediaFixture(size: try #require(sizes[shape]))
        defer { fixture.remove() }
        let resolution: RecordingResolution = outputMode == "native" ? .sharper : .fullHD
        for backdrop in [false, true] {
            let edits = RecordingEdits(zooms: [
                ZoomEffect(start: 0.2, duration: 2, magnification: 2, focalPoint: CGPoint(x: 1, y: 0))
            ], blurredBackdrop: backdrop)
            let prepared = try await MP4Export.prepare(fixture.screen, resolution: resolution, edits: edits)
            let output = fixture.file("backdrop-\(backdrop).mp4")
            try await MP4Export.save(fixture.screen, resolution: resolution, edits: edits, to: output) { _ in }
            let asset = AVURLAsset(url: output)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let (actual, fps) = try await track.load(.naturalSize, .nominalFrameRate)
            let expected: CGSize
            switch (shape, outputMode, backdrop) {
            case ("landscape", "native", _): expected = CGSize(width: 640, height: 360)
            case (_, "native", true): expected = CGSize(width: 1138, height: 640)
            case ("portrait", "native", false): expected = CGSize(width: 240, height: 640)
            case ("narrow", "native", false): expected = CGSize(width: 96, height: 640)
            case ("portrait", "1080p", false): expected = CGSize(width: 406, height: 1080)
            case ("narrow", "1080p", false): expected = CGSize(width: 162, height: 1080)
            default: expected = CGSize(width: 1920, height: 1080)
            }
            #expect(actual == expected)
            #expect(abs(fps - 30) < 0.001)
            #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
            let preview = try await TestMedia.frame(prepared, at: 0.8)
            let encoded = try await TestMedia.frame(output, at: 0.8)
            #expect(try TestMedia.meanDifference(preview, encoded) < 9)
            if backdrop && shape != "landscape" {
                let pixels = try TestMedia.pixels(preview)
                #expect(pixels[(preview.height / 2 * preview.width + 10) * 4 + 2] > 10,
                        "Letterbox area must contain the blurred footage")
            }
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
        changed.blurredBackdrop = true
        changed.zooms[0].magnification = 3
        try await MP4Export.save(fixture.screen, camera: fixture.overlay, edits: changed, to: fixture.file("second.mp4")) { _ in }
        #expect(try Data(contentsOf: fixture.screen) == originalScreen)
        #expect(try Data(contentsOf: fixture.camera) == originalCamera)
    }
}
