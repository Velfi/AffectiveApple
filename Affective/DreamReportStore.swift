//
//  DreamReportStore.swift
//  Affective
//

import Foundation
import SQLite3

nonisolated struct DreamReportJournal: Codable, Equatable {
    var schemaVersion = 1
    var reports: [DreamReport] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reports
    }

    var sortedReports: [DreamReport] {
        reports.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.dreamID.localizedCaseInsensitiveCompare($1.dreamID) == .orderedAscending
        }
    }

    static func load(from url: URL) -> DreamReportJournal {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let journal = try? JSONDecoder.dreamReports.decode(DreamReportJournal.self, from: data)
        else {
            return DreamReportJournal()
        }
        return journal
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder.dreamReports.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

nonisolated struct DreamReport: Codable, Identifiable, Equatable {
    var id: String { reportID }

    var reportID: String
    var dreamID: String
    var dayKey: String
    var createdAt: Date
    var summary: String
    var summarySource: String
    var fullReportText: String
    var reflection: String
    var heat: Double?
    var style: String?
    var confidence: Double?
    var sourceTraceIDs: [String]
    var generatedArtifactID: String?
    var imagePath: String?
    var imageMimeType: String?
    var imagePrompt: String?
    var isRead: Bool
    var isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case dreamID = "dream_id"
        case dayKey = "day_key"
        case createdAt = "created_at"
        case summary
        case summarySource = "summary_source"
        case fullReportText = "full_report_text"
        case reflection
        case heat
        case style
        case confidence
        case sourceTraceIDs = "source_trace_ids"
        case generatedArtifactID = "generated_artifact_id"
        case imagePath = "image_path"
        case imageMimeType = "image_mime_type"
        case imagePrompt = "image_prompt"
        case isRead = "is_read"
        case isArchived = "is_archived"
    }
}

nonisolated struct DreamReportDraft: Equatable {
    var dreamID: String
    var dayKey: String
    var createdAt: Date
    var reflection: String
    var heat: Double?
    var style: String?
    var confidence: Double?
    var sourceTraceIDs: [String]
    var generatedArtifactID: String?
    var imagePath: String?
    var imageMimeType: String?
    var imagePrompt: String?
}

nonisolated struct DreamReportSummaryResult: Equatable {
    var text: String
    var source: String
}

nonisolated protocol DreamReportSummaryProviding {
    func summarize(_ draft: DreamReportDraft) async throws -> DreamReportSummaryResult
}

