import CoreLocation

struct Route {
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: CLLocationDistance
    let giveWayCount: Int?
    let isPreview: Bool
}

protocol Router {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> Route
}

/// Temporary stand-in until the on-device give-way engine lands: a straight line
/// between the two points. Lets the A→B flow be exercised end to end.
struct StraightLineRouter: Router {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> Route {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return Route(
            coordinates: [from, to],
            distanceMeters: a.distance(from: b),
            giveWayCount: nil,
            isPreview: true
        )
    }
}
