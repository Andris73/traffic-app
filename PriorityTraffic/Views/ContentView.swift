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
    @State private var options: [RouteOption] = []
    @State private var navigating = false
    @State private var showSettings = false
    @FocusState private var searchFocused: Bool

    @State private var lastRerouteAt = Date.distantPast

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
                    .padding(.bottom, insets.bottom + (route == nil ? 84 : (navigating ? 150 : 250)))

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
        .onChange(of: engine.trafficEnabled) { _, _ in
            guard let dest = destination else { return }
            Task { await computeOptions(to: dest) }
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
        .onReceive(location.$lastLocation) { loc in
            if let loc { locationUpdate(loc) }
        }
        .task(id: engine.aversion) {
            guard let dest = destination, route != nil, !navigating else { return }
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
            ForEach(options) { opt in
                if abs(opt.multiplier - engine.aversion) > 0.001 {
                    MapPolyline(coordinates: opt.route.coordinates)
                        .stroke(.gray.opacity(0.55), lineWidth: 4)
                }
            }
            if let route {
                if engine.trafficEnabled {
                    ForEach(Array(route.segments.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg.coordinates)
                            .stroke(seg.level.color, lineWidth: 6)
                    }
                } else {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(.blue, lineWidth: 6)
                }
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
                routePanel(route)
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

    private func routePanel(_ route: Route) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if navigating {
                header(route, live: true)
            } else {
                if options.count > 1 {
                    optionCards
                } else {
                    header(route, live: false)
                }
                if !route.isPreview {
                    aversionRow
                }
            }
            actionButtons(route)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
    }

    private func header(_ route: Route, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(timeString(route.travelTimeSeconds))  ·  \(distanceString(route.distanceMeters))")
                .font(.headline)
            Text(detailLine(for: route, live: live))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionCards: some View {
        HStack(spacing: 8) {
            ForEach(options) { opt in
                optionCard(opt)
            }
        }
    }

    private func optionCard(_ opt: RouteOption) -> some View {
        let active = abs(opt.multiplier - engine.aversion) < 0.001
        return Button {
            selectOption(opt)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(opt.label)
                    .font(.caption.bold())
                Text(timeString(opt.route.travelTimeSeconds))
                    .font(.subheadline.weight(.semibold))
                Text("\(opt.route.giveWayCount ?? 0) give-ways")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(distanceString(opt.route.distanceMeters))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(active ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Color.blue : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func actionButtons(_ route: Route) -> some View {
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

    private func detailLine(for route: Route, live: Bool) -> String {
        if route.isPreview {
            return "Straight-line preview — destination is outside the active map."
        }
        let count = route.giveWayCount ?? 0
        let prefix = live ? "Live" : "Give-way"
        return "\(prefix): \(count) events  ·  aversion \(String(format: "%.1f×", engine.aversion))"
    }

    private func timeString(_ seconds: Double) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins) min" }
        return "\(mins / 60) h \(mins % 60) min"
    }

    private var aversionRow: some View {
        VStack(spacing: 1) {
            Slider(value: $engine.aversion, in: 0...10, step: 0.5)
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
            await computeOptions(to: coord)
        }
    }

    private func selectOption(_ opt: RouteOption) {
        route = opt.route
        engine.aversion = opt.multiplier
    }

    @MainActor
    private func computeOptions(to dest: CLLocationCoordinate2D) async {
        guard let start = location.lastLocation?.coordinate else { return }
        let presets: [(Double, String)] = [(0, "Fastest"), (3, "Balanced"), (10, "Priority")]
        var seen = Set<String>()
        var opts = [RouteOption]()
        for (mult, label) in presets {
            guard let r = await engine.route(from: start, to: dest, multiplier: mult) else { continue }
            let sig = "\(r.giveWayCount ?? -1)-\(Int(r.distanceMeters / 20))"
            if seen.contains(sig) { continue }
            seen.insert(sig)
            opts.append(RouteOption(label: label, multiplier: mult, route: r))
        }

        if opts.isEmpty {
            options = []
            route = try? await fallback.route(from: start, to: dest)
        } else {
            options = opts
            let active = opts.first { $0.multiplier == 3 } ?? opts[0]
            route = active.route
            engine.aversion = active.multiplier
        }

        if route != nil, !navigating {
            withAnimation { camera = .region(regionFitting(start, dest)) }
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

    private func locationUpdate(_ loc: CLLocation) {
        guard navigating, let dest = destination, let current = route else { return }
        let off = distanceToRoute(loc.coordinate, current.coordinates)
        guard off > 45, Date().timeIntervalSince(lastRerouteAt) > 8 else { return }
        lastRerouteAt = Date()
        Task { await rerouteFromCurrent(to: dest) }
    }

    @MainActor
    private func rerouteFromCurrent(to dest: CLLocationCoordinate2D) async {
        guard let start = location.lastLocation?.coordinate,
              let r = await engine.route(from: start, to: dest) else { return }
        route = r
        options = []
    }

    private func distanceToRoute(_ p: CLLocationCoordinate2D, _ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return .greatestFiniteMagnitude }
        let mLat = 111_320.0
        let mLon = 111_320.0 * cos(p.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - p.longitude) * mLon, (c.latitude - p.latitude) * mLat)
        }
        var best = Double.greatestFiniteMagnitude
        var prev = xy(coords[0])
        for i in 1..<coords.count {
            let cur = xy(coords[i])
            best = min(best, segmentDistanceFromOrigin(prev, cur))
            prev = cur
        }
        return best
    }

    private func segmentDistanceFromOrigin(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return (a.x * a.x + a.y * a.y).squareRoot() }
        var t = -(a.x * dx + a.y * dy) / len2
        t = max(0, min(1, t))
        let px = a.x + t * dx
        let py = a.y + t * dy
        return (px * px + py * py).squareRoot()
    }

    private func clear() {
        if navigating { navigating = false }
        destination = nil
        destinationName = ""
        route = nil
        options = []
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
