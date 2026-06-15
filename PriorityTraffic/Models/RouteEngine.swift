import CoreLocation
import Foundation

@MainActor
final class RouteEngine: ObservableObject {
    enum Status { case loading, ready, failed }

    @Published var status: Status = .loading

    private var graph: RoutingGraph?

    func loadIfNeeded() {
        guard graph == nil, status != .failed else { return }
        Task.detached(priority: .userInitiated) {
            let loaded = RoutingGraph.loadBundled()
            await MainActor.run {
                self.graph = loaded
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
