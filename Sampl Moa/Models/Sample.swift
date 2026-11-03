import Foundation

/// The folder Splice keeps for one account, such as `~/Splice` or `~/Splice - user-0000000000`.
nonisolated struct SpliceAccount: Identifiable, Hashable, Sendable {
    let folder: URL

    var id: URL { folder }

    var name: String {
        let folderName = folder.lastPathComponent
        return folderName.hasPrefix(SpliceFolders.accountFolderPrefix)
            ? String(folderName.dropFirst("Splice - ".count))
            : folderName
    }
}

nonisolated struct Sample: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let pack: String
    let accountID: SpliceAccount.ID
    let accountName: String
    let format: String
    let fileSize: Int64
    var duration: TimeInterval?

    var id: URL { url }
}

enum SampleColumn: String, CaseIterable {
    case name, pack, account, duration, format, size

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .pack: String(localized: "Pack")
        case .account: String(localized: "Account")
        case .duration: String(localized: "Length")
        case .format: String(localized: "Format")
        case .size: String(localized: "Size")
        }
    }
}

struct SampleSort: Equatable {
    var column = SampleColumn.name
    var ascending = true

    func areInOrder(_ lhs: Sample, _ rhs: Sample) -> Bool {
        let result: ComparisonResult = switch column {
        case .name: lhs.name.localizedStandardCompare(rhs.name)
        case .pack: lhs.pack.localizedStandardCompare(rhs.pack)
        case .account: lhs.accountName.localizedStandardCompare(rhs.accountName)
        case .duration: Self.compare(lhs.duration ?? -1, rhs.duration ?? -1)
        case .format: lhs.format.compare(rhs.format)
        case .size: Self.compare(lhs.fileSize, rhs.fileSize)
        }
        // Keeps equal rows from swapping places whenever the list refreshes.
        if result == .orderedSame { return lhs.url.path < rhs.url.path }
        return result == (ascending ? .orderedAscending : .orderedDescending)
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}
