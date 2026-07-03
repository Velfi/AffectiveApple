//
//  BrainKnowledgeReader.swift
//  Affective
//

import Foundation
import SQLite3

nonisolated enum BrainKnowledgeReader {
    static func loadEntries(from brain: BrainDescriptor) throws -> [LogEntry] {
        guard let object = try readCognitiveObject(from: brain.memoryDatabaseURL) else {
            return []
        }

        var entries: [LogEntry] = []
        entries.append(contentsOf: memoryEntries(from: object))
        entries.append(contentsOf: experienceEventEntries(from: object))
        entries.append(contentsOf: dreamEntries(from: object))
        entries.append(contentsOf: appraisalEntries(from: object))
        entries.append(contentsOf: impressionEntries(from: object))
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    static func isKnowledgeRelated(_ entry: LogEntry) -> Bool {
        if entry.metadata["stream"] == "knowledge_store" {
            return true
        }
        if let eventType = entry.metadata["event_type"],
           knowledgeEventTypes.contains(eventType) {
            return true
        }
        let searchable = searchableText(for: entry)
        return knowledgeKeywords.contains { searchable.localizedCaseInsensitiveContains($0) }
    }

    static let knowledgeKeywords = ["memory", "reminder", "dream", "attention"]
    static let knowledgeEventTypes: Set<String> = [
        "memory_result",
        "memory_mutation",
        "attention_state",
        "thought",
        "appraisal",
        "need_state",
        "intention",
    ]

    static func searchableText(for entry: LogEntry) -> String {
        [
            entry.kind.rawValue,
            entry.title,
            entry.body,
            entry.metadata.map { "\($0.key):\($0.value)" }.joined(separator: " "),
        ].joined(separator: " ")
    }

    private static func memoryEntries(from object: [String: Any]) -> [LogEntry] {
        guard let memories = object["memories"] as? [[String: Any]] else { return [] }
        return memories.compactMap { memory in
            guard let memoryID = stringValue(memory["memory_id"]), !memoryID.isEmpty else { return nil }
            let status = stringValue(memory["status"]) ?? "active"
            guard status != "retracted", status != "contradicted" else { return nil }

            let text = stringValue(memory["text"]) ?? ""
            let interpretation = stringValue(memory["interpretation"]) ?? ""
            let body = mergedBody(primary: text, secondary: interpretation)
            guard !body.isEmpty else { return nil }

            let scope = stringValue(memory["scope"]) ?? "memory"
            var metadata: [String: String] = [
                "stream": "knowledge_store",
                "knowledge_source_id": "memory:\(memoryID)",
                "knowledge_category": "memory",
                "memory_id": memoryID,
                "scope": scope,
                "status": status,
            ]
            if let createdAt = stringValue(memory["created_at"]) {
                metadata["created_at"] = createdAt
            }
            if let lastAccessedAt = stringValue(memory["last_accessed_at"]) {
                metadata["last_accessed_at"] = lastAccessedAt
            }
            if let accessCount = memory["access_count"] {
                metadata["access_count"] = "\(accessCount)"
            }
            if let tags = stringArray(memory["tags"]), !tags.isEmpty {
                metadata["tags"] = tags.joined(separator: ", ")
            }

            return LogEntry(
                kind: .result,
                title: "\(scope.replacingOccurrences(of: "_", with: " ")) memory",
                body: body,
                metadata: metadata,
                createdAt: parsedDate(
                    unixSeconds: stringValue(memory["last_accessed_at"])
                        ?? stringValue(memory["created_at"])
                )
            )
        }
    }

    private static func experienceEventEntries(from object: [String: Any]) -> [LogEntry] {
        guard let events = object["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard let eventID = stringValue(event["id"]), !eventID.isEmpty else { return nil }
            let kind = stringValue(event["kind"]) ?? "experience"
            let payload = stringValue(event["payload"]) ?? ""
            let source = stringValue(event["source"]) ?? ""
            guard isKnowledgeExperience(kind: kind, payload: payload, source: source) else { return nil }

            let parsedPayload = parsePayload(payload)
            let title = parsedPayload.title ?? simplifiedKind(kind)
            let body = parsedPayload.body ?? payload
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            var metadata: [String: String] = [
                "stream": "knowledge_store",
                "knowledge_source_id": "event:\(eventID)",
                "knowledge_category": "experience",
                "event_id": eventID,
                "event_kind": kind,
                "source": source,
            ]
            if let timestampMS = int64Value(event["timestamp_ms"]) {
                metadata["timestamp_ms"] = "\(timestampMS)"
            }

            return LogEntry(
                kind: .state,
                title: title,
                body: body,
                metadata: metadata,
                createdAt: parsedDate(
                    unixMilliseconds: int64Value(event["timestamp_ms"]),
                    unixSeconds: parsedPayload.time ?? stringValue(event["timestamp_ms"])
                )
            )
        }
    }

    private static func dreamEntries(from object: [String: Any]) -> [LogEntry] {
        guard let dreams = object["dream_time_records"] as? [[String: Any]] else { return [] }
        return dreams.compactMap { dream in
            guard let dreamID = stringValue(dream["dream_id"]), !dreamID.isEmpty else { return nil }
            let title = stringValue(dream["title"]) ?? "dream"
            let text = stringValue(dream["text"]) ?? ""
            let wakingThought = stringValue(dream["waking_thought"]) ?? ""
            let body = mergedBody(primary: text, secondary: wakingThought)
            guard !body.isEmpty else { return nil }

            return LogEntry(
                kind: .result,
                title: title,
                body: body,
                metadata: [
                    "stream": "knowledge_store",
                    "knowledge_source_id": "dream:\(dreamID)",
                    "knowledge_category": "dream",
                    "dream_id": dreamID,
                ],
                createdAt: parsedDate(unixMilliseconds: int64Value(dream["created_at_ms"]))
            )
        }
    }

    private static func appraisalEntries(from object: [String: Any]) -> [LogEntry] {
        guard let appraisals = object["appraisals"] as? [[String: Any]] else { return [] }
        return appraisals.compactMap { appraisal in
            guard let appraisalID = stringValue(appraisal["appraisal_id"]), !appraisalID.isEmpty else { return nil }
            let query = stringValue(appraisal["query"]) ?? ""
            let feeling = stringValue(appraisal["feeling_label"]) ?? ""
            let expression = stringValue(appraisal["expression"]) ?? ""
            let body = [query, feeling, expression]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !body.isEmpty else { return nil }

            return LogEntry(
                kind: .state,
                title: "appraisal",
                body: body,
                metadata: [
                    "stream": "knowledge_store",
                    "knowledge_source_id": "appraisal:\(appraisalID)",
                    "knowledge_category": "attention",
                    "appraisal_id": appraisalID,
                ],
                createdAt: parsedDate(unixSeconds: stringValue(appraisal["created_at"]))
            )
        }
    }

    private static func impressionEntries(from object: [String: Any]) -> [LogEntry] {
        guard let impressions = object["impressions"] as? [[String: Any]] else { return [] }
        return impressions.compactMap { impression in
            guard let impressionID = stringValue(impression["impression_id"]), !impressionID.isEmpty else { return nil }
            let text = stringValue(impression["text"]) ?? ""
            guard !text.isEmpty else { return nil }

            var metadata: [String: String] = [
                "stream": "knowledge_store",
                "knowledge_source_id": "impression:\(impressionID)",
                "knowledge_category": "memory",
                "impression_id": impressionID,
            ]
            if let source = stringValue(impression["source"]) {
                metadata["source"] = source
            }
            if let tags = stringArray(impression["tags"]), !tags.isEmpty {
                metadata["tags"] = tags.joined(separator: ", ")
            }

            return LogEntry(
                kind: .state,
                title: "impression",
                body: text,
                metadata: metadata,
                createdAt: parsedDate(unixSeconds: stringValue(impression["created_at"]))
            )
        }
    }

    private static func isKnowledgeExperience(kind: String, payload: String, source: String) -> Bool {
        let haystack = "\(kind) \(payload) \(source)".lowercased()
        return knowledgeKeywords.contains { haystack.contains($0) }
    }

    private static func simplifiedKind(_ kind: String) -> String {
        kind.split(separator: ".").last.map(String.init) ?? kind
    }

    private static func mergedBody(primary: String, secondary: String) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondary = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrimary.isEmpty { return trimmedSecondary }
        if trimmedSecondary.isEmpty || trimmedPrimary.caseInsensitiveCompare(trimmedSecondary) == .orderedSame {
            return trimmedPrimary
        }
        return "\(trimmedPrimary)\n\(trimmedSecondary)"
    }

    private static func parsePayload(_ payload: String) -> (title: String?, body: String?, time: String?) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil, nil) }
        if trimmed.first == "{" || trimmed.first == "[" {
            guard
                let data = trimmed.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return (nil, trimmed, nil)
            }
            let title = stringValue(object["title"])
                ?? stringValue(object["developer_log_title"])
                ?? stringValue(object["kind"])
            let body = stringValue(object["body"])
                ?? stringValue(object["developer_log_body"])
                ?? stringValue(object["text"])
                ?? stringValue(object["interpretation"])
                ?? stringValue(object["raw"])
            return (title, body ?? trimmed, stringValue(object["time"]))
        }
        return (nil, trimmed, nil)
    }

    private static func readCognitiveObject(from databaseURL: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            if let database {
                let detail = sqliteDiagnostic(database: database, operation: "open memory database", code: openCode, fileURL: databaseURL)
                sqlite3_close(database)
                throw BrainKnowledgeReaderError.sqlite(detail)
            }
            throw BrainKnowledgeReaderError.sqlite(
                "open memory database failed (SQLite \(openCode)) at \(databaseURL.path) (\(fileSummary(for: databaseURL)))"
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(
            database,
            "SELECT data_json FROM cognitive_memory WHERE id = 1",
            -1,
            &statement,
            nil
        )
        guard prepareCode == SQLITE_OK else {
            throw BrainKnowledgeReaderError.sqlite(
                sqliteDiagnostic(database: database, operation: "prepare cognitive_memory query", code: prepareCode, fileURL: databaseURL)
            )
        }
        defer { sqlite3_finalize(statement) }

        let stepCode = sqlite3_step(statement)
        switch stepCode {
        case SQLITE_ROW:
            break
        case SQLITE_DONE:
            return nil
        default:
            throw BrainKnowledgeReaderError.sqlite(
                sqliteDiagnostic(database: database, operation: "read cognitive_memory row", code: stepCode, fileURL: databaseURL)
            )
        }

        guard let textPointer = sqlite3_column_text(statement, 0) else {
            throw BrainKnowledgeReaderError.invalidData(
                "cognitive_memory row id=1 has no data_json column at \(databaseURL.path) (\(fileSummary(for: databaseURL)))"
            )
        }

        let jsonText = String(cString: textPointer)
        let data = Data(jsonText.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BrainKnowledgeReaderError.invalidData(
                "cognitive memory JSON is invalid at \(databaseURL.path) (\(data.count) bytes): \(error.localizedDescription)"
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw BrainKnowledgeReaderError.invalidData(
                "cognitive memory must be a JSON object at \(databaseURL.path), got \(String(describing: type(of: object)))"
            )
        }
        return dictionary
    }

    private static func sqliteDiagnostic(
        database: OpaquePointer?,
        operation: String,
        code: Int32,
        fileURL: URL
    ) -> String {
        let label = sqliteResultLabel(code)
        let path = fileURL.path
        let fileInfo = fileSummary(for: fileURL)
        if let database, let message = sqliteErrorMessage(database), !message.isEmpty {
            return "\(operation) failed for \(path) (\(fileInfo)): \(label) (SQLite \(code)) — \(message)"
        }
        return "\(operation) failed for \(path) (\(fileInfo)): \(label) (SQLite \(code))"
    }

    private static func sqliteErrorMessage(_ database: OpaquePointer) -> String? {
        guard let cString = sqlite3_errmsg(database) else { return nil }
        let message = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private static func sqliteResultLabel(_ code: Int32) -> String {
        switch code {
        case SQLITE_BUSY:
            return "database busy (another process may be writing memory)"
        case SQLITE_LOCKED:
            return "database locked"
        case SQLITE_CORRUPT:
            return "database corrupt"
        case SQLITE_NOTADB:
            return "file is not a SQLite database"
        case SQLITE_IOERR:
            return "database I/O error"
        case SQLITE_CANTOPEN:
            return "cannot open database file"
        case SQLITE_PERM:
            return "database access denied"
        case SQLITE_NOMEM:
            return "out of memory while reading database"
        case SQLITE_READONLY:
            return "database is read-only"
        case SQLITE_ERROR:
            return "SQL error"
        default:
            return "SQLite error"
        }
    }

    private static func fileSummary(for url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "size unknown"
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let walPath = url.path + "-wal"
        let walSuffix = FileManager.default.fileExists(atPath: walPath) ? ", WAL present" : ""
        return "size \(size) bytes\(walSuffix)"
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let strings = array.compactMap { stringValue($0) }
        return strings.isEmpty ? nil : strings
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private static func parsedDate(unixMilliseconds: Int64? = nil, unixSeconds: String? = nil) -> Date {
        if let unixMilliseconds {
            return Date(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000)
        }
        if let unixSeconds, let seconds = Double(unixSeconds) {
            if seconds > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: seconds / 1000)
            }
            return Date(timeIntervalSince1970: seconds)
        }
        return Date.distantPast
    }
}

enum BrainKnowledgeReaderError: LocalizedError {
    case sqlite(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message), .invalidData(let message):
            return message
        }
    }
}
