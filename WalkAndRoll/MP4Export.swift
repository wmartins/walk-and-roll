import AVFoundation
import Darwin

enum RecordingResolution: String, CaseIterable, Identifiable {
    case sharper = "Sharper (native, up to 4K)"
    case fullHD = "1080p"

    var id: Self { self }

    func outputSize(for sourceSize: CGSize) -> CGSize {
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
        to destination: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideo
        }

        let (naturalSize, transform, timeRange) = try await video.load(.naturalSize, .preferredTransform, .timeRange)
        let image = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard image.width > 0, image.height > 0, timeRange.duration > .zero else {
            throw ExportError.noVideo
        }
        let frameSize = resolution.outputSize(for: image.size)
        let cameraExport = try await cameraComposition(
            camera, screen: video, asset: asset, screenRange: timeRange,
            screenSize: naturalSize, screenTransform: transform, frameSize: frameSize,
            clicks: clicks, keystrokes: keystrokes, keystrokeDelay: keystrokeDelay
        )
        let exportAsset: AVAsset = cameraExport?.asset ?? asset
        let preset = frameSize.width > 1920 || frameSize.height > 1080
            ? AVAssetExportPreset3840x2160
            : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else {
            throw ExportError.unavailable
        }

        if let cameraExport {
            session.videoComposition = cameraExport.video
        } else if !clicks.isEmpty || !keystrokes.isEmpty {
            session.videoComposition = overlayComposition(
                screen: video, screenSize: naturalSize, screenTransform: transform,
                timeRange: timeRange, frameSize: frameSize, camera: nil,
                clicks: clicks, keystrokes: keystrokes, keystrokeDelay: keystrokeDelay
            )
        } else {
            session.videoComposition = videoComposition(
                for: video, transform: transform, image: image, timeRange: timeRange, frameSize: frameSize
            )
        }
        let audioTracks = try await exportAsset.loadTracks(withMediaType: .audio)
        if audioTracks.count > 1 {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1 / Float(audioTracks.count), at: .zero)
                return parameters
            }
            session.audioMix = mix
        }
        session.timeRange = cameraExport == nil ? timeRange : CMTimeRange(start: .zero, duration: timeRange.duration)
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

    private static func videoComposition(
        for track: AVAssetTrack, transform: CGAffineTransform, image: CGRect, timeRange: CMTimeRange, frameSize: CGSize
    ) -> AVVideoComposition {
        // Fill the frame, including any fractional-pixel difference from rounding to even dimensions.
        let placement = transform
            .concatenating(CGAffineTransform(translationX: -image.minX, y: -image.minY))
            .concatenating(CGAffineTransform(scaleX: frameSize.width / image.width, y: frameSize.height / image.height))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placement, at: timeRange.start)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = frameSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }

    private static func cameraComposition(
        _ overlay: CameraOverlay?, screen: AVAssetTrack, asset sourceAsset: AVURLAsset, screenRange: CMTimeRange,
        screenSize: CGSize, screenTransform: CGAffineTransform, frameSize: CGSize,
        clicks: [ClickHighlight], keystrokes: [KeystrokeBadge], keystrokeDelay: Double
    ) async throws -> (asset: AVMutableComposition, video: AVVideoComposition)? {
        guard let overlay else { return nil }
        let cameraAsset = AVURLAsset(url: overlay.url)
        guard let camera = try await cameraAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noCameraVideo
        }
        let (cameraSize, preferred, sourceRange) = try await camera.load(.naturalSize, .preferredTransform, .timeRange)
        let outputRange = CMTimeRange(start: .zero, duration: screenRange.duration)
        let cameraRange = outputRange.intersection(CMTimeRange(start: overlay.offset, duration: sourceRange.duration))
        guard cameraRange.duration.isNumeric, cameraRange.duration > .zero else {
            throw ExportError.noCameraVideo
        }

        let asset = AVMutableComposition()
        let screenLayer = try addTrack(.video, to: asset)
        let cameraLayer = try addTrack(.video, to: asset)
        try screenLayer.insertTimeRange(screenRange, of: screen, at: .zero)
        let cameraTrim = CMTimeRange(start: sourceRange.start + (cameraRange.start - overlay.offset), duration: cameraRange.duration)
        try cameraLayer.insertTimeRange(cameraTrim, of: camera, at: cameraRange.start)
        // Load the screen audio from the same media file and preserve its offset within the screen clip.
        for source in try await sourceAsset.loadTracks(withMediaType: .audio) {
            let range = try await source.load(.timeRange).intersection(screenRange)
            guard range.duration.isNumeric, range.duration > .zero else { continue }
            let audio = try addTrack(.audio, to: asset)
            try audio.insertTimeRange(range, of: source, at: range.start - screenRange.start)
        }

        let cameraImage = RecordingCompositionInstruction.imageTransform(size: cameraSize, preferred: preferred)
        let cameraBounds = CGRect(origin: .zero, size: cameraSize).applying(cameraImage)
        let bubble = overlay.corner.frame(in: frameSize)
        let scale = max(bubble.width / cameraBounds.width, bubble.height / cameraBounds.height)
        let cameraEffect = CameraLayer(
            track: cameraLayer, timeRange: cameraRange,
            transform: cameraImage.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(
                    translationX: bubble.midX - cameraBounds.width * scale / 2,
                    y: bubble.midY - cameraBounds.height * scale / 2
                )),
            bubble: bubble
        )
        let composition = overlayComposition(
            screen: screenLayer, screenSize: screenSize, screenTransform: screenTransform,
            timeRange: outputRange, frameSize: frameSize, camera: cameraEffect,
            clicks: clicks, keystrokes: keystrokes, keystrokeDelay: keystrokeDelay
        )
        return (asset, composition)
    }

    private static func overlayComposition(
        screen: AVAssetTrack, screenSize: CGSize, screenTransform: CGAffineTransform,
        timeRange: CMTimeRange, frameSize: CGSize, camera: CameraLayer?,
        clicks: [ClickHighlight], keystrokes: [KeystrokeBadge], keystrokeDelay: Double
    ) -> AVVideoComposition {
        let screenImage = RecordingCompositionInstruction.imageTransform(size: screenSize, preferred: screenTransform)
        let screenBounds = CGRect(origin: .zero, size: screenSize).applying(screenImage)
        let instruction = RecordingCompositionInstruction(
            timeRange: timeRange, screen: screen, screenSize: screenSize,
            screenTransform: screenImage.concatenating(CGAffineTransform(
                scaleX: frameSize.width / screenBounds.width, y: frameSize.height / screenBounds.height
            )),
            camera: camera, clicks: clicks, keystrokes: keystrokes, keystrokeDelay: keystrokeDelay
        )
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = RecordingCompositor.self
        composition.renderSize = frameSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        return composition
    }

    private static func addTrack(_ type: AVMediaType, to asset: AVMutableComposition) throws -> AVMutableCompositionTrack {
        guard let track = asset.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.unavailable
        }
        return track
    }
}

private enum ExportError: LocalizedError {
    case noVideo, noCameraVideo, unavailable

    var errorDescription: String? {
        switch self {
        case .noVideo: "The recording contains no usable video frames."
        case .noCameraVideo: "The camera clip has no video that overlaps the screen recording."
        case .unavailable: "The H.264 encoder is unavailable."
        }
    }
}
