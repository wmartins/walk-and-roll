import AVFoundation
import Darwin

enum RecordingResolution: String, CaseIterable, Identifiable {
    case sharper = "Sharper (native, up to 4K)"
    case fullHD = "1080p"

    var id: Self { self }

    /// Export size must not throw away original detail before the user can add zooms.
    static func captureSize(for sourceSize: CGSize) -> CGSize {
        RecordingResolution.sharper.outputSize(for: sourceSize)
    }

    func outputSize(for sourceSize: CGSize, blurredBackdrop: Bool = false) -> CGSize {
        if blurredBackdrop {
            if self == .fullHD { return CGSize(width: 1920, height: 1080) }
            let height = min(2160, max(sourceSize.height, sourceSize.width * 9 / 16))
            return CGSize(width: max(2, (height * 16 / 9 / 2).rounded() * 2),
                          height: max(2, (height / 2).rounded() * 2))
        }
        let fit1080p = min(1920 / sourceSize.width, 1080 / sourceSize.height)
        // Preserve available detail without enlarging small sources in Sharper mode.
        let scale = self == .sharper ? min(1, 2 * fit1080p) : fit1080p
        return CGSize(
            width: max(2, (sourceSize.width * scale / 2).rounded() * 2),
            height: max(2, (sourceSize.height * scale / 2).rounded() * 2)
        )
    }
}

enum MP4Export {
    @MainActor
    static func save(
        _ source: URL,
        camera: CameraOverlay? = nil,
        clicks: [ClickHighlight] = [],
        keystrokes: [KeystrokeBadge] = [],
        keystrokeDelay: Double = 1.5,
        resolution: RecordingResolution = .fullHD,
        edits: RecordingEdits = RecordingEdits(),
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let originals = [source, camera?.url].compactMap { $0 }.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard !originals.contains(destination.resolvingSymlinksInPath().standardizedFileURL) else {
            throw ExportError.overwritesOriginal
        }
        try Task.checkCancellation()
        let composition = try await prepare(
            source, camera: camera, clicks: clicks, keystrokes: keystrokes,
            keystrokeDelay: keystrokeDelay, resolution: resolution, edits: edits
        )
        let frameSize = composition.video.renderSize
        let preset = frameSize.width > 1920 || frameSize.height > 1080
            ? AVAssetExportPreset3840x2160 : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: composition.asset, presetName: preset) else {
            throw ExportError.unavailable
        }
        session.videoComposition = composition.video
        session.audioMix = composition.audio
        session.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        session.shouldOptimizeForNetworkUse = true

