import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            ZStack(alignment: .topLeading) {
                Map(position: $camera) {
                    UserAnnotation()
                }
                .ignoresSafeArea()

                title
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, insets.top + 6)

                recenterButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, insets.bottom + 24)

                if location.isDenied {
                    permissionBanner
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .onAppear { location.requestPermission() }
    }

    private var title: some View {
        Text("Priority Traffic")
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 4, y: 1)
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
}
