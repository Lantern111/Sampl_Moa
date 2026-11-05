import AudioToolbox
import Foundation

nonisolated enum SampleScanner {
    struct Result: Sendable {
        let spliceFolders: [URL]
        let samples: [Sample]
    }

    private static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "flac", "caf", "ogg",
    ]
    private static let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey]

    @concurrent static func scan(home: URL, folders: [URL]) async -> Result {
        let spliceFolders = SpliceFolders.locate(in: home)
        let spliceInfo = spliceFolders.isEmpty ? [:] : SpliceDatabase.loadSampleInfo(home: home)

        // The same pack downloaded from two accounts should only show up once.
        var seenSpliceSamples: Set<String> = []
        var samples = spliceFolders.flatMap { samples(inSplice: $0, info: spliceInfo, seen: &seenSpliceSamples) }

        // Added folders may overlap each other, so a file is only listed the first time it's found.
        var seenPaths: Set<String> = []
        for folder in folders where !Task.isCancelled {
            samples += self.samples(inFolder: folder, seen: &seenPaths)
        }
        return Result(spliceFolders: spliceFolders, samples: samples)
    }

    @concurrent static func readDurations(of urls: [URL]) async -> [TimeInterval?] {
        urls.map { CloudFiles.isOnThisMac($0) ? readDuration(of: $0) : nil }
    }

    private static func samples(
        inSplice spliceFolder: URL,
        info: [String: SpliceSampleInfo],
        seen: inout Set<String>
    ) -> [Sample] {
        // Only `sounds` holds downloads. `INSTRUMENT` and `presets` belong to Splice's plugins.
        let sounds = spliceFolder.appending(path: "sounds", directoryHint: .isDirectory)

        return audioFiles(in: sounds).compactMap { url, values in
            // Splice stores samples as `sounds/packs/<pack>/<folders…>/<file>`.
            var folders = Array(url.pathComponents.dropFirst(sounds.pathComponents.count).dropLast())
            if folders.first == "packs" { folders.removeFirst() }
            let pack = folders.isEmpty ? url.deletingLastPathComponent().lastPathComponent : folders.removeFirst()

            guard seen.insert("\(pack)/\(url.lastPathComponent)/\(values.fileSize ?? 0)").inserted else { return nil }

            let name = url.deletingPathExtension().lastPathComponent
            let details = info[url.lastPathComponent.lowercased()]
            let genres = details.map { SampleGenre.from(tags: $0.tags, packGenre: $0.packGenre) }
                ?? SampleGenre.guess(fileName: name, folders: [pack] + folders)
            let category = SampleCategory.classify(
                fileName: name,
                folders: folders,
                tags: details?.tags ?? [],
                isLoop: details?.isLoop ?? false,
                pack: pack
            )

            return makeSample(
                url: url, name: name, collection: pack, source: .splice, category: category, genres: genres,
                extraSearchText: details?.tags.joined(separator: " ") ?? "", values: values
            )
        }
    }

    private static func samples(inFolder folder: URL, seen: inout Set<String>) -> [Sample] {
        audioFiles(in: folder).compactMap { url, values in
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }

            let folders = Array(url.pathComponents.dropFirst(folder.pathComponents.count).dropLast())
            let name = url.deletingPathExtension().lastPathComponent

            return makeSample(
                url: url,
                name: name,
                collection: folders.last ?? folder.lastPathComponent,
                source: .folder(folder),
                category: SampleCategory.classify(fileName: name, folders: folders, pack: folder.lastPathComponent),
                genres: SampleGenre.guess(fileName: name, folders: [folder.lastPathComponent] + folders),
                extraSearchText: folders.joined(separator: " "),
                values: values
            )
        }
    }

    /// Every audio file under a folder, including its subfolders.
    private static func audioFiles(in folder: URL) -> [(URL, URLResourceValues)] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [(URL, URLResourceValues)] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files.append((url, values))
        }
        return files
    }

    private static func makeSample(
        url: URL,
        name: String,
        collection: String,
        source: SampleSource,
        category: SampleCategory,
        genres: [SampleGenre],
        extraSearchText: String,
        values: URLResourceValues
    ) -> Sample {
        let genreText = genres.flatMap { [$0.id, $0.title] + $0.aliases }.joined(separator: " ")
        let searchText = [name, collection, category.title, category.searchTerms, genreText, extraSearchText]
            .joined(separator: " ")

        return Sample(
            url: url,
            name: name,
            collection: collection,
            source: source,
            category: category,
            genres: genres,
            addedAt: values.creationDate ?? .distantPast,
            searchText: SampleSearch.normalize(searchText),
            availability: CloudFiles.isOnThisMac(url) ? .onThisMac : .inCloud
        )
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

nonisolated enum SampleSearch {
    /// Makes text comparable regardless of case and of how macOS happened to compose Korean file names.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
