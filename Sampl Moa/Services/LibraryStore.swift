import CoreServices
import Foundation
import Observation

@Observable
final class LibraryStore {
    let player = SamplePlayer()

    private(set) var isScanning = false
    private(set) var hasFinishedFirstScan = false
    private(set) var foundSpliceFolder = false
    private(set) var packs: [SamplePack] = []
    private(set) var folders: [SampleFolder] = []
    private(set) var spliceSampleCount = 0
    private(set) var folderSampleCount = 0
    private(set) var visibleSamples: [Sample] = []
    private(set) var selection: [Sample] = []
    /// Goes up whenever the keyboard should return to the sample list, so the arrow keys move through samples.
    private(set) var listFocusRequest = 0
    /// How many samples of each kind are in the current view, for the filter bar.
    private(set) var categoryCounts: [SampleCategory: Int] = [:]
    private(set) var genreCounts: [(genre: SampleGenre, count: Int)] = []

    var tab = LibraryTab.splice {
        didSet {
            guard tab != oldValue else { return }
            scope = .all
            category = nil
            genre = nil
            selection = []
        }
    }
    var scope = LibraryScope.all {
        didSet { refreshVisibleSamples() }
    }
    var category: SampleCategory? {
        didSet { refreshVisibleSamples() }
    }
    var genre: SampleGenre? {
        didSet { refreshVisibleSamples() }
    }
    var searchText = "" {
        didSet { refreshVisibleSamples() }
    }
    var sort = SampleSort() {
        didSet { refreshVisibleSamples() }
    }

    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var addedFolders: [URL] = []
    @ObservationIgnored private var knownDurations: [URL: TimeInterval] = [:]
    @ObservationIgnored private var downloading: Set<URL> = []
    @ObservationIgnored private var downloadWatcher: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let folderAccess = FolderAccess()
    @ObservationIgnored private var spliceFolders: [URL] = []
    @ObservationIgnored private var hasUnseenChanges = false
    @ObservationIgnored private var lastScanDate = Date.distantPast
    @ObservationIgnored private lazy var folderWatcher = FolderWatcher { [weak self] in
        self?.hasUnseenChanges = true
    }

    /// Some folders, such as those on network drives, don't report changes. This is how long they can go unchecked.
    private static let longestTimeBetweenScans: TimeInterval = 10 * 60

    init() {
        addedFolders = folderAccess.restoreFolders()
        rescan()
    }

    var title: String {
        switch scope {
        case .all: String(localized: "All Samples")
        case .pack(let name): name
        case .folder(let url): url.lastPathComponent
        }
    }

    var tabSampleCount: Int {
        tab == .splice ? spliceSampleCount : folderSampleCount
    }

    var hasActiveFilters: Bool {
        category != nil || genre != nil || !searchText.isEmpty || scope != .all
    }

    func clearFilters() {
        category = nil
        genre = nil
        searchText = ""
        scope = .all
    }

    // MARK: - Finding samples

    /// Picks up samples downloaded while the app was in the background. People come back here every time they've
    /// dragged a sample into another app, so this only scans when something has actually changed.
    func refreshIfIdle() {
        guard !isScanning else { return }

        let isOverdue = Date().timeIntervalSince(lastScanDate) > Self.longestTimeBetweenScans
        // A newly signed-in Splice account adds a folder that isn't being watched yet.
        if hasUnseenChanges || isOverdue || SpliceFolders.locate(in: FolderAccess.userHome) != spliceFolders {
            rescan()
        }
    }

    func rescan() {
        let folders = addedFolders
        let home = FolderAccess.userHome
        let scanStart = FSEventsGetCurrentEventId()

        scanTask?.cancel()
        isScanning = true
        hasUnseenChanges = false
        scanTask = Task {
            let result = await SampleScanner.scan(home: home, folders: folders)
            guard !Task.isCancelled else { return }

            spliceFolders = result.spliceFolders
            foundSpliceFolder = !result.spliceFolders.isEmpty
            lastScanDate = Date()
            let watched = result.spliceFolders + [SpliceDatabase.accountsFolder(home: home)] + folders
            if watched != folderWatcher.folders {
                folderWatcher.watch(watched, since: scanStart)
            }

            let scanned = result.samples.map { sample in
                var sample = sample
                sample.duration = knownDurations[sample.url]
                if sample.availability == .inCloud, downloading.contains(sample.url) {
                    sample.availability = .downloading
                }
                return sample
            }
            if scanned != samples {
                samples = scanned
                refreshCollections()
                refreshVisibleSamples()
            } else {
                refreshCollections()
            }
            isScanning = false
            hasFinishedFirstScan = true

            await loadMissingDurations()
        }
    }

