import CoreServices
import Foundation

/// Reports when anything changes inside a set of folders, including their subfolders.
final class FolderWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private(set) var folders: [URL] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Also reports changes made since `eventID`, so nothing is missed between reading the folders and watching them.
    func watch(_ folders: [URL], since eventID: FSEventStreamEventId) {
        stop()
        self.folders = folders
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, _, flags, _ in
                guard let info else { return }
                // Catching up on past changes ends with an event that isn't a change itself.
                let changed = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                if changed {
                    MainActor.assumeIsolated { watcher.onChange() }
                }
            },
            &context,
            folders.map(\.path) as CFArray,
            eventID,
            1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
