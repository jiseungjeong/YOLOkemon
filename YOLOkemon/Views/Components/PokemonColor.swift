import SwiftUI

/// Type-safe wrappers around the YOLOkémon color set.
/// String-based `Color("...")` lookups crash silently on typos; routing
/// every reference through this enum makes the compiler the safety net.
enum PokemonColor {
    static let pokeballRed    = Color("PokeballRed")
    static let pokeballCenter = Color("PokeballCenter")
    static let pokedexYellow  = Color("PokedexYellow")
    static let pokedexBlue    = Color("PokedexBlue")
    static let lilacBG        = Color("LilacBG")
    static let softNeonPurple = Color("SoftNeonPurple")
    static let slateDim       = Color("SlateDim")
}
