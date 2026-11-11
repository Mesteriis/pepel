import Foundation

/// A sentence shown to a person, in the language macOS chose for PEPEL (English or Russian).
///
/// The compiler records every literal passed here as a key of `Resources/Localizable.xcstrings`
/// (`Scripts/sync-strings.sh`). Interpolated values become arguments, so the translation can put
/// them where its grammar wants; counts get plural forms there. In the command-line tool there
/// is no catalog beside it and the English text is used, which keeps its output stable for scripts.
/// Codes that code compares (audit outcomes, keys, identifiers) must never go through this.
public func L(_ resource: LocalizedStringResource) -> String {
    String(localized: resource)
}
