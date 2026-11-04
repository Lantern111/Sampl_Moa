import Foundation

/// The language the app appears in. macOS reads this when an app launches, so a change needs a restart to show.
enum AppLanguage: String, Hashable {
    case system
    case english = "en"
    case korean = "ko"

    private static let languagesKey = "AppleLanguages"

    /// What was in effect when the app launched, which is what's on screen right now.
    static let inUse = saved

    static var saved: AppLanguage {
        // Only this app's own setting. Asking `UserDefaults.standard` would also return the Mac's language list.
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let language = (domain?[languagesKey] as? [String])?.first else { return .system }
        return language.hasPrefix(korean.rawValue) ? .korean : .english
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.languagesKey)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.languagesKey)
        }
    }
}