nonisolated struct DreamReportProviderSummarizer: DreamReportSummaryProviding {
    let credentialStore: KeychainCredentialStore
    let session: URLSession

    init(
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.session = session
    }

    func summarize(_ draft: DreamReportDraft) async throws -> DreamReportSummaryResult {
        let credentials = try providerCredentials()
        if let credential = credentials[.openAI] {
            return try await summarizeWithOpenAI(draft, credential: credential)
        }
        if let credential = credentials[.anthropic] {
            return try await summarizeWithAnthropic(draft, credential: credential)
        }
        if let credential = credentials[.google] {
            return try await summarizeWithGoogle(draft, credential: credential)
        }
        throw DreamReportSummaryError.missingProviderCredential
    }

    private func providerCredentials() throws -> [ProviderCredentialKey: String] {
        var credentials: [ProviderCredentialKey: String] = [:]
        for key in ProviderCredentialKey.allCases {
            let value = try credentialStore.credential(for: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                credentials[key] = value
            }
        }
        return credentials
    }

    private func summarizeWithOpenAI(_ draft: DreamReportDraft, credential: String) async throws -> DreamReportSummaryResult {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "model": "gpt-4.1-nano",
            "input": summaryPrompt(for: draft),
            "max_output_tokens": 120,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await jsonObject(for: request)
        if let text = object["output_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(text: cleanSummary(text), source: "openai")
        }
        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return .init(text: cleanSummary(text), source: "openai")
                    }
                }
            }
        }
        throw DreamReportSummaryError.invalidProviderResponse
    }

    private func summarizeWithAnthropic(_ draft: DreamReportDraft, credential: String) async throws -> DreamReportSummaryResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(credential, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 120,
            "messages": [
                ["role": "user", "content": summaryPrompt(for: draft)]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await jsonObject(for: request)
        guard let content = object["content"] as? [[String: Any]] else {
            throw DreamReportSummaryError.invalidProviderResponse
        }
        for part in content {
            if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .init(text: cleanSummary(text), source: "anthropic")
            }
        }
        throw DreamReportSummaryError.invalidProviderResponse
    }

    private func summarizeWithGoogle(_ draft: DreamReportDraft, credential: String) async throws -> DreamReportSummaryResult {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: credential)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": summaryPrompt(for: draft)]
                    ],
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await jsonObject(for: request)
        guard let candidates = object["candidates"] as? [[String: Any]] else {
            throw DreamReportSummaryError.invalidProviderResponse
        }
        for candidate in candidates {
            guard
                let content = candidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else { continue }
            for part in parts {
                if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .init(text: cleanSummary(text), source: "google")
                }
            }
        }
        throw DreamReportSummaryError.invalidProviderResponse
    }

    private func jsonObject(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw DreamReportSummaryError.providerRejected
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DreamReportSummaryError.invalidProviderResponse
        }
        return object
    }

    private func summaryPrompt(for draft: DreamReportDraft) -> String {
        """
        Summarize this private UI-side dream report for a player mailbox. Do not address the brain or imply the brain knows about this report. Use one concise sentence, 35 words or fewer.

        Dream ID: \(draft.dreamID)
        Reflection: \(draft.reflection)
        Heat: \(draft.heat.map { String(format: "%.3f", $0) } ?? "unknown")
        Style: \(draft.style ?? "unknown")
        Confidence: \(draft.confidence.map { String(format: "%.3f", $0) } ?? "unknown")
        Source trace count: \(draft.sourceTraceIDs.count)
        Image prompt: \(draft.imagePrompt ?? "unknown")
        """
    }

    private func cleanSummary(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

nonisolated enum DreamReportSummaryError: Error {
    case missingProviderCredential
    case providerRejected
    case invalidProviderResponse
}

nonisolated enum DreamReportCollector {
    static let recentDreamInterval: TimeInterval = 24 * 60 * 60

    static func collect(
        brain: BrainDescriptor,
        existing journal: DreamReportJournal,
        summaryProvider: DreamReportSummaryProviding = DreamReportProviderSummarizer(),
        calendar: Calendar = .current
    ) async throws -> DreamReportJournal {
        let drafts = try loadDrafts(brain: brain, calendar: calendar)
        var updated = journal
        var existingKeys = Set(updated.reports.map { reportKey(dayKey: $0.dayKey, dreamID: $0.dreamID) })
        var didAddReport = false

        for draft in drafts {
            let key = reportKey(dayKey: draft.dayKey, dreamID: draft.dreamID)
            guard !existingKeys.contains(key) else { continue }
            let summary: DreamReportSummaryResult
            do {
                summary = try await summaryProvider.summarize(draft)
            } catch {
                summary = fallbackSummary(for: draft)
            }
            updated.reports.append(report(from: draft, summary: summary))
            existingKeys.insert(key)
            didAddReport = true
        }

        if didAddReport {
            try updated.write(to: brain.dreamReportsURL)
        }
        _ = try BrainCognitiveCompactor.compactAfterDailyDream(in: brain, now: Date(), calendar: calendar)
        return updated
    }

    static func shouldEnterDreamOnLoad(
        brain: BrainDescriptor,
        journal: DreamReportJournal,
        now: Date = Date()
    ) -> Bool {
        guard let latestDreamDate = latestDreamDate(brain: brain, journal: journal) else {
            return true
        }
        return now.timeIntervalSince(latestDreamDate) >= recentDreamInterval
    }

    static func latestDreamDate(brain: BrainDescriptor, journal: DreamReportJournal) -> Date? {
        let reportDate = journal.reports.map(\.createdAt).max()
        let draftDate = (try? loadDrafts(brain: brain).map(\.createdAt).max()) ?? nil

        switch (reportDate, draftDate) {
        case let (reportDate?, draftDate?):
            return max(reportDate, draftDate)
        case let (reportDate?, nil):
            return reportDate
        case let (nil, draftDate?):
            return draftDate
        case (nil, nil):
            return nil
        }
    }

    static func loadDrafts(brain: BrainDescriptor, calendar: Calendar = .current) throws -> [DreamReportDraft] {
        guard let cognitive = try CognitiveStoreReader.loadCognitiveFile(from: brain.memoryDatabaseURL) else {
            return []
        }
        let prompts = try DreamEventReader.loadDreamImageEvents(from: brain.eventsURL)
        let artifactsByID = Dictionary(uniqueKeysWithValues: cognitive.artifacts.map { ($0.artifactID, $0) })
        return cognitive.dreams.compactMap { dream -> DreamReportDraft? in
            guard let createdAt = DreamReportDateFormatter.date(from: dream.createdAt) else { return nil }
            let artifact = dream.generatedArtifactID.flatMap { artifactsByID[$0] }
            let prompt = artifact.flatMap { prompts[$0.path] }
            return DreamReportDraft(
                dreamID: dream.dreamID,
                dayKey: DreamReportDateFormatter.dayKey(for: createdAt, calendar: calendar),
                createdAt: createdAt,
                reflection: dream.reflection,
                heat: dream.heat,
                style: style(forHeat: dream.heat),
                confidence: confidence(forHeat: dream.heat),
                sourceTraceIDs: dream.selectedTraceIDs,
                generatedArtifactID: dream.generatedArtifactID,
                imagePath: artifact?.path,
                imageMimeType: artifact?.mimeType,
                imagePrompt: prompt?.prompt
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    static func fallbackSummary(for draft: DreamReportDraft) -> DreamReportSummaryResult {
        let reflection = draft.reflection.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = reflection.isEmpty ? "A dream report was recorded" : reflection
        let heat = draft.heat.map { String(format: "%.2f", $0) } ?? "unknown heat"
        let sourceText = "\(draft.sourceTraceIDs.count) source \(draft.sourceTraceIDs.count == 1 ? "trace" : "traces")"
        var text = "\(lead) with \(heat) heat and \(sourceText)."
        if let prompt = draft.imagePrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            text += " Image seed: \(prompt)"
        }
        return .init(text: String(text.prefix(260)), source: "fallback")
    }

    static func fullReportText(for draft: DreamReportDraft) -> String {
        [
            "Dream ID: \(draft.dreamID)",
            "Created: \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "Reflection: \(draft.reflection)",
            "Heat: \(draft.heat.map { String(format: "%.3f", $0) } ?? "unknown")",
            "Style: \(draft.style ?? "unknown")",
            "Confidence: \(draft.confidence.map { String(format: "%.3f", $0) } ?? "unknown")",
            "Source trace IDs: \(draft.sourceTraceIDs.isEmpty ? "none" : draft.sourceTraceIDs.joined(separator: ", "))",
            "Image prompt: \(draft.imagePrompt ?? "unknown")",
            "Image path: \(draft.imagePath ?? "unknown")",
            "Image MIME type: \(draft.imageMimeType ?? "unknown")",
        ].joined(separator: "\n")
    }

    static func report(from draft: DreamReportDraft, summary: DreamReportSummaryResult) -> DreamReport {
        DreamReport(
            reportID: reportKey(dayKey: draft.dayKey, dreamID: draft.dreamID),
            dreamID: draft.dreamID,
            dayKey: draft.dayKey,
            createdAt: draft.createdAt,
            summary: summary.text,
            summarySource: summary.source,
            fullReportText: fullReportText(for: draft),
            reflection: draft.reflection,
            heat: draft.heat,
            style: draft.style,
            confidence: draft.confidence,
            sourceTraceIDs: draft.sourceTraceIDs,
            generatedArtifactID: draft.generatedArtifactID,
            imagePath: draft.imagePath,
            imageMimeType: draft.imageMimeType,
            imagePrompt: draft.imagePrompt,
            isRead: false,
            isArchived: false
        )
    }

    static func reportKey(dayKey: String, dreamID: String) -> String {
        "\(dayKey)-\(dreamID)"
    }

    static func style(forHeat heat: Double) -> String {
        if heat < 0.34 { return "grounded_replay" }
        if heat < 0.67 { return "associative_synthesis" }
        return "surreal_symbolic"
    }

    static func confidence(forHeat heat: Double) -> Double {
        max(0.20, 0.85 - heat * 0.55)
    }
}

nonisolated enum DreamReportDateFormatter {
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
    var removedEventCount: Int
    var removedCognitiveItemCount: Int
    var markedCognitiveItemCount: Int
    var removedDreamReportCount: Int
    var backupURL: URL?

    var summary: String {
        "Removed \(removedEventCount) event log entries, \(removedCognitiveItemCount) cognitive memory items, marked \(markedCognitiveItemCount) older orphaned items for deletion, and removed \(removedDreamReportCount) dream reports from today."
    }

    var metadata: [String: String] {
        var values = [
            "events_removed": "\(removedEventCount)",
            "cognitive_items_removed": "\(removedCognitiveItemCount)",
            "cognitive_items_marked": "\(markedCognitiveItemCount)",
            "dream_reports_removed": "\(removedDreamReportCount)",
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
        let interval = dayInterval(containing: now, calendar: calendar)
        let backupURL = try BrainExperienceBackup.createBackup(
            for: brain,
            now: now,
            rootDirectory: brain.rootURL.appendingPathComponent(".forget_today_backups", isDirectory: true)
        )
        let cognitiveResult = try BrainCognitiveCompactor.forgetToday(in: brain, interval: interval, now: now)
        return BrainExperienceForgetResult(
            removedEventCount: try pruneEvents(at: brain.eventsURL, interval: interval),
            removedCognitiveItemCount: cognitiveResult.removedCount,
            markedCognitiveItemCount: cognitiveResult.markedCount,
            removedDreamReportCount: try pruneDreamReports(at: brain.dreamReportsURL, interval: interval),
            backupURL: backupURL
        )
    }

    private static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 24 * 60 * 60)
    }

    private static func pruneEvents(at url: URL, interval: DateInterval) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let text = try String(contentsOf: url, encoding: .utf8)
        var keptLines: [String] = []
        var removed = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(line)
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                keptLines.append(rawLine)
                continue
            }
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               eventHasDate(in: interval, object: object) {
                removed += 1
            } else {
                keptLines.append(rawLine)
            }
        }

        if removed > 0 {
            try keptLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return removed
    }

    private static func pruneDreamReports(at url: URL, interval: DateInterval) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var journal = DreamReportJournal.load(from: url)
        let originalCount = journal.reports.count
        journal.reports.removeAll { interval.contains($0.createdAt) }
        let removed = originalCount - journal.reports.count
        if removed > 0 {
            try journal.write(to: url)
        }
        return removed
    }

    private static func eventHasDate(in interval: DateInterval, object: [String: Any]) -> Bool {
        BrainCognitiveCompactor.dateValue(forKeys: ["time", "timestamp", "date", "created_at"], in: object)
            .map(interval.contains) ?? false
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
        try copyIfPresent(brain.eventsURL, to: backupRoot.appendingPathComponent("events.jsonl"))
        try copyIfPresent(brain.dreamReportsURL, to: backupRoot.appendingPathComponent("dream_reports.json"))
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

nonisolated struct BrainCognitiveCompactionResult: Equatable {
    var removedCount: Int = 0
    var markedCount: Int = 0
    var restoredCount: Int = 0
}

nonisolated enum BrainCognitiveCompactor {
    static let identityKeyOrder = ["trace_id", "belief_id", "subject_id", "artifact_id", "dream_id"]
    static let identityKeys = Set(identityKeyOrder)
    static let referenceKeys = Set(["selected_trace_ids", "linked_trace_ids", "belief_change_ids", "generated_artifact_id", "source_trace_ids"])

    static func compactAfterDailyDream(
        in brain: BrainDescriptor,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> BrainCognitiveCompactionResult {
        let interval = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 24 * 60 * 60)
        if FileManager.default.fileExists(atPath: brain.memoryDatabaseURL.path) {
            _ = try BrainExperienceBackup.createBackup(
                for: brain,
                now: now,
                rootDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Affective-DailyMemoryCompactionBackups", isDirectory: true)
                    .appendingPathComponent(brain.id, isDirectory: true)
            )
        }
        return try compactStore(
            at: brain.memoryDatabaseURL,
            referenceExclusion: { item in
                item.isPendingDeletion && (item.pendingDeletionDate ?? now) < interval.start
            }
        ) { item, context in
            guard !item.isProtected else { return .keep }
            guard !context.referencedIDs.contains(item.id) else {
                return item.isPendingDeletion ? .restore : .keep
            }
            if item.isPendingDeletion, let markedAt = item.pendingDeletionDate, markedAt < interval.start {
                return .delete
            }
            return item.isPendingDeletion ? .keep : .mark(reason: "unreferenced", source: "daily_dream", at: now)
        }
    }

    static func forgetToday(
        in brain: BrainDescriptor,
        interval: DateInterval,
        now: Date = Date()
    ) throws -> BrainCognitiveCompactionResult {
        try compactStore(
            at: brain.memoryDatabaseURL,
            referenceExclusion: { $0.wasTouched(in: interval) }
        ) { item, context in
            guard !item.isProtected else { return .keep }
            if item.wasTouched(in: interval) {
                return .delete
            }
            guard !context.referencedIDs.contains(item.id) else {
                return item.isPendingDeletion ? .restore : .keep
            }
            if item.wasCreated(in: interval) {
                return .delete
            }
            return item.isPendingDeletion
                ? .keep
                : .mark(reason: "unreferenced_after_forget_today", source: "forget_today", at: now)
        }
    }

    private static func compactStore(
        at url: URL,
        referenceExclusion: (CognitiveItem) -> Bool = { _ in false },
        decision: (CognitiveItem, CognitiveCompactionContext) -> CognitiveItemDecision
    ) throws -> BrainCognitiveCompactionResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let dataJSON = try CognitiveStoreReader.readCognitiveJSON(from: url),
              let data = dataJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init()
        }

        let context = CognitiveCompactionContext(root: root, excluding: referenceExclusion)
        var result = BrainCognitiveCompactionResult()
        let compacted = compact(value: root, context: context, result: &result, decision: decision)
        guard result.removedCount > 0 || result.markedCount > 0 || result.restoredCount > 0 else {
            return result
        }
        try CognitiveStoreReader.writeCognitiveJSON(compacted, to: url)
        return result
    }

    private static func compact(
        value: Any,
        context: CognitiveCompactionContext,
        result: inout BrainCognitiveCompactionResult,
        decision: (CognitiveItem, CognitiveCompactionContext) -> CognitiveItemDecision
    ) -> Any {
        if let array = value as? [Any] {
            return array.compactMap { element in
                guard let object = element as? [String: Any],
                      let item = CognitiveItem(object: object) else {
                    return compact(value: element, context: context, result: &result, decision: decision)
                }

                switch decision(item, context) {
                case .keep:
                    return compact(value: object, context: context, result: &result, decision: decision)
                case .delete:
                    result.removedCount += 1
                    return nil
                case .mark(let reason, let source, let at):
                    result.markedCount += 1
                    var marked = object
                    markLifecycle(in: &marked, reason: reason, source: source, at: at)
                    return compact(value: marked, context: context, result: &result, decision: decision)
                case .restore:
                    result.restoredCount += 1
                    var restored = object
                    clearPendingDeletion(in: &restored)
                    return compact(value: restored, context: context, result: &result, decision: decision)
                }
            }
        }

        if let object = value as? [String: Any] {
            var compacted: [String: Any] = [:]
            for (key, child) in object {
                compacted[key] = compact(value: child, context: context, result: &result, decision: decision)
            }
            return compacted
        }

        return value
    }

    private static func markLifecycle(in object: inout [String: Any], reason: String, source: String, at date: Date) {
        var lifecycle = object["lifecycle"] as? [String: Any] ?? [:]
        lifecycle["status"] = "pending_deletion"
        lifecycle["pending_deletion_at"] = DreamReportDateFormatter.isoWithoutFractionalSeconds.string(from: date)
        lifecycle["pending_deletion_reason"] = reason
        lifecycle["pending_deletion_source"] = source
        object["lifecycle"] = lifecycle
    }

    private static func clearPendingDeletion(in object: inout [String: Any]) {
        guard var lifecycle = object["lifecycle"] as? [String: Any] else { return }
        if lifecycle["status"] as? String == "pending_deletion" {
            lifecycle["status"] = "active"
        }
        lifecycle.removeValue(forKey: "pending_deletion_at")
        lifecycle.removeValue(forKey: "pending_deletion_reason")
        lifecycle.removeValue(forKey: "pending_deletion_source")
        object["lifecycle"] = lifecycle
    }

    static func dateValue(forKeys keys: [String], in object: [String: Any]) -> Date? {
        for key in keys {
            guard let text = object[key] as? String,
                  let date = DreamReportDateFormatter.date(from: text) else {
                continue
            }
            return date
        }
        return nil
    }
}

