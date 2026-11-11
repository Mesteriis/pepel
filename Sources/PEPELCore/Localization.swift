import Foundation

/// A sentence shown to a person, in the language macOS chose for PEPEL (English or Russian).
///
/// The compiler records every literal passed here as a key of `Resources/Localizable.xcstrings`
/// (`Scripts/sync-strings.sh`). Interpolated values become arguments, so the translation can put
/// them where its grammar wants; counts get plural forms there. Codes that code compares (audit
/// outcomes, keys, identifiers) must never go through this.
public func L(_ resource: LocalizedStringResource) -> String {
    guard let bundle = Localization.commandLineBundle else { return String(localized: resource) }
    // The command-line tool always speaks English (scripts and agents read it), but takes the
    // English plural forms from the app's catalog so that it says "1 file", not "1 files".
    return String(localized: resource.defaultValue, table: resource.table, bundle: bundle, locale: Locale(identifier: "en"))
}

enum Localization {
    /// The PEPEL.app around `Contents/Helpers/pepel` when this process is the command-line tool;
    /// nil in the app itself, and in tests or a bare build where there is no app around it.
    static let commandLineBundle: Bundle? = {
        guard Bundle.main.bundleURL.pathExtension != "app", let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/en.lproj") else { return nil }
        // The en.lproj folder itself as the bundle, so the Russian table is never chosen.
        return Bundle(path: app.path + "/Contents/Resources/en.lproj")
    }()
}
