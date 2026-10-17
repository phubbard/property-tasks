#if os(iOS)
import CoreLocation
import CoreMotion
import Foundation
import PropertyTasksCore

/// Raw sensor readings for the capture sidecar (DESIGN.md §9): GPS with accuracy, compass
/// heading and device attitude, sampled continuously while the camera is open and frozen
/// at the shutter by `snapshot()`. Permission is requested when-in-use and every reading is
/// optional, so a denial just leaves those fields nil and EXIF fills what it can.
@MainActor
final class CaptureSensors: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private var running = false

    private(set) var gps: CaptureSidecar.GPS?
    private(set) var headingDeg: Double?
    private(set) var attitude: CaptureSidecar.Attitude?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        authorization = location.authorizationStatus
    }

    func start() {
        guard !running else { return }
        running = true
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else {
            startLocationIfAllowed()
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] dm, _ in
                guard let dm else { return }
                let a = dm.attitude
                let roll = a.roll, pitch = a.pitch, yaw = a.yaw
                let magnetic = dm.heading
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.attitude = CaptureSidecar.Attitude(roll: roll, pitch: pitch, yaw: yaw)
                    // Core Motion's heading is only valid with a magnetic-north reference frame;
                    // the compass (CLHeading) wins when it is reporting.
                    if self.headingDeg == nil, magnetic >= 0 { self.headingDeg = magnetic }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
    }

    private func startLocationIfAllowed() {
        switch location.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            location.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
        default:
            break
        }
    }

    /// Everything the sensors know right now; the camera calls this at the shutter.
    func snapshot() -> CaptureSidecar {
        CaptureSidecar(capturedAt: Millis(Date().timeIntervalSince1970 * 1000), gps: gps, headingDeg: headingDeg, attitude: attitude)
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread, where the manager was made)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorization = status
            if running { startLocationIfAllowed() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let alt: Double? = loc.verticalAccuracy >= 0 ? loc.altitude : nil
        let acc: Double? = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        MainActor.assumeIsolated {
            gps = CaptureSidecar.GPS(lat: lat, lon: lon, alt: alt, accuracyM: acc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let deg = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard deg >= 0 else { return }
        MainActor.assumeIsolated { headingDeg = deg }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is optional; a failure just leaves `gps` as it was.
    }
}
#endif
