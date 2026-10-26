import SwiftUI

@main struct VolterraDSPPredictorApp: App {
    init() {
        // `--profile [frames]`: headless Release-build profiling, exits when done.
        HeadlessProfiler.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("VolterraDSPPredictor") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 760)
        }
    }
}
