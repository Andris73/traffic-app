import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var search = PlaceSearch()
    @StateObject private var store = GraphStore()
    @StateObject private var engine = RouteEngine()

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var destination: CLLocationCoordinate2D?
    @State private var destinationName = ""
    @State private var route: Route?
    @State private var navigating = false
    @State private var showSettings = false
    @FocusState private var searchFocused: Bool

    private let fallback = StraightLineRouter()
    private let rerouteTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .topLeading) {
                map.ignoresSafeArea()

                if location.isDenied {
                    permissionBanner
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, insets.top)
                }

                settingsButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 16)
                    .padding(.top, insets.top + 8)

                recenterButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, insets.bottom + (route == nil ? 84 : 160))

                searchPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 14)
                    .padding(.bottom, insets.bottom + 10)
            }
        }
        .onAppear {
            location.requestPermission()
            engine.load(url: store.activeURL(), id: store.activeID)
        }
        .onChange(of: store.activeID) { _, _ in
            engine.load(url: store.activeURL(), id: store.activeID)
        }
        .onChange(of: navigating) { _, isNav in
            withAnimation {
                camera = isNav
                    ? .userLocation(followsHeading: true, fallback: .automatic)
                    : .userLocation(fallback: .automatic)
            }
            if isNav {
                location.startNavigation()
            } else {
                location.stopNavigation()
            }
        }
        .onReceive(rerouteTimer) { _ in
            Task { await rerouteIfBetter() }
        }
        .task(id: engine.aversion) {
            guard let dest = destination, route != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            await computeRoute(to: dest)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, engine: engine)
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
                ForEach(Array(route.giveWayEvents.enumerated()), id: \.offset) { _, event in
                    Annotation("", coordinate: event.coordinate) {
                        Circle()
                            .fill(event.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(timeString(route.travelTimeSeconds))  ·  \(distanceString(route.distanceMeters))")
                            .font(.headline)
                    Text(detailLine(for: route))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !route.isPreview && !navigating {
                aversionRow
            }
            HStack(spacing: 10) {
                if navigating {
                    Button(role: .destructive) {
                        navigating = false
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button("Clear") { clear() }
                        .buttonStyle(.bordered)
                    if !route.isPreview {
                        Button {
                            navigating = true
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
    }

    private func detailLine(for route: Route) -> String {
        if route.isPreview {
            return "Straight-line preview — destination is outside the active map."
        }
        let count = route.giveWayCount ?? 0
        let prefix = navigating ? "Live" : "Give-way"
        return "\(prefix): \(count) events  ·  aversion \(String(format: "%.1f×", engine.aversion))"
    }

    private func timeString(_ seconds: Double) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60) h \(mins % 60) min"
    }

    private var aversionRow: some View {
        VStack(spacing: 1) {
            Slider(value: $engine.aversion, in: 0...3, step: 0.25)
            HStack {
                Text("Fastest")
                Spacer()
                Text("Avoid give-ways")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("Settings")
    }

    private var recenterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) {
                camera = navigating
                    ? .userLocation(followsHeading: true, fallback: .automatic)
                    : .userLocation(fallback: .automatic)
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
        var result = await engine.route(from: start, to: dest)
        if result == nil {
            result = try? await fallback.route(from: start, to: dest)
        }
        guard let result else { return }
        route = result
        if !navigating {
            withAnimation {
                camera = .region(regionFitting(start, dest))
            }
        }
    }

    @MainActor
    private func rerouteIfBetter() async {
        guard navigating,
              let dest = destination,
              let start = location.lastLocation?.coordinate,
              let candidate = await engine.route(from: start, to: dest) else { return }
        guard let current = route else {
            route = candidate
            return
        }
        let curCount = current.giveWayCount ?? .max
        let newCount = candidate.giveWayCount ?? .max
        let better = newCount < curCount
            || (newCount == curCount && candidate.distanceMeters < current.distanceMeters * 0.97)
        if better {
            route = candidate
        }
    }

    private func clear() {
        if navigating { navigating = false }
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
