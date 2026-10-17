import Foundation
import PropertyTasksCore

/// One photo on its way into the Space: the encoded bytes plus whatever the
/// sensors said at shutter time. Platform-neutral so the same commit path
/// serves the iOS camera, the photo picker and tests.
struct CapturedPhoto: Sendable {
    var data: Data
    var mime: String
    /// Sensor readings taken at the shutter (GPS, heading, attitude). EXIF fills the gaps.
    var sensors: CaptureSidecar?
    var capturedAt: Millis?

    init(data: Data, mime: String = "image/jpeg", sensors: CaptureSidecar? = nil, capturedAt: Millis? = nil) {
        self.data = data; self.mime = mime; self.sensors = sensors; self.capturedAt = capturedAt
    }
}

/// Hashing and derivatives done off the main actor; the result is what the event and the
/// upload queue need.
struct PreparedPhoto: Sendable {
    var sha256: String
    var info: ImageTools.Info?
    var thumb: Data?
    var phone: Data?

    static func prepare(_ data: Data) -> PreparedPhoto {
        PreparedPhoto(sha256: ImageTools.sha256Hex(data), info: ImageTools.info(data),
                      thumb: ImageTools.derivative(data, maxPixel: 256),
                      phone: ImageTools.derivative(data, maxPixel: 2048))
    }
}

extension CaptureSidecar {
    /// Sensor values win; EXIF-derived values fill whatever the sensors could not provide.
    static func merge(sensors: CaptureSidecar?, exif: ImageTools.Info?, capturedAt: Millis?) -> CaptureSidecar {
        var out = sensors ?? CaptureSidecar()
        out.capturedAt = out.capturedAt ?? capturedAt ?? exif?.capturedAt
        out.gps = out.gps ?? exif?.gps
        if let exif {
            let fromExif = Intrinsics(focalLengthMm: exif.focalLengthMm, sensorWidthMm: exif.sensorWidthMm,
                                      imageWidth: exif.width, imageHeight: exif.height)
            if var i = out.intrinsics {
                i.focalLengthMm = i.focalLengthMm ?? fromExif.focalLengthMm
                i.sensorWidthMm = i.sensorWidthMm ?? fromExif.sensorWidthMm
                out.intrinsics = i
            } else {
                out.intrinsics = fromExif
            }
        }
        return out
    }
}

extension SpaceStore {
    /// The offline photo flow (DESIGN.md §3, §11): hash and derive off the main actor, stage the
    /// original and both derivatives for upload, then record attachment.added at once. The bytes
    /// follow in `drainUploads`, which `submit` triggers through `flush`.
    @discardableResult
    func attachPhoto(_ photo: CapturedPhoto, to nodeId: String) async -> String? {
        let data = photo.data
        let prepared = await Task.detached(priority: .userInitiated) { PreparedPhoto.prepare(data) }.value
        let sha = prepared.sha256
        guard stageBlob(sha256: sha, variant: nil, data: data, mime: photo.mime) else { return nil }
        if let thumb = prepared.thumb { stageBlob(sha256: sha, variant: "thumb", data: thumb, mime: "image/jpeg") }
        if let phone = prepared.phone { stageBlob(sha256: sha, variant: "phone", data: phone, mime: "image/jpeg") }
        let capture = CaptureSidecar.merge(sensors: photo.sensors, exif: prepared.info, capturedAt: photo.capturedAt)
        let ext = photo.mime == "image/heic" ? "heic" : photo.mime == "image/png" ? "png" : "jpg"
        let input = AttachmentInput(id: uuidv7(), kind: .image, mime: photo.mime, filename: "\(sha.prefix(12)).\(ext)", byteSize: data.count,
                                    sha256: sha, url: nil, width: prepared.info?.width, height: prepared.info?.height, durationMs: nil,
                                    caption: "", sortKey: uuidv7(), capture: capture)
        let ok = await submit(.attachmentAdded(AttachmentAddedPayload(attachment: input)), nodeId: nodeId)
        return ok ? input.id : nil
    }

    /// The capture sheet's Done button: create the task under `parentId` (nil means the root
    /// Inbox, created on first use) and attach every photo. Returns the new node id.
    func createCapturedItem(title: String, parentId: String?, priority: Priority, photos: [CapturedPhoto]) async -> String? {
        var parent = parentId
        if parent == nil {
            guard let inbox = await ensureInbox() else { return nil }
            parent = inbox
        }
        let nodeId = uuidv7()
        let payload = NodeCreatedPayload(parentId: parent, kind: .task, title: title.trimmingCharacters(in: .whitespacesAndNewlines), priority: priority)
        guard await submit(.nodeCreated(payload), nodeId: nodeId) else { return nil }
        for photo in photos { await attachPhoto(photo, to: nodeId) }
        return nodeId
    }
}
