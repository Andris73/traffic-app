import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .ignoresSafeArea()

            header
        }
        .onAppear { location.requestPermission() }
        .overlay(alignment: .bottom) { permissionBanner }
    }

    private var header: some View {
        Text("Priority Traffic")
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
    }

    @ViewBuilder
    private var permissionBanner: some View {
        if location.authorization == .denied || location.authorization == .restricted {
            Text("Location access denied — enable it in Settings to route from your position.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.85))
        }
    }
}
