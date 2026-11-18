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

    @Test("Plain portrait 1080p preserves proportions with even dimensions")
    func portraitOutputDimensions() {
        let source = CGSize(width: 240, height: 640)
        #expect(RecordingResolution.fullHD.outputSize(for: source) == CGSize(width: 406, height: 1080))
    }

    @Test("Large landscape, portrait and ultrawide sources stay within 4K", arguments: RecordingFrameStyle.allCases)
    func fourKCeiling(style: RecordingFrameStyle) {
        for size in [CGSize(width: 8000, height: 6000), CGSize(width: 200, height: 8000), CGSize(width: 8000, height: 200)] {
            let output = RecordingResolution.sharper.layout(for: size, frameStyle: style).canvas
            #expect(output.width <= 3840 && output.height <= 2160)
            #expect(Int(output.width).isMultiple(of: 2))
            #expect(Int(output.height).isMultiple(of: 2))
        }
    }
}

extension RecordingResolutionTests {
    @Test("Window Frame has equal margins and codec-safe dimensions at either resolution")
    func windowFrameGeometry() {
        for source in [CGSize(width: 1800, height: 1264), CGSize(width: 3840, height: 2160),
                       CGSize(width: 240, height: 640), CGSize(width: 8000, height: 200),
                       CGSize(width: 2, height: 8000), CGSize(width: 8000, height: 6000)] {
            for resolution in RecordingResolution.allCases {
                let layout = resolution.layout(for: source, frameStyle: .windowFrame)
                let inset = layout.content.minX
                #expect(inset > 0)
                #expect(inset == layout.content.minY)
                #expect(layout.canvas.width - layout.content.maxX == inset)
                #expect(layout.canvas.height - layout.content.maxY == inset)
                #expect(layout.canvas.width <= (resolution == .sharper ? 3840 : 1920))
                #expect(layout.canvas.height <= (resolution == .sharper ? 2160 : 1080))
                #expect(Int(layout.canvas.width).isMultiple(of: 2))
                #expect(Int(layout.canvas.height).isMultiple(of: 2))
                #expect(RecordingGeometry.sourcePoint(at: CGPoint(x: 0, y: 0.5), content: layout.content,
                    canvas: layout.canvas, zoom: nil, seconds: 0) == nil)
                #expect(RecordingGeometry.sourcePoint(at: CGPoint(x: 0.5, y: 0.5), content: layout.content,
                    canvas: layout.canvas, zoom: nil, seconds: 0) == CGPoint(x: 0.5, y: 0.5))
            }
        }
        let native = RecordingResolution.sharper.layout(for: CGSize(width: 1800, height: 1264), frameStyle: .windowFrame)
        #expect(native.canvas == CGSize(width: 1952, height: 1416))
        #expect(native.content == CGRect(x: 76, y: 76, width: 1800, height: 1264))
    }
}
