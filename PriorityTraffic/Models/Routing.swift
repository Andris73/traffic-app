import CoreLocation
import SwiftUI

struct GiveWayEvent {
    let coordinate: CLLocationCoordinate2D
    let flagBits: UInt8
    let classStep: Bool
    let rightTurn: Bool

    var color: Color {
        if flagBits & 2 != 0 { return .red }        // stop sign
        if flagBits & 1 != 0 { return .orange }     // give-way marking
        if flagBits & 8 != 0 { return .blue }       // mini-roundabout
        if rightTurn { return .orange }              // right turn across oncoming
        if classStep { return .gray }                // joining a bigger road
        return .secondary
    }
}

struct Route {
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: CLLocationDistance
    let travelTimeSeconds: Double
    let giveWayCount: Int?
    let giveWayEvents: [GiveWayEvent]
    let isPreview: Bool
}

protocol Router {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> Route
}

struct StraightLineRouter: Router {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> Route {
        let a = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let dist = a.distance(from: b)
        return Route(
            coordinates: [from, to],
            distanceMeters: dist,
            travelTimeSeconds: dist / 13,
            giveWayCount: nil,
            giveWayEvents: [],
            isPreview: true
        )
    }
}
