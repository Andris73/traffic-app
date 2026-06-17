import CoreLocation
import Foundation

@MainActor
final class RouteEngine: ObservableObject {
    enum Status { case idle, loading, ready, failed }

    @Published var status: Status = .idle
    @Published private(set) var loadedID: String?
    @Published var aversion: Double {
        didSet { UserDefaults.standard.set(aversion, forKey: Self.aversionKey) }
    }
    @Published var trafficEnabled: Bool {
        didSet { UserDefaults.standard.set(trafficEnabled, forKey: Self.trafficKey) }
    }

    private static let aversionKey = "giveWayAversion"
    private static let trafficKey = "trafficEnabled"
    static let defaultAversion = 1.0

    private var graph: RoutingGraph?

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.aversionKey) as? Double {
            self.aversion = stored
        } else {
            self.aversion = Self.defaultAversion
        }
        if UserDefaults.standard.object(forKey: Self.trafficKey) != nil {
            self.trafficEnabled = UserDefaults.standard.bool(forKey: Self.trafficKey)
        } else {
            self.trafficEnabled = true
        }
    }

    func load(url: URL?, id: String) {
        guard let url else {
            graph = nil
            loadedID = nil
            status = .failed
            return
        }
        if loadedID == id, graph != nil { return }
        status = .loading
        Task.detached(priority: .userInitiated) {
            let loaded = RoutingGraph.load(from: url)
            await MainActor.run {
                self.graph = loaded
                self.loadedID = loaded == nil ? nil : id
                self.status = loaded == nil ? .failed : .ready
            }
        }
    }

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> Route? {
        await route(from: from, to: to, multiplier: aversion)
    }

    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, multiplier: Double) async -> Route? {
        guard let graph else { return nil }
        let traffic = TrafficModel(
            enabled: trafficEnabled,
            hour: Calendar.current.component(.hour, from: Date())
        )
        return await Task.detached(priority: .userInitiated) {
            graph.route(from: from, to: to, multiplier: multiplier, traffic: traffic)
        }.value
    }
}