    func addFolders() async {
        let chosen = await folderAccess.chooseFolders()
        guard !chosen.isEmpty else { return }

        for url in chosen where !addedFolders.contains(url) {
            folderAccess.add(url)
            addedFolders.append(url)
        }
        addedFolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        tab = .folders
        // Shows the new folders right away, before their contents have been read.
        refreshCollections()
        rescan()
    }

    /// Only takes the folder off the list. The files themselves stay where they are.
    func removeFolder(_ url: URL) {
        folderAccess.remove(url)
        addedFolders.removeAll { $0 == url }
        if scope == .folder(url) { scope = .all }
        rescan()
    }

    private func refreshCollections() {
        let spliceSamples = samples.filter { $0.source == .splice }
        spliceSampleCount = spliceSamples.count
        folderSampleCount = samples.count - spliceSamples.count

        packs = Dictionary(grouping: spliceSamples, by: \.collection)
            .map { SamplePack(name: $0.key, sampleCount: $0.value.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        folders = addedFolders.map { url in
            SampleFolder(url: url, sampleCount: samples.lazy.filter { $0.source == .folder(url) }.count)
        }
    }

    /// Lengths come from each file's header, so they fill in after the list is already on screen.
    private func loadMissingDurations() async {
        let pending = samples.indices.filter { samples[$0].duration == nil && samples[$0].availability == .onThisMac }
        let batchSize = max(200, pending.count / 20)

        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let indices = Array(pending[start..<min(start + batchSize, pending.count)])
            let durations = await SampleScanner.readDurations(of: indices.map { samples[$0].url })
            guard !Task.isCancelled else { return }

            for (index, duration) in zip(indices, durations) {
                samples[index].duration = duration
                knownDurations[samples[index].url] = duration
            }
            refreshVisibleSamples()
        }
    }

    // MARK: - Playing samples

    func requestListFocus() {
        listFocusRequest += 1
    }

    func updateSelection(to samples: [Sample], viaKeyboard: Bool) {
        selection = samples
        guard samples.count == 1, let sample = samples.first, sample.id != player.sample?.id else { return }

        // The arrow keys keep auditioning even after a short sample has ended. A click only takes over from a sound
        // that's still playing, because a click on a silent list may just be the start of a drag.
        if player.isPlaying || (viaKeyboard && player.isAuditioning) {
            play(sample)
        }
    }

    /// Plays right away if the sample is on this Mac. Otherwise downloads it first, then plays.
    func play(_ sample: Sample) {
        if CloudFiles.isOnThisMac(sample.url) {
            player.play(sample)
        } else {
            player.waitForDownload(of: sample)
            download(sample)
        }
    }

    func download(_ sample: Sample) {
        guard !downloading.contains(sample.url), !CloudFiles.isOnThisMac(sample.url) else { return }

        CloudFiles.requestDownload(of: sample.url)
        downloading.insert(sample.url)
        setAvailability(.downloading, of: sample.url)
        watchDownloads()
    }

    private func setAvailability(_ availability: SampleAvailability, of url: URL) {
        guard let index = samples.firstIndex(where: { $0.url == url }) else { return }
        samples[index].availability = availability
        refreshVisibleSamples()
    }

    /// Nothing announces when a download ends for an app that doesn't own the folder, so this checks once a second.
    private func watchDownloads() {
        guard downloadWatcher == nil else { return }

        downloadWatcher = Task {
            while !downloading.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                for url in downloading {
                    if CloudFiles.isOnThisMac(url) {
                        await finishDownload(of: url)
                    } else if CloudFiles.downloadFailed(url) {
                        failDownload(of: url)
                    }
                }
            }
            downloadWatcher = nil
        }
    }

