import SwiftUI
import UIKit

@main
struct YOLOkemonApp: App {
    // Shared across Live / Dashboard / Export tabs so every view reads
    // the same in-memory log. LiveView appends; Dashboard renders the
    // rollup; Export serializes it to CSV/JSON.
    @StateObject private var sessionLog = SessionLogStore()

    // YOLOkémon persistent catalog. LiveView writes
    // when a capture succeeds; the Pokédex tab reads. Loaded
    // from `Documents/pokedex.json` on init so the dex survives
    // relaunches.
    @StateObject private var pokedexStore = PokedexStore()

    @MainActor
    init() {
        // Needed for UIDevice.batteryLevel to return a real value
        // instead of -1. The Dashboard and per-frame LogRecord both
        // read from this — opting in at app launch avoids having to
        // gate every reader.
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionLog)
                .environmentObject(pokedexStore)
        }
    }
}
