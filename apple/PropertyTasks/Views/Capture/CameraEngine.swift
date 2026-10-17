#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// An AVFoundation photo session that stays open between shots so several can be taken in a
/// row (DESIGN.md §3). Session work runs on its own serial queue; the preview layer attaches
/// to the session from the main thread, which AVFoundation permits.
final class CameraEngine: @unchecked Sendable {
    enum State: Sendable, Equatable { case idle, starting, running, unavailable(String) }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "net.phfactor.propertytasks.camera")
    private let output = AVCapturePhotoOutput()
    /// Only touched on `queue`.
    private var configured = false

    init() {}

    /// Ask for permission, configure the session once and start it. The caller keeps the
    /// returned state; it is `.running` only when a viewfinder can be shown.
    func start() async -> State {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var allowed = status == .authorized
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        guard allowed else {
            return .unavailable("Camera access is off. Allow it in Settings to take photos here.")
        }
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                if !configured {
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                          let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        cont.resume(returning: .unavailable("No camera on this device."))
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    output.maxPhotoQualityPrioritization = .balanced
                    session.commitConfiguration()
                    configured = true
                }
                if !session.isRunning { session.startRunning() }
                cont.resume(returning: .running)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Take one photo; resolves with the encoded file bytes (JPEG) once AVFoundation has them.
    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard configured, session.isRunning else {
                    cont.resume(throwing: CameraError.notRunning)
                    return
                }
                let settings: AVCapturePhotoSettings
                if output.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .balanced
                let delegate = ShotDelegate(continuation: cont)
                ShotDelegate.retain(delegate)
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    enum CameraError: LocalizedError {
        case notRunning, noData
        var errorDescription: String? {
            switch self {
            case .notRunning: return "The camera is not running."
            case .noData: return "The camera returned no image."
            }
        }
    }

    /// One capture's delegate. AVFoundation calls it on an internal queue; the continuation
    /// carries the bytes back to whoever awaited `capture()`.
    private final class ShotDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<Data, Error>?
        private static let lock = NSLock()
        nonisolated(unsafe) private static var inFlight: [ObjectIdentifier: ShotDelegate] = [:]

        init(continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

        static func retain(_ d: ShotDelegate) { lock.lock(); inFlight[ObjectIdentifier(d)] = d; lock.unlock() }
        private static func release(_ d: ShotDelegate) { lock.lock(); inFlight[ObjectIdentifier(d)] = nil; lock.unlock() }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            guard let cont = continuation else { return }
            continuation = nil
            if let error { cont.resume(throwing: error); return }
            if let data = photo.fileDataRepresentation() { cont.resume(returning: data) } else { cont.resume(throwing: CameraError.noData) }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let cont = continuation { continuation = nil; cont.resume(throwing: error ?? CameraError.noData) }
            Self.release(self)
        }
    }
}

/// The live viewfinder.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#endif
