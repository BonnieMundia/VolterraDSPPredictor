import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Live Dashboard", systemImage: "gauge.with.dots.needle.67percent") {
                LiveDashboardView()
            }
            Tab("Signal & PA", systemImage: "waveform.path") {
                Phase1DashboardView()
            }
            Tab("Volterra Engine", systemImage: "cube.transparent") {
                Phase2EngineView()
            }
            Tab("Adaptive DPD", systemImage: "arrow.triangle.2.circlepath") {
                Phase3DPDView()
            }
        }
    }
}

#Preview {
    ContentView()
}
