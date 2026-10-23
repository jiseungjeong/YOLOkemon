import SwiftUI

/// Stable identifier for each tab in `ContentView`. Centralizing the
/// enum (instead of using `Int` .tag values) lets the voice command
/// `.openPokedex` and the Live controlPanel Pokédex toggle write to
/// the same `selectedTab` state without any integer bookkeeping.
enum Tab: Hashable {
    case live
    case dashboard
    case pokedex
    case export
}

struct ContentView: View {
    @State private var selectedTab: Tab = .live

    var body: some View {
        TabView(selection: $selectedTab) {
            LiveView(selectedTab: $selectedTab)
                .tabItem { Label("Live", systemImage: "camera") }
                .tag(Tab.live)

            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }
                .tag(Tab.dashboard)

            PokedexView()
                .tabItem { Label("Pokédex", systemImage: "book.closed.fill") }
                .tag(Tab.pokedex)

            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                .tag(Tab.export)
        }
        .tint(PokemonColor.pokeballRed)
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionLogStore())
        .environmentObject(PokedexStore())
}
