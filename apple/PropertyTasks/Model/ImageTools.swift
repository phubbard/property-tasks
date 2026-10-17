import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PropertyTasksCore
import UniformTypeIdentifiers

/// Image helpers shared by iOS and macOS: hashing, EXIF reading and
/// client-side derivatives (DESIGN.md §11: the Worker never resizes).
enum ImageTools {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Info {
        var width: Int
        var height: Int
        var capturedAt: Millis?
        var gps: CaptureSidecar.GPS?
    }

    static func info(_ data: Data) -> Info? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        var info = Info(width: w, height: h)
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.timeZone = .current
            if let d = f.date(from: s) { info.capturedAt = Millis(d.timeIntervalSince1970 * 1000) }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            info.gps = CaptureSidecar.GPS(lat: latRef == "S" ? -lat : lat, lon: lonRef == "W" ? -lon : lon,
                                          alt: gps[kCGImagePropertyGPSAltitude] as? Double,
                                          accuracyM: gps[kCGImagePropertyGPSHPositioningError] as? Double)
        }
        return info
    }

    /// A JPEG no larger than `maxPixel` on its long side.
    static func derivative(_ data: Data, maxPixel: Int, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }
}
