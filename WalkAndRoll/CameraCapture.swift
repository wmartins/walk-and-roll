import AVFoundation

struct CameraClip {
    let url: URL
    let firstFrame: CMTime
}

enum CameraCorner: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    var id: Self { self }

    func frame(in canvas: CGSize) -> CGRect {
        let shortSide = min(canvas.width, canvas.height)
        let side = shortSide * 0.23
        let margin = shortSide * 0.035
        let x = self == .topLeft || self == .bottomLeft ? margin : canvas.width - margin - side
        let y = self == .bottomLeft || self == .bottomRight ? margin : canvas.height - margin - side
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "WalkAndRoll.camera")
    private var configured = false
    private var file: CameraFile?

    func startPreview() async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configure()
                    if !self.session.isRunning { self.session.startRunning() }
                    guard self.session.isRunning else { throw CameraError.unavailable }
                    completion.resume()
                } catch {
                    completion.resume(throwing: error)
                }
            }
        }
    }

    private func configure() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.unavailable
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        // The preview and written video use the same unmirrored orientation.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        configured = true
    }

    func beginRecording(to url: URL) async -> Bool {
        await withCheckedContinuation { completion in
            queue.async {
                guard self.session.isRunning else {
                    completion.resume(returning: false)
                    return
                }
                self.file = CameraFile(url: url)
                completion.resume(returning: true)
            }
        }
    }

    func stop() {
        queue.async {
            let file = self.file
            self.file = nil
            if let writer = file?.writer, writer.status == .writing { writer.cancelWriting() }
            self.session.stopRunning()
            if let file { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    func finishRecording() async -> CameraClip? {
        await withCheckedContinuation { completion in
            queue.async {
                let file = self.file
                self.file = nil
                self.session.stopRunning()
                guard let file, let writer = file.writer, writer.status == .writing, file.firstFrame.isNumeric else {
                    if let file { try? FileManager.default.removeItem(at: file.url) }
                    completion.resume(returning: nil)
                    return
                }

                file.adaptor?.assetWriterInput.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        completion.resume(returning: CameraClip(url: file.url, firstFrame: file.firstFrame))
                    } else {
                        try? FileManager.default.removeItem(at: file.url)
                        completion.resume(returning: nil)
                    }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let file, !file.failed, let buffer = sample.imageBuffer,
              let clock = session.synchronizationClock else { return }
        let time = clock.convertTime(sample.presentationTimeStamp, to: CMClock.hostTimeClock)
        guard time.isNumeric else { return }

        do {
            if file.writer == nil { try file.start(with: buffer, at: time) }
            guard let adaptor = file.adaptor, adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
            if adaptor.append(buffer, withPresentationTime: time) {
                if !file.firstFrame.isNumeric { file.firstFrame = time }
            } else {
                file.failed = true
                if let writer = file.writer, writer.status == .writing { writer.cancelWriting() }
            }
        } catch {
            file.failed = true
        }
    }
}

private final class CameraFile {
    let url: URL
    var firstFrame = CMTime.invalid
    var writer: AVAssetWriter?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    var failed = false

    init(url: URL) { self.url = url }

    func start(with buffer: CVPixelBuffer, at time: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: CVPixelBufferGetWidth(buffer),
            AVVideoHeightKey: CVPixelBufferGetHeight(buffer)
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CameraError.unavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? CameraError.unavailable }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.adaptor = adaptor
    }
}

private enum CameraError: LocalizedError {
    case unavailable

    var errorDescription: String? { "The camera couldn’t start." }
}
