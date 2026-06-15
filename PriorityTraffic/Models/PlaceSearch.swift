import Combine
import MapKit

@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = ""
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
        cancellable = $query
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.apply(text) }
    }

    func biasRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    private func apply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        let response = try? await search.start()
        return response?.mapItems.first?.placemark.coordinate
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
