import SwiftUI
import MapKit

struct CustomAreaSheet: View {
    @ObservedObject var store: GraphStore
    @ObservedObject var engine: RouteEngine
    @StateObject private var builder = CustomAreaBuilder()
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var region: MKCoordinateRegion?
    @State private var name = ""

    private static let maxSideKm = 250.0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $camera) { }
                    .ignoresSafeArea(edges: .top)
                    .onMapCameraChange(frequency: .onEnd) { context in
                        region = context.region
                    }

                Rectangle()
                    .stroke(Color.blue, lineWidth: 3)
                    .background(Color.blue.opacity(0.06))
                    .padding(.horizontal, 24)
                    .padding(.top, 60)
                    .padding(.bottom, panelHeight + 24)
                    .allowsHitTesting(false)

                bottomPanel
            }
            .navigationTitle("Custom area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isWorking {
                workingView
            } else {
                sizeSummary
                TextField("Area name (e.g. Cambridgeshire + Suffolk)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button {
                    guard let region else { return }
                    Task { await runBuild(region: region) }
                } label: {
                    Label("Build this area", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canBuild)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var sizeSummary: some View {
        let dims = currentDimensions()
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected area")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(dims.label)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(dims.tooBig ? .red : .primary)
            }
            Spacer()
            if dims.tooBig {
                Text("Too large — zoom in")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Building \(name.isEmpty ? "area" : name)")
                .font(.headline)
            HStack(spacing: 10) {
                ProgressView()
                Text(builder.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var panelHeight: CGFloat { isWorking ? 140 : 170 }

    private var isWorking: Bool {
        switch builder.phase {
        case .fetching, .parsing, .contracting, .saving: return true
        default: return false
        }
    }

    private var canBuild: Bool {
        guard region != nil else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !currentDimensions().tooBig
    }

    private func currentDimensions() -> (label: String, tooBig: Bool) {
        guard let region else { return ("pan or zoom the map", false) }
        let cosLat = cos(region.center.latitude * .pi / 180)
        let widthKm = region.span.longitudeDelta * 111 * cosLat
        let heightKm = region.span.latitudeDelta * 111
        let label = String(format: "%.0f × %.0f km", widthKm, heightKm)
        let tooBig = widthKm > Self.maxSideKm || heightKm > Self.maxSideKm
        return (label, tooBig)
    }

    private func runBuild(region: MKCoordinateRegion) async {
        let bbox = bbox(for: region)
        let result = await builder.build(bbox: bbox, name: name, store: store)
        if result != nil {
            engine.load(url: store.activeURL(), id: store.activeID)
            dismiss()
        }
    }

    private func bbox(for region: MKCoordinateRegion) -> [Double] {
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        return [south, west, north, east]
    }
}
