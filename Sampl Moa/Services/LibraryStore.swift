import Foundation
import Observation

enum LibraryScope: Hashable {
    case all
    case account(SpliceAccount.ID)
}

@Observable
final class LibraryStore {
    private(set) var hasAccess = false
    private(set) var accessProblem: String?
    private(set) var isScanning = false
    private(set) var accounts: [SpliceAccount] = []
    private(set) var visibleSamples: [Sample] = []

    var scope = LibraryScope.all {
        didSet { refreshVisibleSamples() }
    }
    var searchText = "" {
        didSet { refreshVisibleSamples() }
    }
    var sort = SampleSort() {
        didSet { refreshVisibleSamples() }
    }

    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var knownDurations: [URL: TimeInterval] = [:]
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let folderAccess = FolderAccess()

    init() {
        if let url = folderAccess.restore() {
            root = url
            hasAccess = true
            rescan()
        }
    }

    var totalSampleCount: Int { samples.count }

    func sampleCount(in account: SpliceAccount) -> Int {
        samples.lazy.filter { $0.accountID == account.id }.count
    }

    func chooseFolder() async {
        guard let url = await folderAccess.chooseFolder() else { return }

        let isUserHome = url.standardizedFileURL.path == FolderAccess.userHome.standardizedFileURL.path
        guard isUserHome || !SpliceFolders.locate(in: url).isEmpty else {
            accessProblem = String(localized: "“\(url.lastPathComponent)” doesn’t contain a Splice folder. Please choose your user folder.")
            return
        }

        do {
            try folderAccess.save(url)
        } catch {
            accessProblem = String(localized: "The folder permission couldn’t be saved. Please try again.")
            return
        }

        folderAccess.replaceScopedURL(with: url)
        accessProblem = nil
        root = url
        hasAccess = true
        rescan()
    }

    func rescan() {
        guard let root else { return }

        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            let result = await SampleScanner.scan(root: root)
            guard !Task.isCancelled else { return }

            accounts = result.accounts
            samples = result.samples.map { sample in
                var sample = sample
                sample.duration = knownDurations[sample.url]
                return sample
            }
            if case .account(let id) = scope, !accounts.contains(where: { $0.id == id }) {
                scope = .all
            }
            refreshVisibleSamples()
            isScanning = false

            await loadMissingDurations()
        }
    }

    /// Lengths come from each file's header, so they fill in after the list is already on screen.
    private func loadMissingDurations() async {
        let pending = samples.indices.filter { samples[$0].duration == nil }
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

    private func refreshVisibleSamples() {
        let searchTerms = searchText.split(whereSeparator: \.isWhitespace)
        visibleSamples = samples
            .filter { sample in
                if case .account(let id) = scope, sample.accountID != id { return false }
                return searchTerms.allSatisfy { term in
                    sample.name.localizedCaseInsensitiveContains(term)
                        || sample.pack.localizedCaseInsensitiveContains(term)
                }
            }
            .sorted(by: sort.areInOrder)
    }
}
