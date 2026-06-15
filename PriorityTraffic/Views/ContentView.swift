import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var search = PlaceSearch()
    @StateObject private var engine = RouteEngine()

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var destination: CLLocationCoordinate2D?
    @State private var destinationName = ""
    @State private var route: Route?
    @FocusState private var searchFocused: Bool

    private let fallback = StraightLineRouter()

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .topLeading) {
                map
                    .ignoresSafeArea()

                if location.isDenied {
                    permissionBanner
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, insets.top)
                }

                recenterButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, insets.bottom + (route == nil ? 84 : 150))

                searchPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 14)
                    .padding(.bottom, insets.bottom + 10)
            }
        }
        .onAppear {
            location.requestPermission()
            engine.loadIfNeeded()
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let destination {
                Marker(destinationName.isEmpty ? "Destination" : destinationName, coordinate: destination)
                    .tint(.green)
            }
            if let route {
                MapPolyline(coordinates: route.coordinates)
                    .stroke(.blue, lineWidth: 6)
            }
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 8) {
            if searchFocused && !search.results.isEmpty {
                resultsList
            }
            searchField
            if let route {
                routeSummary(route)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Where to?", text: $search.query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !search.query.isEmpty {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(search.results, id: \.self) { item in
                    Button { select(item) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .foregroundStyle(.primary)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
    }

    private func routeSummary(_ route: Route) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(distanceString(route.distanceMeters))
                    .font(.headline)
                Text(route.isPreview
                     ? "Straight-line preview — on-device routing coming next"
                     : "Give-way events: \(route.giveWayCount.map(String.init) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear") { clear() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
    }

    private var recenterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) {
                camera = .userLocation(fallback: .automatic)
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 50, height: 50)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("Centre on my location")
    }

    private var permissionBanner: some View {
        Text("Location access denied — enable it in Settings to route from your position.")
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.85))
    }

    private func select(_ item: MKLocalSearchCompletion) {
        destinationName = item.title
        searchFocused = false
        search.query = item.title
        Task {
            guard let coord = await search.resolve(item) else { return }
            destination = coord
            await computeRoute(to: coord)
        }
    }

    @MainActor
    private func computeRoute(to dest: CLLocationCoordinate2D) async {
        guard let start = location.lastLocation?.coordinate else { return }
        let result = await engine.route(from: start, to: dest)
            ?? (try? await fallback.route(from: start, to: dest))
        guard let result else { return }
        route = result
        withAnimation {
            camera = .region(regionFitting(start, dest))
        }
    }

    private func clear() {
        destination = nil
        destinationName = ""
        route = nil
        search.query = ""
        search.results = []
        searchFocused = false
    }

    private func distanceString(_ meters: CLLocationDistance) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func regionFitting(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2,
            longitude: (a.longitude + b.longitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: abs(a.latitude - b.latitude) * 1.6 + 0.01,
            longitudeDelta: abs(a.longitude - b.longitude) * 1.6 + 0.01
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
