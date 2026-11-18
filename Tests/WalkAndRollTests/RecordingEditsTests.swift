import CoreGraphics
import Testing
@testable import WalkAndRoll

struct RecordingEditsTests {
    @Test("Zooms ease symmetrically from and back to the original scale", arguments: [0.2, 2.0, 5.0])
    func symmetricEasing(duration: Double) {
        let zoom = ZoomEffect(start: 1, duration: duration, magnification: 4, focalPoint: .zero)
        let ramp = min(0.4, duration / 2)
        #expect(zoom.scale(at: 0.9) == 1)
        #expect(zoom.scale(at: 1) == 1)
        #expect(abs(zoom.scale(at: 1 + ramp / 2) - 2.5) < 0.00001)
        #expect(abs(zoom.scale(at: 1 + duration - ramp / 2) - 2.5) < 0.00001)
        #expect(zoom.scale(at: 1 + duration / 2) == 4)
        #expect(zoom.scale(at: 1 + duration) == 1)
    }

    @Test("A later zoom truncates the earlier zoom and completes its ease-out")
    func overlappingZooms() throws {
        let first = ZoomEffect(start: 1, duration: 5, focalPoint: .zero)
        let second = ZoomEffect(start: 2, duration: 3, focalPoint: .zero)
        let edits = RecordingEdits(zooms: [second, first])
        #expect(edits.resolvedZooms.map(\.id) == [first.id, second.id])
        #expect(edits.resolvedZooms[0].duration == 1)
        let ending = try #require(edits.zoom(at: 1.99))
        #expect(abs(ending.scale(at: 1.99) - 1) < 0.01)
        #expect(edits.zoom(at: 2)?.id == second.id)
        #expect(edits.zoom(at: 5) == nil)
        #expect(edits.zooms[1].duration == 5, "Resolution must not rewrite the authored instruction")
    }

    @Test("The most recently inserted zoom wins equal start times")
    func equalStartPrecedence() {
        let first = ZoomEffect(start: 1, duration: 5, focalPoint: .zero)
        let last = ZoomEffect(start: 1, duration: 1, focalPoint: .zero)
        let edits = RecordingEdits(zooms: [first, last])
        #expect(edits.resolvedZooms == [last])
        #expect(edits.zoom(at: 1)?.id == last.id)
        #expect(edits.zoom(at: 2) == nil)
    }

    @Test("Invalid zoom instructions do not interrupt valid zooms")
    func invalidInstructions() {
        let valid = ZoomEffect(start: 1, duration: 2, focalPoint: .zero)
        let invalid = [
            ZoomEffect(start: .nan, focalPoint: .zero),
            ZoomEffect(start: -1, focalPoint: .zero),
            ZoomEffect(start: 2, duration: 0, focalPoint: .zero),
            ZoomEffect(start: 2, magnification: .infinity, focalPoint: .zero),
            ZoomEffect(start: 2, focalPoint: CGPoint(x: Double.nan, y: 0))
        ]
        #expect(RecordingEdits(zooms: [valid] + invalid).resolvedZooms == [valid])
    }
}
