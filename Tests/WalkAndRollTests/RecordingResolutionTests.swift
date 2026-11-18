import CoreGraphics
import Testing
@testable import WalkAndRoll

struct RecordingResolutionTests {
    @Test("Sharper preserves a small source's native dimensions")
    func nativeSmallSource() {
        let size = CGSize(width: 800, height: 624)
        #expect(RecordingResolution.sharper.outputSize(for: size) == size)
        #expect(RecordingResolution.captureSize(for: size) == size)
    }

    @Test("1080p export retains a native 4K original for later zooms")
    func captureDetailIndependentOfExport() {
        let size = CGSize(width: 3840, height: 2160)
        #expect(RecordingResolution.captureSize(for: size) == size)
        #expect(RecordingResolution.fullHD.outputSize(for: size) == CGSize(width: 1920, height: 1080))
    }

    @Test("Portrait 1080p uses even dimensions and an optional widescreen canvas")
    func portraitOutputDimensions() {
        let source = CGSize(width: 240, height: 640)
        #expect(RecordingResolution.fullHD.outputSize(for: source) == CGSize(width: 406, height: 1080))
        #expect(RecordingResolution.fullHD.outputSize(for: source, blurredBackdrop: true) == CGSize(width: 1920, height: 1080))
    }

    @Test("Large landscape, portrait and ultrawide sources stay within 4K", arguments: [false, true])
    func fourKCeiling(backdrop: Bool) {
        for size in [CGSize(width: 8000, height: 6000), CGSize(width: 200, height: 8000), CGSize(width: 8000, height: 200)] {
            let output = RecordingResolution.sharper.outputSize(for: size, blurredBackdrop: backdrop)
            #expect(output.width <= 3840 && output.height <= 2160)
            #expect(Int(output.width).isMultiple(of: 2))
            #expect(Int(output.height).isMultiple(of: 2))
        }
    }
}
