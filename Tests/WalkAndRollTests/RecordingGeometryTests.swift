import CoreGraphics
import Testing
@testable import WalkAndRoll

struct RecordingGeometryTests {
    @Test("Portrait footage is centered without changing its aspect ratio")
    func portraitAspectFit() {
        let content = RecordingGeometry.fittedRect(
            source: CGSize(width: 240, height: 640), canvas: CGSize(width: 1920, height: 1080)
        )
        #expect(content == CGRect(x: 757.5, y: 0, width: 405, height: 1080))
    }

    @Test("Crops stay inside landscape, portrait and narrow sources", arguments: [640.0, 240.0, 96.0])
    func edgeClamping(width: Double) {
        let content = RecordingGeometry.fittedRect(
            source: CGSize(width: width, height: width == 640 ? 360 : 640), canvas: CGSize(width: 1920, height: 1080)
        )
        for x in [0.0, 0.01, 0.5, 0.99, 1.0] {
            for y in [0.0, 0.01, 0.5, 0.99, 1.0] {
                let zoom = ZoomEffect(start: 1, duration: 2, magnification: 4, focalPoint: CGPoint(x: x, y: y))
                for seconds in [1.0, 1.1, 1.2, 1.4, 2.0, 2.8, 2.9, 3.0] {
                    let crop = RecordingGeometry.crop(in: content, zoom: zoom, at: seconds)
                    #expect(crop.minX >= content.minX - 0.0001)
                    #expect(crop.minY >= content.minY - 0.0001)
                    #expect(crop.maxX <= content.maxX + 0.0001)
                    #expect(crop.maxY <= content.maxY + 0.0001)
                    let mapped = crop.applying(RecordingGeometry.zoomTransform(in: content, zoom: zoom, at: seconds))
                    #expect(abs(mapped.minX - content.minX) < 0.00001)
                    #expect(abs(mapped.maxX - content.maxX) < 0.00001)
                    #expect(abs(mapped.minY - content.minY) < 0.00001)
                    #expect(abs(mapped.maxY - content.maxY) < 0.00001)
                }
            }
        }
    }

    @Test("A top-right focal point produces the expected bounded source crop")
    func cornerCrop() {
        let content = CGRect(x: 100, y: 50, width: 800, height: 600)
        let zoom = ZoomEffect(start: 0, duration: 2, magnification: 2, focalPoint: CGPoint(x: 1, y: 0))
        #expect(RecordingGeometry.crop(in: content, zoom: zoom, at: 1) == CGRect(x: 500, y: 350, width: 400, height: 300))
    }

    @Test("Preview clicks invert the current zoom and respect top-left source coordinates")
    func inverseHitTesting() throws {
        let content = CGRect(x: 200, y: 0, width: 800, height: 600)
        let canvas = CGSize(width: 1200, height: 600)
        let zoom = ZoomEffect(start: 0, duration: 2, magnification: 2, focalPoint: CGPoint(x: 1, y: 0))
        let source = try #require(RecordingGeometry.sourcePoint(
            at: CGPoint(x: 0.5, y: 0.5), content: content, canvas: canvas, zoom: zoom, seconds: 1
        ))
        #expect(source == CGPoint(x: 0.75, y: 0.25))
        #expect(RecordingGeometry.sourcePoint(at: CGPoint(x: 0, y: 0.5), content: content,
                                              canvas: canvas, zoom: zoom, seconds: 1) == nil)
    }
}