nonisolated struct CognitiveCompactionContext {
    var referencedIDs: Set<String>

    init(root: [String: Any], excluding shouldExclude: (CognitiveItem) -> Bool) {
        referencedIDs = Self.collectReferences(in: root, excluding: shouldExclude)
    }

    private static func collectReferences(in value: Any, excluding shouldExclude: (CognitiveItem) -> Bool) -> Set<String> {
        var references = Set<String>()
        collectReferences(in: value, excluding: shouldExclude, into: &references)
        return references
    }

    private static func collectReferences(
        in value: Any,
        excluding shouldExclude: (CognitiveItem) -> Bool,
        into references: inout Set<String>
    ) {
        if let object = value as? [String: Any] {
            if let item = CognitiveItem(object: object), shouldExclude(item) {
                return
            }
            for (key, child) in object {
                if BrainCognitiveCompactor.identityKeys.contains(key) {
                    continue
                }
                if BrainCognitiveCompactor.referenceKeys.contains(key)
                    || key.hasSuffix("_id")
                    || key.hasSuffix("_ids") {
                    collectStringValues(in: child, into: &references)
                }
                collectReferences(in: child, excluding: shouldExclude, into: &references)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectReferences(in: child, excluding: shouldExclude, into: &references)
            }
        }
    }

    private static func collectStringValues(in value: Any, into references: inout Set<String>) {
        if let string = value as? String, !string.isEmpty {
            references.insert(string)
        } else if let array = value as? [Any] {
            for child in array {
                collectStringValues(in: child, into: &references)
            }
        }
    }
}

