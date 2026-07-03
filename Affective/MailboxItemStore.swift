//
//  MailboxItemStore.swift
//  Affective
//

import Foundation
import SQLite3

nonisolated struct MailboxUIStateJournal: Codable, Equatable {
    var schemaVersion = 1
    var items: [MailboxUIState] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case items
    }

    static func load(from url: URL) -> MailboxUIStateJournal {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let journal = try? JSONDecoder.mailboxItems.decode(MailboxUIStateJournal.self, from: data)
        else {
            return MailboxUIStateJournal()
        }
        return journal
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder.mailboxItems.encode(self)
        try data.write(to: url, options: .atomic)
    }

    var stateByMailboxID: [String: MailboxUIState] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.mailboxID, $0) })
    }

    mutating func set(mailboxID: String, isRead: Bool? = nil, isArchived: Bool? = nil) {
        var current = stateByMailboxID[mailboxID] ?? MailboxUIState(mailboxID: mailboxID)
        if let isRead { current.isRead = isRead }
        if let isArchived { current.isArchived = isArchived }
        items.removeAll { $0.mailboxID == mailboxID }
        items.append(current)
    }
}

nonisolated struct MailboxUIState: Codable, Equatable {
    var mailboxID: String
    var isRead = false
    var isArchived = false

    enum CodingKeys: String, CodingKey {
        case mailboxID = "mailbox_id"
        case isRead = "is_read"
        case isArchived = "is_archived"
    }
}

nonisolated struct MailboxItem: Codable, Identifiable, Equatable {
    static let recentMailboxDeliveryInterval: TimeInterval = 24 * 60 * 60

    var id: String { mailboxID }

    var mailboxID: String
    var sourceDreamID: String
    var dayKey: String
    var createdAt: Date
    var summary: String
    var summarySource: String
    var bodyText: String
    var reflection: String
    var heat: Double?
    var style: String?
    var confidence: Double?
    var sourceEventIDs: [String]
    var artifactID: String?
    var imagePath: String?
    var imageMimeType: String?
    var imageSpec: String?
    var isRead: Bool
    var isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case mailboxID = "mailbox_id"
        case sourceDreamID = "source_dream_id"
        case dayKey = "day_key"
        case createdAt = "created_at"
        case summary
        case summarySource = "summary_source"
        case bodyText = "body_text"
        case reflection
        case heat
        case style
        case confidence
        case sourceEventIDs = "source_event_ids"
        case artifactID = "artifact_id"
        case imagePath = "image_path"
        case imageMimeType = "image_mime_type"
        case imageSpec = "image_spec"
        case isRead = "is_read"
        case isArchived = "is_archived"
    }
}

extension MailboxItem {
    nonisolated init(mailbox item: BrainMailboxItem, state: MailboxUIState?) {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(item.createdAtMS) / 1000)
        let sourceDreamID = item.sourceDreamID ?? item.mailboxID
        let imageSpec = item.imageSpecJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            mailboxID: item.mailboxID,
            sourceDreamID: sourceDreamID,
            dayKey: MailboxItemDateFormatter.dayKey(for: createdAt),
            createdAt: createdAt,
            summary: item.title.isEmpty ? item.text : item.title,
            summarySource: "affective_core_mailbox",
            bodyText: item.text,
            reflection: item.wakingThought.isEmpty ? item.visibleLesson : item.wakingThought,
            heat: nil,
            style: nil,
            confidence: nil,
            sourceEventIDs: item.sourceEventIDs,
            artifactID: item.imageArtifactID,
            imagePath: nil,
            imageMimeType: nil,
            imageSpec: imageSpec.isEmpty ? nil : imageSpec,
            isRead: state?.isRead ?? false,
            isArchived: state?.isArchived ?? false
        )
    }

    nonisolated func resolvingArtifact(in memoryDatabaseURL: URL, brainID: String) -> MailboxItem {
        guard imagePath == nil, let artifactID else { return self }
        guard let artifact = CognitiveArtifactResolver.artifact(id: artifactID, in: memoryDatabaseURL, brainID: brainID) else { return self }
        var resolved = self
        resolved.imagePath = artifact.path
        resolved.imageMimeType = artifact.mimeType
        return resolved
    }
}

