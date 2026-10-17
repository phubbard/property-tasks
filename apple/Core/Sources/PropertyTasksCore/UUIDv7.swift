import Foundation
import Security

/// Time-ordered UUIDv7, matching shared/src/ids.ts.
public func uuidv7(now: Millis = Millis(Date().timeIntervalSince1970 * 1000)) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
    let ms = UInt64(now)
    bytes[0] = UInt8((ms >> 40) & 0xff)
    bytes[1] = UInt8((ms >> 32) & 0xff)
    bytes[2] = UInt8((ms >> 24) & 0xff)
    bytes[3] = UInt8((ms >> 16) & 0xff)
    bytes[4] = UInt8((ms >> 8) & 0xff)
    bytes[5] = UInt8(ms & 0xff)
    bytes[6] = (bytes[6] & 0x0f) | 0x70
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let h = Array(hex)
    return "\(String(h[0..<8]))-\(String(h[8..<12]))-\(String(h[12..<16]))-\(String(h[16..<20]))-\(String(h[20..<32]))"
}