nonisolated struct CognitiveItem {
    var id: String
    var object: [String: Any]

    init?(object: [String: Any]) {
        guard let id = BrainCognitiveCompactor.identityKeyOrder
            .compactMap({ object[$0] as? String })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }
        self.id = id
        self.object = object
    }

    var lifecycle: [String: Any] {
        object["lifecycle"] as? [String: Any] ?? [:]
    }

    var isPendingDeletion: Bool {
        lifecycle["status"] as? String == "pending_deletion"
    }

    var isProtected: Bool {
        let values = [
            object["status"] as? String,
            object["retention"] as? String,
            lifecycle["status"] as? String,
            lifecycle["retention"] as? String,
        ].compactMap { $0?.lowercased() }
        return values.contains { ["pinned", "protected", "retained", "permanent"].contains($0) }
    }

    var pendingDeletionDate: Date? {
        (lifecycle["pending_deletion_at"] as? String).flatMap(DreamReportDateFormatter.date(from:))
    }

    func wasCreated(in interval: DateInterval) -> Bool {
        dateValues(forKeys: ["created_at"]).contains(where: interval.contains)
    }

    func wasTouched(in interval: DateInterval) -> Bool {
        dateValues(forKeys: ["created_at", "updated_at"]).contains(where: interval.contains)
    }

    private func dateValues(forKeys keys: [String]) -> [Date] {
        var dates: [Date] = []
        dates.append(contentsOf: keys.compactMap { key in
            guard let text = object[key] as? String else { return nil }
            return DreamReportDateFormatter.date(from: text)
        })
        if let lifecycle = object["lifecycle"] as? [String: Any] {
            dates.append(contentsOf: keys.compactMap { key in
                guard let text = lifecycle[key] as? String else { return nil }
                return DreamReportDateFormatter.date(from: text)
            })
        }
        return dates
    }
}

