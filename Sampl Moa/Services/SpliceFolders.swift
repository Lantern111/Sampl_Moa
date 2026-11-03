import Foundation

nonisolated enum SpliceFolders {
    static let accountFolderPrefix = "Splice - user-"

    static func isSpliceFolder(named name: String) -> Bool {
        name == "Splice" || name.hasPrefix(accountFolderPrefix)
    }

    /// Finds the Splice folders directly inside `root`, or `root` itself if the user picked one of them.
    static func locate(in root: URL) -> [URL] {
        if isSpliceFolder(named: root.lastPathComponent) { return [root] }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []

        return children
            .filter { url in
                isSpliceFolder(named: url.lastPathComponent)
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
