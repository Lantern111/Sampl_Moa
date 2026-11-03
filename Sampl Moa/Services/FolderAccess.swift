import AppKit
import Darwin

/// Holds the read-only permission for the folder the user chose in the open panel.
/// The sandbox grants that access only for the current launch, so it's kept in a security-scoped bookmark.
final class FolderAccess {
    private static let bookmarkKey = "libraryRootBookmark"

    private var scopedURL: URL?

    /// The user's real home folder. Inside the sandbox, `FileManager` reports the app's container instead.
    static var userHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Returns the folder approved on an earlier launch, or `nil` if the permission is missing or no longer valid.
    func restore() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return nil
        }

        scopedURL = url
        if isStale { try? save(url) }
        return url
    }

    /// Shows the open panel with the user's home folder already selected.
    func chooseFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.userHome
        panel.message = String(localized: "Select your user folder to give Sampl Moa read-only access.")
        panel.prompt = String(localized: "Allow")

        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }

    /// Remembers `url` for later launches. Stays read-only so the app can't alter the user's samples.
    func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
    }

    func replaceScopedURL(with url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }
}
