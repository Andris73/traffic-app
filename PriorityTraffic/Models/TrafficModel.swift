import SwiftUI

enum TrafficLevel: Int, Sendable {
    case free, light, moderate, heavy

    var speedFactor: Double {
        switch self {
        case .free: return 1.0
        case .light: return 0.8
        case .moderate: return 0.6
        case .heavy: return 0.4
        }
    }

    var color: Color {
        switch self {
        case .free: return .green
        case .light: return .yellow
        case .moderate: return .orange
        case .heavy: return .red
        }
    }
}

/// Coarse time-of-day congestion estimate by road class. Placeholder until a
/// real per-segment provider (Mapbox traffic tiles) is wired in behind it.
/// Congestion concentrates on arterials (lower class = bigger road) at peak.
struct TrafficModel: Sendable {
    var enabled: Bool
    var hour: Int

    func level(roadClass: Int) -> TrafficLevel {
        guard enabled else { return .free }
        let peak = (7...9).contains(hour) || (16...18).contains(hour)
        let shoulder = hour == 6 || hour == 10 || hour == 15 || hour == 19
        if peak {
            if roadClass <= 3 { return .heavy }
            if roadClass <= 5 { return .moderate }
            return .light
        }
        if shoulder {
            if roadClass <= 3 { return .moderate }
            if roadClass <= 5 { return .light }
            return .free
        }
        return .free
    }

    func speedFactor(roadClass: Int) -> Double {
        level(roadClass: roadClass).speedFactor
    }
}
