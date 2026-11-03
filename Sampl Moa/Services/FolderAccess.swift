import AppKit
import Darwin

/// Remembers the folders the user added. Each stays readable across launches through a security-scoped bookmark,
/// which is what makes folders outside the user's home, such as on an external drive, keep working.
final class FolderAccess {
    private static let bookmarksKey = "addedFolderBookmarks"

    private var scopedURLs: [URL] = []

    /// The user's real home folder. Inside the sandbox, `FileManager` reports the app's container instead.
    static var userHome: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: Self.bookmarksKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.bookmarksKey) }
    }

    func restoreFolders() -> [URL] {
        bookmarks.values.compactMap { bookmark in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }

            startAccessing(url)
            if isStale { save(url) }
            return url
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func chooseFolders() async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose a folder. All the audio files in it and its subfolders will be added.")
        panel.prompt = String(localized: "Add")

        guard await panel.begin() == .OK else { return [] }
        return panel.urls
    }

    func add(_ url: URL) {
        startAccessing(url)
        save(url)
    }

    func remove(_ url: URL) {
        bookmarks[url.standardizedFileURL.path] = nil
        if let index = scopedURLs.firstIndex(of: url) {
            scopedURLs.remove(at: index).stopAccessingSecurityScopedResource()
        }
    }

    private func startAccessing(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
    }

    /// Stays read-only so the app can't alter the user's samples.
    private func save(_ url: URL) {
        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        bookmarks[url.standardizedFileURL.path] = bookmark
    }
}