nonisolated enum CognitiveItemDecision {
    case keep
    case delete
    case mark(reason: String, source: String, at: Date)
    case restore
}

nonisolated struct CognitiveStoreReader {
    struct CognitiveFile: Decodable, Equatable {
        var dreams: [Dream]
        var artifacts: [Artifact]
    }

    struct Dream: Decodable, Equatable {
        var dreamID: String
        var selectedTraceIDs: [String]
        var generatedArtifactID: String?
        var reflection: String
        var heat: Double
        var createdAt: String

        enum CodingKeys: String, CodingKey {
            case dreamID = "dream_id"
            case selectedTraceIDs = "selected_trace_ids"
            case generatedArtifactID = "generated_artifact_id"
            case reflection
            case heat
            case createdAt = "created_at"
        }
    }

    struct Artifact: Decodable, Equatable {
        var artifactID: String
        var path: String
        var mimeType: String
        var provenance: String

        enum CodingKeys: String, CodingKey {
            case artifactID = "artifact_id"
            case path
            case mimeType = "mime_type"
            case provenance
        }
    }

    static func loadCognitiveFile(from databaseURL: URL) throws -> CognitiveFile? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        guard let dataJSON = try readCognitiveJSON(from: databaseURL) else { return nil }
        return try JSONDecoder().decode(CognitiveFile.self, from: Data(dataJSON.utf8))
    }

    static func readCognitiveJSON(from databaseURL: URL) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw CognitiveStoreReaderError.openFailed
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let textPointer = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: textPointer)
    }

    static func writeCognitiveJSON(_ value: Any, to databaseURL: URL) throws {
        let output = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let outputText = String(data: output, encoding: .utf8) ?? "{}"

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw CognitiveStoreReaderError.openFailed
        }
        defer { sqlite3_close(database) }

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE cognitive_memory SET data_json = ? WHERE id = 1", -1, &updateStatement, nil) == SQLITE_OK else {
            sqlite3_finalize(updateStatement)
            throw CognitiveStoreReaderError.updateFailed
        }
        defer { sqlite3_finalize(updateStatement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindStatus = outputText.withCString { pointer in
            sqlite3_bind_text(updateStatement, 1, pointer, -1, transient)
        }
        guard bindStatus == SQLITE_OK else {
            throw CognitiveStoreReaderError.updateFailed
        }
        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw CognitiveStoreReaderError.updateFailed
        }
        guard sqlite3_changes(database) > 0 else {
            throw CognitiveStoreReaderError.updateFailed
        }
    }
}

nonisolated enum CognitiveStoreReaderError: Error {
    case openFailed
    case updateFailed
}

nonisolated struct DreamEventReader {
    struct DreamImageEvent: Equatable {
        var path: String
        var prompt: String?
        var createdAt: Date?
    }

    static func loadDreamImageEvents(from eventsURL: URL) throws -> [String: DreamImageEvent] {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [:] }
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        var eventsByPath: [String: DreamImageEvent] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONValue.decodedObject(from: data),
                  object["title"]?.stringValue == "dream_image" else {
                continue
            }
            let path = object["body"]?.stringValue
                ?? object["interpretation"]?.stringValue
                ?? object["raw"]?.stringValue
            guard let path, !path.isEmpty else { continue }
            eventsByPath[path] = DreamImageEvent(
                path: path,
                prompt: object["raw"]?.stringValue,
                createdAt: object["time"]?.stringValue.flatMap(DreamReportDateFormatter.date(from:))
            )
        }
        return eventsByPath
    }
}

extension JSONDecoder {
    static var dreamReports: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var dreamReports: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
