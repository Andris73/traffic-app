import CoreLocation
import Foundation

@MainActor
final class RouteEngine: ObservableObject {
    enum Status { case idle, loading, ready, failed }

    @Published var status: Status = .idle
    @Published private(set) var loadedID: String?

    private var graph: RoutingGraph?

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
        guard let graph else { return nil }
        return await Task.detached(priority: .userInitiated) {
            graph.route(from: from, to: to)
        }.value
    }
}