nonisolated struct CognitiveArtifact: Decodable, Equatable {
    let artifactID: String
    let path: String
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case path
        case mimeType = "mime_type"
    }
}

nonisolated enum CognitiveArtifactResolver {
    static func artifact(id: String, in memoryDatabaseURL: URL?, brainID: String) -> CognitiveArtifact? {
        guard let memoryDatabaseURL else { return nil }
        _ = brainID
        guard let data = cognitiveData(at: memoryDatabaseURL) else { return nil }
        guard let file = try? JSONDecoder().decode(CognitiveArtifactFile.self, from: data) else { return nil }
        return file.artifacts.first { $0.artifactID == id }
    }

    private static func cognitiveData(at url: URL) -> Data? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return Data(String(cString: textPointer).utf8)
    }

    private struct CognitiveArtifactFile: Decodable {
        let artifacts: [CognitiveArtifact]
    }
}

nonisolated enum MailboxItemDateFormatter {
    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from text: String) -> Date? {
        iso.date(from: text) ?? isoWithoutFractionalSeconds.date(from: text)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

nonisolated struct BrainExperienceForgetResult: Equatable {
    var clearedMailboxUIStateCount: Int
    var backupURL: URL?

    var summary: String {
        "Cleared \(clearedMailboxUIStateCount) local mailbox UI state entries."
    }

    var metadata: [String: String] {
        var values = [
            "mailbox_ui_state_cleared": "\(clearedMailboxUIStateCount)",
        ]
        if let backupURL {
            values["backup_path"] = backupURL.path
        }
        return values
    }
}

nonisolated enum BrainExperienceForgetter {
    static func forgetToday(
        in brain: BrainDescriptor,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> BrainExperienceForgetResult {
        _ = calendar
        let backupURL = try BrainExperienceBackup.createBackup(
            for: brain,
            now: now,
            rootDirectory: brain.rootURL.appendingPathComponent(".forget_today_backups", isDirectory: true)
        )
        return BrainExperienceForgetResult(
            clearedMailboxUIStateCount: try clearMailboxUIState(at: brain.mailboxUIStateURL),
            backupURL: backupURL
        )
    }

    private static func clearMailboxUIState(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let journal = MailboxUIStateJournal.load(from: url)
        let cleared = journal.items.count
        if cleared > 0 {
            try MailboxUIStateJournal().write(to: url)
        }
        return cleared
    }
}

nonisolated enum BrainExperienceBackup {
    static func createBackup(
        for brain: BrainDescriptor,
        now: Date,
        rootDirectory: URL
    ) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        var backupRoot = rootDirectory.appendingPathComponent(stamp, isDirectory: true)
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            backupRoot = rootDirectory.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
        }
        let memoryBackup = backupRoot.appendingPathComponent("memory", isDirectory: true)

        try FileManager.default.createDirectory(at: memoryBackup, withIntermediateDirectories: true)
        try copyIfPresent(brain.mailboxUIStateURL, to: backupRoot.appendingPathComponent("mailbox_ui_state.json"))
        try copyIfPresent(brain.memoryDatabaseURL, to: memoryBackup.appendingPathComponent("people.sqlite"))
        try copyIfPresent(URL(fileURLWithPath: brain.memoryDatabaseURL.path + "-wal"), to: memoryBackup.appendingPathComponent("people.sqlite-wal"))
        try copyIfPresent(URL(fileURLWithPath: brain.memoryDatabaseURL.path + "-shm"), to: memoryBackup.appendingPathComponent("people.sqlite-shm"))
        return backupRoot
    }

    private static func copyIfPresent(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

extension JSONDecoder {
    nonisolated static var mailboxItems: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    nonisolated static var mailboxItems: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
