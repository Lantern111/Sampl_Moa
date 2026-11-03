import Darwin
import Foundation

/// A file in iCloud Drive or another cloud folder may exist on this Mac as a name only. Opening one makes the system
/// download it, and blocks until that's done, so nothing should read a sample's contents without checking here first.
nonisolated enum CloudFiles {
    static func isOnThisMac(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        // `SF_DATALESS`: the system holds the file's name and size, but its contents are in the cloud.
        return info.st_flags & 0x4000_0000 == 0
    }

    static func requestDownload(of url: URL) {
        if (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) != nil { return }

        // Not every cloud provider takes that request, but all of them fetch a file when it's read.
        Task.detached(priority: .utility) {
            let file = try? FileHandle(forReadingFrom: url)
            _ = try? file?.read(upToCount: 1)
            try? file?.close()
        }
    }

    static func downloadFailed(_ url: URL) -> Bool {
        var url = url
        url.removeCachedResourceValue(forKey: .ubiquitousItemDownloadingErrorKey)
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
        return values?.ubiquitousItemDownloadingError != nil
    }
}