        // Encode beside the destination so publishing can replace it atomically.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".walk-and-roll-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case let .exporting(value) = state {
                    progress(value.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        try await session.export(to: staging, as: .mp4)
        try Task.checkCancellation()
        let result = staging.withUnsafeFileSystemRepresentation { input in
            destination.withUnsafeFileSystemRepresentation { output in
                rename(input, output)
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The same immutable composition snapshot is used by AVPlayerItem and MP4 export.
    struct Prepared {
        let asset: AVComposition
        let video: AVVideoComposition
        let audio: AVAudioMix?
        let duration: CMTime
        let contentRect: CGRect

        @MainActor
        func playerItem() -> AVPlayerItem {
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = video
            item.audioMix = audio
            item.seekingWaitsForVideoCompositionRendering = true
            return item
        }
    }

    @MainActor
    static func prepare(
        _ source: URL, camera overlay: CameraOverlay? = nil,
        clicks: [ClickHighlight] = [], keystrokes: [KeystrokeBadge] = [],
        keystrokeDelay: Double = 1.5, resolution: RecordingResolution = .fullHD,
        edits: RecordingEdits = RecordingEdits()
    ) async throws -> Prepared {
        let sourceAsset = AVURLAsset(url: source)
        guard let screen = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideo
        }
        let (screenSize, preferredScreen, screenRange) = try await screen.load(.naturalSize, .preferredTransform, .timeRange)
        let screenImage = RecordingCompositionInstruction.imageTransform(size: screenSize, preferred: preferredScreen)
        let screenBounds = CGRect(origin: .zero, size: screenSize).applying(screenImage)
        guard screenBounds.width > 0, screenBounds.height > 0, screenRange.duration > .zero else {
            throw ExportError.noVideo
        }
        let frameSize = resolution.outputSize(for: screenBounds.size, blurredBackdrop: edits.blurredBackdrop)
        let content = RecordingGeometry.fittedRect(source: screenBounds.size, canvas: frameSize)
        let outputRange = CMTimeRange(start: .zero, duration: screenRange.duration)
        let asset = AVMutableComposition()
        let screenLayer = try addTrack(.video, to: asset)
        try screenLayer.insertTimeRange(screenRange, of: screen, at: .zero)
        var audioParameters: [AVAudioMixInputParameters] = []
        for source in try await sourceAsset.loadTracks(withMediaType: .audio) {
            let range = try await source.load(.timeRange).intersection(screenRange)
            guard range.duration.isNumeric, range.duration > .zero else { continue }
            let audio = try addTrack(.audio, to: asset)
            try audio.insertTimeRange(range, of: source, at: range.start - screenRange.start)
            audioParameters.append(AVMutableAudioMixInputParameters(track: audio))
        }
        let mix: AVMutableAudioMix?
        if audioParameters.count > 1 {
            mix = AVMutableAudioMix()
            for case let parameters as AVMutableAudioMixInputParameters in audioParameters {
                parameters.setVolume(1 / Float(audioParameters.count), at: .zero)
            }
            mix?.inputParameters = audioParameters
        } else {
            mix = nil
        }

        var cameraEffect: CameraLayer?
        if let overlay {
            let cameraAsset = AVURLAsset(url: overlay.url)
            guard let camera = try await cameraAsset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noCameraVideo
            }
            let (cameraSize, preferred, sourceRange) = try await camera.load(.naturalSize, .preferredTransform, .timeRange)
            let cameraRange = outputRange.intersection(CMTimeRange(start: overlay.offset, duration: sourceRange.duration))
            guard cameraRange.duration.isNumeric, cameraRange.duration > .zero else {
                throw ExportError.noCameraVideo
            }
            let cameraLayer = try addTrack(.video, to: asset)
            let cameraTrim = CMTimeRange(start: sourceRange.start + (cameraRange.start - overlay.offset), duration: cameraRange.duration)
            try cameraLayer.insertTimeRange(cameraTrim, of: camera, at: cameraRange.start)
            let cameraImage = RecordingCompositionInstruction.imageTransform(size: cameraSize, preferred: preferred)
            let cameraBounds = CGRect(origin: .zero, size: cameraSize).applying(cameraImage)
            let bubble = overlay.corner.frame(in: frameSize)
            let scale = max(bubble.width / cameraBounds.width, bubble.height / cameraBounds.height)
            cameraEffect = CameraLayer(
                track: cameraLayer, timeRange: cameraRange,
                transform: cameraImage.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(
                        translationX: bubble.midX - cameraBounds.width * scale / 2,
                        y: bubble.midY - cameraBounds.height * scale / 2
                    )), bubble: bubble
            )
        }
        let scale = content.width / screenBounds.width
        let instruction = RecordingCompositionInstruction(
            timeRange: outputRange, screen: screenLayer, screenSize: screenSize,
            screenTransform: screenImage.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: content.minX, y: content.minY)),
            contentRect: content, edits: edits,
            camera: cameraEffect, clicks: clicks, keystrokes: keystrokes, keystrokeDelay: keystrokeDelay
        )
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = RecordingCompositor.self
        video.renderSize = frameSize
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [instruction]
        return Prepared(asset: asset, video: video, audio: mix, duration: screenRange.duration, contentRect: content)
    }

    private static func addTrack(_ type: AVMediaType, to asset: AVMutableComposition) throws -> AVMutableCompositionTrack {
        guard let track = asset.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.unavailable
        }
        return track
    }
}

private enum ExportError: LocalizedError {
    case noVideo, noCameraVideo, unavailable, overwritesOriginal

    var errorDescription: String? {
        switch self {
        case .noVideo: "The recording contains no usable video frames."
        case .noCameraVideo: "The camera clip has no video that overlaps the screen recording."
        case .unavailable: "The H.264 encoder is unavailable."
        case .overwritesOriginal: "Choose a destination other than the original recording media."
        }
    }
}
