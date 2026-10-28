import CoreLocation

/// When-in-use location for stills. Updates only while the camera session is running.
final class CaptureLocation: NSObject, CLLocationManagerDelegate {
    static let shared = CaptureLocation()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var last: CLLocation?

    var location: CLLocation? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func start() {
        DispatchQueue.main.async {
            self.manager.delegate = self
            self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            self.manager.distanceFilter = 15
            switch self.manager.authorizationStatus {
            case .notDetermined:
                self.manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                self.manager.startUpdatingLocation()
            default:
                break
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.manager.stopUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        lock.lock()
        last = newest
        lock.unlock()
    }
}
