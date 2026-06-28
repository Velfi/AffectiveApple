//
//  BrainStatsJournal.swift
//  Affective
//

import Foundation

struct BrainStatsJournal: Codable, Equatable {
    var schemaVersion = 1
    var sizeSnapshots: [BrainSizeSnapshot] = []
    var notes: [BrainTimestampedNote] = []
    var profileSnapshots: [BrainProfileSnapshot] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sizeSnapshots = "size_snapshots"
        case notes
        case profileSnapshots = "profile_snapshots"
    }

    var latestSizeSnapshot: BrainSizeSnapshot? {
        sizeSnapshots.sorted { $0.createdAt < $1.createdAt }.last
    }

    var sortedNotes: [BrainTimestampedNote] {
        notes.sorted { $0.createdAt > $1.createdAt }
    }

    var sortedProfileSnapshots: [BrainProfileSnapshot] {
        profileSnapshots.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    mutating func recordSize(_ bytes: Int64, at date: Date = Date(), force: Bool = false) -> Bool {
        if let latestSizeSnapshot, Calendar.current.isDate(latestSizeSnapshot.createdAt, inSameDayAs: date) {
            guard force else { return false }
            let updated = BrainSizeSnapshot(createdAt: date, bytes: bytes)
            if let index = sizeSnapshots.firstIndex(where: { $0.id == latestSizeSnapshot.id }) {
                sizeSnapshots[index] = updated
            }
            return true
        }
        sizeSnapshots.append(.init(createdAt: date, bytes: bytes))
        return true
    }

    mutating func addNote(_ body: String, at date: Date = Date()) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(.init(createdAt: date, body: trimmed))
    }

    mutating func addProfileSnapshot(traits: String, goals: String, recentMemories: String, at date: Date = Date()) {
        let snapshot = BrainProfileSnapshot(
            createdAt: date,
            traits: traits.trimmingCharacters(in: .whitespacesAndNewlines),
            goals: goals.trimmingCharacters(in: .whitespacesAndNewlines),
            recentMemories: recentMemories.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !snapshot.traits.isEmpty || !snapshot.goals.isEmpty || !snapshot.recentMemories.isEmpty else { return }
        profileSnapshots.append(snapshot)
    }

    func sizeChange(since interval: DateComponents, now: Date = Date()) -> BrainSizeChange? {
        guard let latest = latestSizeSnapshot else { return nil }
        guard let startDate = Calendar.current.date(byAdding: interval, to: now) else { return nil }
        let ordered = sizeSnapshots.sorted { $0.createdAt < $1.createdAt }
        let baseline = ordered.last { $0.createdAt <= startDate } ?? ordered.first
        guard let baseline else { return nil }
        return BrainSizeChange(
            baselineBytes: baseline.bytes,
            latestBytes: latest.bytes,
            baselineDate: baseline.createdAt,
            latestDate: latest.createdAt
        )
    }

    static func load(from url: URL) throws -> BrainStatsJournal {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BrainStatsJournal()
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return BrainStatsJournal() }
        let journal = try JSONDecoder.brainStats.decode(BrainStatsJournal.self, from: data)
        return journal
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder.brainStats.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

struct BrainSizeSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt: Date
    var bytes: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case bytes
    }
}

struct BrainTimestampedNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt: Date
    var body: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case body
    }
}

struct BrainProfileSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt: Date
    var traits: String
    var goals: String
    var recentMemories: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case traits
        case goals
        case recentMemories = "recent_memories"
    }
}

struct BrainSizeChange: Equatable {
    let baselineBytes: Int64
    let latestBytes: Int64
    let baselineDate: Date
    let latestDate: Date

    var deltaBytes: Int64 {
        latestBytes - baselineBytes
    }
}

enum BrainStatsFormatter {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func signedBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "No change" }
        let sign = bytes > 0 ? "+" : "-"
        return "\(sign)\(Self.bytes(abs(bytes)))"
    }
}

extension JSONDecoder {
    static var brainStats: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var brainStats: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension FileManager {
    nonisolated func approximateDirectorySize(at rootURL: URL, maximumFiles: Int = 400) -> Int64 {
        guard let enumerator = enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }

        var total: Int64 = 0
        var fileCount = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == "brain_stats.json" { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
            fileCount += 1
            if fileCount >= maximumFiles { break }
        }
        return total
    }
}