    private func finishDownload(of url: URL) async {
        downloading.remove(url)
        setAvailability(.onThisMac, of: url)

        if let duration = await SampleScanner.readDurations(of: [url]).first ?? nil,
           let index = samples.firstIndex(where: { $0.url == url }) {
            samples[index].duration = duration
            knownDurations[url] = duration
            refreshVisibleSamples()
        }

        if player.isWaitingForDownload, player.sample?.id == url,
           let sample = samples.first(where: { $0.url == url }) {
            player.play(sample)
        }
    }

    private func failDownload(of url: URL) {
        downloading.remove(url)
        setAvailability(.inCloud, of: url)
        if player.isWaitingForDownload, player.sample?.id == url {
            player.downloadFailed()
        }
    }

    func togglePlayback(of sample: Sample) {
        selection = [sample]
        if sample.id != player.sample?.id {
            play(sample)
        } else if player.isWaitingForDownload {
            // Changed their mind. The download carries on, but nothing will start playing out of the blue.
            player.close()
        } else {
            player.toggle()
        }
        requestListFocus()
    }

    /// The player bar's button, which always acts on the sample already loaded in it.
    func toggleCurrentPlayback() {
        player.toggle()
        requestListFocus()
    }

    /// The selection may belong to a pack that's no longer on screen, so it only counts if it's still listed.
    private var listedSelection: Sample? {
        selection.first { selected in visibleSamples.contains { $0.id == selected.id } }
    }

    /// What the Left arrow does: starts the selected sample again from the beginning.
    func replaySelection() {
        if let sample = listedSelection ?? (player.sample == nil ? visibleSamples.first : nil) {
            selection = [sample]
            play(sample)
        } else if let sample = player.sample {
            play(sample)
        }
        requestListFocus()
    }

    /// What the Right arrow does: the same as the Down arrow, wherever the keyboard focus happens to be.
    func selectNextSample() {
        let current = selection.last.flatMap { selected in visibleSamples.firstIndex { $0.id == selected.id } }
        let next = current.map { $0 + 1 } ?? 0
        if visibleSamples.indices.contains(next) {
            updateSelection(to: [visibleSamples[next]], viaKeyboard: true)
        }
        requestListFocus()
    }

    /// What the Space bar does. Plays the selected sample if it's listed. Otherwise it stops whatever is audible,
    /// or starts the first sample in the list.
    func togglePlaybackOfSelection() {
        if let sample = listedSelection {
            togglePlayback(of: sample)
        } else if player.isPlaying {
            toggleCurrentPlayback()
        } else if let sample = visibleSamples.first {
            togglePlayback(of: sample)
        } else if player.sample != nil {
            toggleCurrentPlayback()
        }
    }

    // MARK: - Filtering

    private func refreshVisibleSamples() {
        let searchTerms = searchText.split(whereSeparator: \.isWhitespace).map { SampleSearch.normalize(String($0)) }
        let matching = samples.filter { sample in
            switch (tab, sample.source) {
            case (.splice, .splice), (.folders, .folder): break
            default: return false
            }

            switch scope {
            case .all: break
            case .pack(let name): if sample.collection != name { return false }
            case .folder(let url): if sample.source != .folder(url) { return false }
            }
            return searchTerms.allSatisfy { sample.searchText.contains($0) }
        }

        // Each filter's counts take the other filter into account, so a number always matches what clicking it shows.
        categoryCounts = matching
            .filter { genre == nil || $0.genres.contains(genre!) }
            .reduce(into: [:]) { $0[$1.category, default: 0] += 1 }

        var genreTotals: [SampleGenre: Int] = [:]
        for sample in matching where category == nil || sample.category == category {
            for genre in sample.genres { genreTotals[genre, default: 0] += 1 }
        }
        genreCounts = genreTotals
            .map { (genre: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.genre.title < $1.genre.title }

        visibleSamples = matching
            .filter { (category == nil || $0.category == category) && (genre == nil || $0.genres.contains(genre!)) }
            .sorted(by: sort.areInOrder)
    }
}
