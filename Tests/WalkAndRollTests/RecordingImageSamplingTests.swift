import CoreGraphics
import CoreImage
import Testing
@testable import WalkAndRoll

@MainActor
struct RecordingImageSamplingTests {
    private let bounds = CGRect(x: 0, y: 0, width: 256, height: 128)
    private let scale = CGAffineTransform(scaleX: 2, y: 2)

    private func edge(dark: CGFloat = 0, light: CGFloat = 1) -> CIImage {
        CIImage(color: CIColor(red: light, green: light, blue: light))
            .cropped(to: CGRect(x: 128, y: 0, width: 128, height: 128))
            .composited(over: CIImage(color: CIColor(red: dark, green: dark, blue: dark)).cropped(to: bounds))
    }

    @Test("Enlargement keeps text-like edge contrast firmer than bilinear sampling")
    func enlargedEdgeContrast() throws {
        let source = edge()
        let output = bounds.applying(scale)
        let linear = try TestMedia.pixels(TestMedia.render(source.transformed(by: scale), in: output))
        let enlarged = try TestMedia.pixels(TestMedia.render(RecordingImageSampling.transform(source, by: scale), in: output))
        let left = (128 * 512 + 255) * 4
        let oldGradient = Int(linear[left + 4]) - Int(linear[left])
        let newGradient = Int(enlarged[left + 4]) - Int(enlarged[left])
        #expect(newGradient > oldGradient + 10)
    }

    @Test("High-contrast text edges do not acquire dark or bright halos")
    func noContrastOvershoot() throws {
        let source = edge(dark: 0.2, light: 0.8)
        let original = try TestMedia.pixels(TestMedia.render(source, in: bounds))
        let enlarged = try TestMedia.pixels(TestMedia.render(
            RecordingImageSampling.transform(source, by: scale), in: bounds.applying(scale)
        ))
        let minimum = Int(original[0]), maximum = Int(original[128 * 4])
        for x in 0..<512 {
            let value = Int(enlarged[(128 * 512 + x) * 4])
            #expect(value >= minimum - 1 && value <= maximum + 1)
        }
    }

    @Test("Sampling at source boundaries stays opaque")
    func opaqueBoundaries() throws {
        let enlarged = try TestMedia.pixels(TestMedia.render(
            RecordingImageSampling.transform(edge(), by: scale), in: bounds.applying(scale)
        ))
        for (x, y) in [(0, 0), (511, 0), (0, 255), (511, 255)] {
            #expect(enlarged[(y * 512 + x) * 4 + 3] == 255)
        }
    }

    @Test("A fit reduction followed by an equal zoom preserves original pixel detail")
    func combinedTransformPreservesNativePixels() throws {
        let source = edge()
        let transform = CGAffineTransform(scaleX: 0.5, y: 0.5).concatenating(scale)
        let result = try TestMedia.render(RecordingImageSampling.transform(source, by: transform), in: bounds)
        let original = try TestMedia.render(source, in: bounds)
        #expect(try TestMedia.meanDifference(result, original) == 0)
    }

    @Test("Resampling preserves rotated framing", arguments: [0.0, Double.pi / 2, Double.pi, -Double.pi / 2])
    func rotatedFraming(angle: Double) throws {
        let source = edge()
        let transform = CGAffineTransform(rotationAngle: angle).concatenating(scale)
        let output = bounds.applying(transform).integral
        let expected = try TestMedia.render(source.clampedToExtent().transformed(by: transform), in: output)
        let actual = try TestMedia.render(RecordingImageSampling.transform(source, by: transform), in: output)
        #expect(try TestMedia.meanDifference(actual, expected) < 1)
    }
}
