import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: GraphStore
    @ObservedObject var engine: RouteEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.areas) { area in
                        AreaRow(area: area, store: store, engine: engine)
                    }
                } header: {
                    Text("Search area")
                } footer: {
                    Text("Downloaded maps are stored on your device and used for offline routing inside their bounding box.")
                }

                Section("Coming soon") {
                    bullet("Pick your own area (counties, regions) and build the graph on-device — no need to ship every region in the app.")
                    bullet("Give-way aversion slider — trade a longer route for fewer give-way events.")
                    bullet("Time-of-day historical traffic profile (UK National Highways).")
                }

                Section {
                    Text("Priority Traffic routes you for right-of-way, picking roads where you keep priority and give way as little as possible.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refreshManifest() }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct AreaRow: View {
    let area: GraphArea
    @ObservedObject var store: GraphStore
    @ObservedObject var engine: RouteEngine

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(area.name).font(.body)
                Text(sizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
    }

    private var isInstalled: Bool { store.installed.contains(area.id) }
    private var isActive: Bool { store.activeID == area.id }
    private var isDownloading: Bool { store.downloading.contains(area.id) }

    private var sizeString: String {
        String(format: "%.1f MB", Double(area.sizeBytes) / 1_000_000)
    }

    @ViewBuilder
    private var action: some View {
        if isDownloading {
            ProgressView()
        } else if isActive {
            Label("Active", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.title3)
        } else if isInstalled {
            HStack(spacing: 8) {
                Button("Use") {
                    store.setActive(area.id)
                    engine.load(url: store.activeURL(), id: store.activeID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if !area.bundled {
                    Button(role: .destructive) {
                        store.delete(area)
                        engine.load(url: store.activeURL(), id: store.activeID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            Button("Download") {
                Task { await store.download(area) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
