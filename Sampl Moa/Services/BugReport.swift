import AppKit

/// Opens the bug report form in the browser, with the versions already filled in so nobody has to look them up.
/// The form passes reports on to the developer's email, so the app needs no internet access and shows no address.
enum BugReport {
    private static let formAddress =
        "https://docs.google.com/forms/d/e/1FAIpQLSd9EkOKriMZ6I81EN8zIILyKDtNbfAg2Ka3HH9nRg2-TEy_jA/viewform"

    static func open() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let macOS = ProcessInfo.processInfo.operatingSystemVersion

        var components = URLComponents(string: formAddress)
        components?.queryItems = [
            URLQueryItem(name: "usp", value: "pp_url"),
            URLQueryItem(name: "entry.765315099", value: appVersion),
            URLQueryItem(name: "entry.606096784", value: "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)"),
        ]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }
}
