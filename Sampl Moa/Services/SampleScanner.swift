import AudioToolbox
import Foundation

nonisolated enum SampleScanner {
    struct Result: Sendable {
        let accounts: [SpliceAccount]
        let samples: [Sample]
    }

    private static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "flac", "caf", "ogg",
    ]

    @concurrent static func scan(root: URL) async -> Result {
        let accounts = SpliceFolders.locate(in: root).map(SpliceAccount.init(folder:))
        return Result(accounts: accounts, samples: accounts.flatMap(samples(in:)))
    }

    @concurrent static func readDurations(of urls: [URL]) async -> [TimeInterval?] {
        urls.map(readDuration(of:))
    }

    private static func samples(in account: SpliceAccount) -> [Sample] {
        // Only `sounds` holds downloads. `INSTRUMENT` and `presets` belong to Splice's plugins.
        let sounds = account.folder.appending(path: "sounds", directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: sounds,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var samples: [Sample] = []
        for case let url as URL in enumerator {
            let format = url.pathExtension.lowercased()
            guard audioExtensions.contains(format),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }

            samples.append(Sample(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                pack: packName(of: url, in: sounds),
                accountID: account.id,
                accountName: account.name,
                format: format.uppercased(),
                fileSize: Int64(values.fileSize ?? 0)
            ))
        }
        return samples
    }

    /// Splice stores samples as `sounds/packs/<pack>/…`.
    private static func packName(of url: URL, in sounds: URL) -> String {
        let relative = url.pathComponents.dropFirst(sounds.pathComponents.count).dropLast()
        if relative.first == "packs", let pack = relative.dropFirst().first { return pack }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private static func readDuration(of url: URL) -> TimeInterval? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }

        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr else {
            return nil
        }
        return duration
    }
}
