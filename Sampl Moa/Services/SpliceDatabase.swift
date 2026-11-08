import Foundation
import SQLite3

/// What Splice knows about a downloaded sample.
nonisolated struct SpliceSampleInfo: Sendable {
    let tags: [String]
    let packGenre: String?
    let isLoop: Bool
    /// 0 when Splice doesn't give one, as for one-shots.
    var bpm = 0
}

/// Reads the sample details Splice keeps in its own database, one per account. This is Splice's private format and
/// could change without notice, so everything here is optional: without it, genres are guessed from names instead.
nonisolated enum SpliceDatabase {
    /// Holds one folder per account, each with its database.
    static func accountsFolder(home: URL) -> URL {
        home.appending(path: "Library/Application Support/com.splice.Splice/users/default")
    }

    /// Returns details keyed by lowercased file name.
    static func loadSampleInfo(home: URL) -> [String: SpliceSampleInfo] {
        let accounts = (try? FileManager.default.contentsOfDirectory(at: accountsFolder(home: home), includingPropertiesForKeys: nil)) ?? []

        var info: [String: SpliceSampleInfo] = [:]
        for account in accounts {
            info.merge(readCopy(of: account.appending(path: "sounds.db"))) { current, _ in current }
        }
        return info
    }

    /// Works on a copy so the app never holds a lock on a file Splice may be writing to.
    private static func readCopy(of database: URL) -> [String: SpliceSampleInfo] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: database.path) else { return [:] }

        let directory = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fileManager.removeItem(at: directory) }
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return [:]
        }

        // Read and written rather than `copyItem`, which clones the file. The system reports a clone as a change to the
        // folder it came from, and since that folder is being watched, every scan would call for another one.
        let copy = directory.appending(path: "sounds.db")
        guard let contents = try? Data(contentsOf: database), (try? contents.write(to: copy)) != nil else { return [:] }
        // Recent changes may still be in the write-ahead log.
        if let log = try? Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")) {
            try? log.write(to: URL(fileURLWithPath: copy.path + "-wal"))
        }

        return read(copy)
    }

    private static func read(_ database: URL) -> [String: SpliceSampleInfo] {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { return [:] }

        // A database without tempos still has everything else, so it's asked again without them.
        let withTempo = """
            SELECT s.filename, s.local_path, s.tags, s.sample_type, p.genre, s.bpm
            FROM samples s LEFT JOIN packs p ON p.uuid = s.pack_uuid
            """
        let withoutTempo = """
            SELECT s.filename, s.local_path, s.tags, s.sample_type, p.genre
            FROM samples s LEFT JOIN packs p ON p.uuid = s.pack_uuid
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var hasTempo = true
        if sqlite3_prepare_v2(connection, withTempo, -1, &statement, nil) != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            hasTempo = false
            guard sqlite3_prepare_v2(connection, withoutTempo, -1, &statement, nil) == SQLITE_OK else { return [:] }
        }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        var info: [String: SpliceSampleInfo] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = text(1).flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
            guard let fileName = path ?? text(0) else { continue }

            info[fileName.lowercased()] = SpliceSampleInfo(
                tags: (text(2) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() },
                packGenre: text(4)?.lowercased(),
                isLoop: text(3) == "loop",
                bpm: hasTempo ? Int(sqlite3_column_int(statement, 5)) : 0
            )
        }
        return info
    }
}
