import AVFoundation
import CoreImage
import Testing
@testable import WalkAndRoll

@Suite(.serialized)
@MainActor
struct RecordingPreviewTests {
    private func ready(_ preview: RecordingPreview) async throws {
        try await TestMedia.waitUntil {
            !preview.isPreparing && (preview.error != nil || preview.player.currentItem?.status == .readyToPlay)
        }
        try #require(preview.error == nil)
        try #require(preview.player.currentItem?.status == .readyToPlay)
    }

    private func seek(_ preview: RecordingPreview, to seconds: Double) async throws {
        preview.seek(to: seconds)
        try await TestMedia.waitUntil { abs(preview.player.currentTime().seconds - seconds) < 0.02 }
    }

    @Test("Preview seeks forward and backward to the requested frame")
    func exactSeeking() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let preview = fixture.preview()
        defer { preview.close() }
        try await ready(preview)
        #expect(abs(preview.duration - 3) < 0.01)
        for seconds in [2.2, 0.4, 1.5] {
            try await seek(preview, to: seconds)
            #expect(abs(preview.time - seconds) < 0.02)
        }
    }

    @Test("AVPlayer delivers the same composed frame used by export")
    func playerCompositionOutput() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let preview = fixture.preview()
        defer { preview.close() }
        try await ready(preview)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        preview.player.currentItem?.add(output)
        let time = CMTime(seconds: 1.5, preferredTimescale: 600)
        try await seek(preview, to: 1.5)
        try await TestMedia.waitUntil { output.hasNewPixelBuffer(forItemTime: time) }
        let buffer = try #require(output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil))
        let actual = try TestMedia.render(CIImage(cvPixelBuffer: buffer), in: CGRect(origin: .zero, size: fixture.size))
        let prepared = try await MP4Export.prepare(fixture.screen, camera: fixture.overlay,
            clicks: fixture.clicks, keystrokes: fixture.keystrokes, resolution: .sharper)
        let expected = try await TestMedia.frame(prepared, at: 1.5)
        #expect(try TestMedia.meanDifference(actual, expected) < 2)
    }

    @Test("Adding, selecting, adjusting and removing a zoom update the edit instructions")
    func zoomEditing() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let preview = fixture.preview()
        defer { preview.close() }
        try await ready(preview)
        try await seek(preview, to: 1)
        preview.addingZoom = true
        preview.addZoom(at: CGPoint(x: 0.9, y: 0.1))
        try #require(preview.edits.zooms.count == 1)
        let zoom = try #require(preview.selectedZoom)
        #expect(zoom.start == 1)
        #expect(abs(zoom.focalPoint.x - 0.9) < 0.00001)
        #expect(abs(zoom.focalPoint.y - 0.1) < 0.00001)
        preview.updateSelected(duration: 0.5, magnification: 3)
        #expect(preview.selectedZoom?.duration == 0.5)
        #expect(preview.selectedZoom?.magnification == 3)
        try await ready(preview)
        try await seek(preview, to: 2)
        preview.selectZoom(zoom.id)
        try await TestMedia.waitUntil { abs(preview.player.currentTime().seconds - 1) < 0.02 }
        preview.removeSelected()
        #expect(preview.edits.zooms.isEmpty)
        #expect(preview.selectedZoomID == nil)
    }

    @Test("Rapid changes publish only the newest composition and preserve the playhead")
    func latestEditWins() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let preview = fixture.preview()
        defer { preview.close() }
        try await ready(preview)
        try await seek(preview, to: 1.5)
        preview.edits.blurredBackdrop = true
        preview.resolution = .fullHD
        preview.includesCamera = false
        try await ready(preview)
        #expect(preview.canvas == CGSize(width: 1920, height: 1080))
        #expect(abs(preview.time - 1.5) < 0.02)
        let instruction = try #require(preview.player.currentItem?.videoComposition?.instructions.first as? RecordingCompositionInstruction)
        #expect(instruction.camera == nil)
        #expect(instruction.edits.blurredBackdrop)
    }

    @Test("Playback advances, pauses at the end, and restarts from the beginning")
    func playbackEndAndReplay() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let preview = fixture.preview()
        defer { preview.close() }
        try await ready(preview)
        try await seek(preview, to: 0.2)
        preview.togglePlayback()
        try await TestMedia.waitUntil { preview.player.currentTime().seconds > 0.4 }
        try await seek(preview, to: 2.8)
        preview.togglePlayback()
        try await TestMedia.waitUntil {
            preview.player.currentTime().seconds >= 2.99 && preview.player.rate == 0 && !preview.isPlaying
        }
        preview.togglePlayback()
        try await TestMedia.waitUntil {
            preview.player.rate != 0 && preview.player.currentTime().seconds > 0.1 && preview.player.currentTime().seconds < 1
        }
    }

    @Test("A failed camera preview can be retried without changing the screen recording")
    func retryWithoutCamera() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.screen)
        let missing = CameraOverlay(url: fixture.file("missing.mov"), offset: .zero, corner: .topLeft)
        let preview = RecordingPreview(source: fixture.screen, camera: missing, clicks: [], keystrokes: [],
                                       keystrokeDelay: 1.5, resolution: .sharper)
        defer { preview.close() }
        try await TestMedia.waitUntil { !preview.isPreparing }
        #expect(preview.error != nil)
        preview.includesCamera = false
        try await ready(preview)
        #expect(preview.error == nil)
        #expect(try Data(contentsOf: fixture.screen) == original)
    }
}
