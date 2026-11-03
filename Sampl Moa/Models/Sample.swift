import Foundation

nonisolated enum SampleSource: Hashable, Sendable {
    case splice
    case folder(URL)
}

/// Whether a sample's contents are on this Mac, or only in iCloud Drive or another cloud folder.
nonisolated enum SampleAvailability: Hashable, Sendable {
    case onThisMac, inCloud, downloading
}

nonisolated struct Sample: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    /// The Splice pack it came from, or the folder it sits in.
    let collection: String
    let source: SampleSource
    let category: SampleCategory
    let genres: [SampleGenre]
    let addedAt: Date
    /// Normalized text that the search box looks through.
    let searchText: String
    var availability: SampleAvailability
    var duration: TimeInterval?

    var id: URL { url }
}

struct SamplePack: Identifiable, Hashable {
    let name: String
    let sampleCount: Int

    var id: String { name }
}

struct SampleFolder: Identifiable, Hashable {
    let url: URL
    let sampleCount: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum LibraryTab: Hashable {
    case splice, folders
}

enum LibraryScope: Hashable {
    case all
    case pack(String)
    case folder(URL)
}

enum SampleColumn: String, CaseIterable {
    case play, name, collection, category, genre, length, added

    var title: String {
        switch self {
        case .play: ""
        case .name: String(localized: "Name")
        case .collection: String(localized: "Pack")
        case .category: String(localized: "Type")
        case .genre: String(localized: "Genre")
        case .length: String(localized: "Length")
        case .added: String(localized: "Date Added")
        }
    }
}

struct SampleSort: Equatable {
    var column = SampleColumn.added
    var ascending = false

    func areInOrder(_ lhs: Sample, _ rhs: Sample) -> Bool {
        let result: ComparisonResult = switch column {
        case .play, .name: .orderedSame
        case .collection: lhs.collection.localizedStandardCompare(rhs.collection)
        case .category: lhs.category.title.localizedStandardCompare(rhs.category.title)
        case .genre: (lhs.genres.first?.title ?? "").localizedStandardCompare(rhs.genres.first?.title ?? "")
        case .length: Self.compare(lhs.duration ?? -1, rhs.duration ?? -1)
        case .added: Self.compare(lhs.addedAt, rhs.addedAt)
        }
        if result != .orderedSame {
            return result == (ascending ? .orderedAscending : .orderedDescending)
        }

        // Keeps equal rows from swapping places whenever the list refreshes.
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame {
            return byName == (ascending || column != .name ? .orderedAscending : .orderedDescending)
        }
        return lhs.url.path < rhs.url.path
    }

    private static func compare<Value: Comparable>(_ lhs: Value, _ rhs: Value) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}

/// Formats a length as `0:03`, rounding up so a short one-shot never reads `0:00`.
func formattedLength(_ duration: TimeInterval) -> String {
    let seconds = Int(duration.rounded(.up))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
