import AVFoundation
import Testing
@testable import WalkAndRoll

@Suite(.serialized)
@MainActor
struct MP4ExportTests {
    @Test("Silent exports contain 30 fps H.264 and no audio track")
    func silentMP4Format() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let output = fixture.file("silent.mp4")
        try await MP4Export.save(fixture.screen, resolution: .sharper, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(abs(try await track.load(.nominalFrameRate) - 30) < 0.001)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    }

    @Test("Export cancellation preserves an existing destination and permits retry")
    func cancellationAndRetry() async throws {
        // Give progress-driven cancellation enough frames to observe an active encoder.
        let fixture = try await MediaFixture(frames: 900)
        defer { fixture.remove() }
        let destination = fixture.file("existing.mp4")
        let existing = Data("existing destination".utf8)
        try existing.write(to: destination)
        var exportTask: Task<Void, Error>?
        let task = Task {
            try await MP4Export.save(fixture.screen, resolution: .fullHD, edits: fixture.edits, to: destination) { _ in
                exportTask?.cancel()
            }
        }
        exportTask = task
        defer { exportTask = nil }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(task.isCancelled, "Cancellation must happen after export progress is observed")
        #expect(try Data(contentsOf: destination) == existing)
        #expect(FileManager.default.fileExists(atPath: fixture.screen.path))
        try await MP4Export.save(fixture.screen, resolution: .sharper, edits: fixture.edits, to: destination) { _ in }
        #expect(try Data(contentsOf: destination) != existing)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!files.contains { $0.hasPrefix(".walk-and-roll-") }, "Staging files must be cleaned up")
    }

    @Test("A failed destination leaves the original available for another export")
    func invalidDestinationAndRetry() async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.screen)
        await #expect(throws: (any Error).self) {
            try await MP4Export.save(fixture.screen, to: fixture.file("missing/output.mp4")) { _ in }
        }
        #expect(try Data(contentsOf: fixture.screen) == original)
        let retry = fixture.file("retry.mp4")
        try await MP4Export.save(fixture.screen, resolution: .sharper, to: retry) { _ in }
        #expect(FileManager.default.fileExists(atPath: retry.path))
    }

    @Test("Export cannot overwrite screen or camera originals", arguments: ["screen", "camera", "symlink"])
    func originalMediaProtection(destinationKind: String) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let beforeScreen = try Data(contentsOf: fixture.screen)
        let beforeCamera = try Data(contentsOf: fixture.camera)
        let destination: URL
        if destinationKind == "symlink" {
            destination = fixture.file("original-alias.mp4")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: fixture.screen)
        } else {
            destination = destinationKind == "camera" ? fixture.camera : fixture.screen
        }
        await #expect(throws: (any Error).self) {
            try await MP4Export.save(fixture.screen, camera: fixture.overlay, to: destination) { _ in }
        }
        #expect(try Data(contentsOf: fixture.screen) == beforeScreen)
        #expect(try Data(contentsOf: fixture.camera) == beforeCamera)
    }

    @Test("One or two audio sources export as a single AAC track with the expected tones", arguments: [1, 2])
    func mixedAACAudio(sourceCount: Int) async throws {
        let fixture = try await MediaFixture()
        defer { fixture.remove() }
        let composition = AVMutableComposition()
        let screenAsset = AVURLAsset(url: fixture.screen)
        let video = try #require(try await screenAsset.loadTracks(withMediaType: .video).first)
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        for frequency in [440.0, 880.0].prefix(sourceCount) {
            let url = fixture.file("tone-\(Int(frequency)).wav")
            try makeTone(at: url, frequency: frequency)
            let asset = AVURLAsset(url: url)
            let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(range, of: audio, at: .zero)
        }
        let source = fixture.file("audio-source.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: source, as: .mov)
        let overlay = sourceCount == 2 ? fixture.overlay : nil
        let output = fixture.file("audio-export.mp4")
        try await MP4Export.save(source, camera: overlay, edits: fixture.edits, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try #require(tracks.count == 1)
        let format = try #require(try await tracks[0].load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        let (samples, rate) = try decodeAudio(asset, track: tracks[0])
        try #require(samples.count > Int(rate * 2.9), "Audio must last for the recording")
        #expect(amplitude(440, in: samples, rate: rate) > 0.03)
        let secondTone = amplitude(880, in: samples, rate: rate)
        #expect(sourceCount == 1 ? secondTone < 0.01 : secondTone > 0.03)
    }

    private func makeTone(at url: URL, frequency: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000))
        buffer.frameLength = 144000
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<144000 { channels[0][index] = Float(sin(Double(index) * frequency * 2 * .pi / 48000)) * 0.2 }
        try file?.write(from: buffer)
        file = nil // Finalize the WAV header before AVFoundation opens it.
    }

    private func decodeAudio(_ asset: AVAsset, track: AVAssetTrack) throws -> ([Float], Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        try #require(reader.startReading())
        var samples: [Float] = []
        var rate = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let description = try #require(CMSampleBufferGetFormatDescription(sample))
            let format = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
            rate = format.mSampleRate
            let channels = Int(format.mChannelsPerFrame)
            try #require(channels > 0)
            var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            try #require(status == noErr)
            samples.append(contentsOf: stride(from: 0, to: data.count, by: channels).map { data[$0] })
        }
        try #require(reader.status == .completed)
        try #require(rate > 0)
        return (samples, rate)
    }

    private func amplitude(_ frequency: Double, in samples: [Float], rate: Double) -> Double {
        let start = Int(rate * 0.2), length = Int(rate)
        var real = 0.0, imaginary = 0.0
        for index in 0..<length {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            real += Double(samples[start + index]) * cos(phase)
            imaginary += Double(samples[start + index]) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(length)
    }
}
