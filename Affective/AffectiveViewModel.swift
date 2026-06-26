//
//  AffectiveViewModel.swift
//  Affective
//
//  Created by Zelda Hessler on 6/24/26.
//

import Foundation
import Combine

@MainActor
final class AffectiveViewModel: ObservableObject {
    static let legacyStoredOptionsKey = "Affective.runtimeOptions"
    static let autonomyBudgetOptionKey = "autonomy_daily_energy"
    static let boredomIntervalOptionKey = "boredom_interval_seconds"
    static let makeUpLostDreamTimeOptionKey = "make_up_lost_dream_time"
    static let speechVoiceOptionKey = "speech_voice"
    static let cameraDeviceIDOptionKey = "camera_device_id"
    static let textProviderPreferenceOptionKey = "text_provider_preference"
    static let motionGestureEnabledOptionKey = "motion_gesture_enabled"
    static let automaticCameraDeviceID = "automatic"
    static let recentStimulusLimit = 10
    static let recentStimulusRetentionSeconds: TimeInterval = 90
    static let socialTurnResponseWindowSeconds: TimeInterval = 8
    static let counterpartActivityWindowSeconds: TimeInterval = 12
    static let conversationRecentTurnLimit = 16
    static let conversationStopWords: Set<String> = [
        "about", "after", "again", "also", "because", "been", "being", "could", "from",
        "have", "into", "just", "like", "more", "much", "need", "only", "over", "should",
        "that", "their", "them", "then", "there", "these", "they", "this", "through",
        "what", "when", "where", "which", "with", "would", "your",
    ]
    nonisolated static let brainVoiceEnabledKey = "Affective.brainVoiceEnabled"
    nonisolated static let orientationPermissionStatusKey = "Affective.orientationPermissionStatus"
    static let credentialStore = KeychainCredentialStore()
    static let secretOptionKeys = Set(ProviderCredentialKey.allCases.map(\.rawValue))
    static let lastOpenedBrainIDKey = "Affective.lastOpenedBrainID"
    let brainCore: any BrainCoreClient
    let speechSpeaker = AppleSpeechSpeaker()
    var pokeStartedAt: Date?
    var lastPokeEndedAt: Date?
    var pendingPokePulses: [PokePulse] = []
    var recentStimuli: [RecentStimulus] = []
    var stimulusInventory: [String: StimulusInventoryRecord] = [:]
    var nextStimulusSequence = 1
    var conversationWorkingState = ConversationWorkingState()
    var pokeFlushTask: Task<Void, Never>?
    var boredomSenseTask: Task<Void, Never>?
    var boredomSenseGeneration = 0
    var lastHostStimulusAt = Date()
    var awaitingSocialResponseUntil: Date?
    var counterpartActiveUntil: Date?
    let brain: BrainDescriptor
    @Published var isBrainConnected = false
    @Published var isToolRunning = false
    var isBrainConnectionInFlight = false
    var hostPipelineQueue: [HostPipelineAction] = []
    var isHostPipelineRunning = false
    var currentHostPipelineAction: HostPipelineAction?
    var currentHostPipelineActionIsAwaitingChatResponse = false
    var pendingChatResponseCount = 0
    @Published var hostPipelineHold: HostPipelineHold = .none

    @Published var selectedSection: WorkspaceSection = .chat
    @Published var commandSearchText = ""
    @Published var selectedCommandKind: LogKind?
    @Published var knowledgeSearchText = ""
    @Published var selectedSettingsScope: SettingsScope = .brain
    @Published var messageText = ""
    @Published var statusText = "Ready"
    @Published var isPoking = false
    @Published var canSend = true
    @Published var brainVoiceEnabled = true
    @Published var isAwaitingChatResponse = false
    @Published var droppedImageName: String?
    @Published var commandEntries: [LogEntry] = []
    @Published var chatEntries: [LogEntry] = []
    @Published var memoryQuery = ""
    @Published var memoryText = ""
    @Published var memoryTags = ""
    @Published var reminderSchedule = "in 10 minutes"
    @Published var reminderText = ""
    @Published var brainStats = BrainStatsJournal()
    @Published var dreamReports: [DreamReport] = []
    @Published var selectedDreamReportID: DreamReport.ID?
    @Published var showsArchivedDreamReports = false
    @Published var brainNoteText = ""
    @Published var brainTraitsText = ""
    @Published var brainGoalsText = ""
    @Published var brainRecentMemoriesText = ""
    @Published var autonomyMode = "off"
    @Published var optionGroups: [RuntimeOptionGroup]
    @Published var developerToolActions: [CoreToolAction] = []
    @Published var credentialTestResults: [ProviderCredentialKey: CredentialTestStatus] = [:]
    private var canWriteBrainStats = true
    private var didCheckDreamOnLoad = false
    var cameraPermissionRequestTask: Task<HostCameraPermissionStatus, Never>?
    var pendingCameraRequestID: String?
    var didLogCoalescedCameraRequest = false
    var pendingOrientationRequestID: String?
    var cameraPhotoCaptureOverride: (() async throws -> Data)?
    var orientationObservationOverride: (() async throws -> OrientationObservation)?
    var hostCapabilityPendingSince: [String: Date] = [:]
    var closedPullSenseRequestIDs: Set<String> = []
    var terminalPullSenseRequestIDs: Set<String> = []
    var orientationPermissionStatusOverride: HostOrientationPermissionStatus?
    var orientationCapabilityStatusOverride: HostOrientationPermissionStatus?
    var orientationPermissionContinuation: CheckedContinuation<HostOrientationPermissionStatus, Never>?
    var motionGestureMonitor: MotionGestureMonitor?
    @Published var orientationPermissionPrompt: OrientationPermissionPrompt?

    init(brain: BrainDescriptor, brainCore: (any BrainCoreClient)? = nil) {
        self.brain = brain
        self.brainCore = brainCore ?? BrainCore(brain: brain)
        let storedValues = Self.storedValuesForLaunch(brain: brain)
        brainVoiceEnabled = UserDefaults.standard.object(forKey: Self.brainVoiceEnabledKey) as? Bool ?? true
        autonomyMode = storedValues["autonomy_mode"] ?? "off"
        optionGroups = Self.loadOptionGroups(storedValues: storedValues, brain: brain)
        UserDefaults.standard.set(brain.id, forKey: Self.lastOpenedBrainIDKey)
        statusText = "Opening \(brain.displayName)"
        commandEntries = [
            .init(kind: .state, title: "brain selected", body: brain.rootURL.path, metadata: ["brain": brain.id]),
        ]
        chatEntries = [
            .init(kind: .brain, title: "Brain Loaded", body: "Loaded \(brain.displayName). Chat by typing or with the poke button.", metadata: ["brain": brain.id]),
        ]
        loadBrainStats()
        loadDreamReports()
        recordBrainSizeSnapshotIfNeeded()
        refreshDreamReports()
    }

    deinit {
        boredomSenseTask?.cancel()
        motionGestureMonitor?.stop()
    }

    var coreStatusText: String {
        if isBrainConnectionInFlight { return "connecting" }
        if isBrainConnected { return "connected" }
        return "disconnected"
    }

    var coreStatusSymbolName: String {
        if isBrainConnectionInFlight { return "arrow.triangle.2.circlepath" }
        if isBrainConnected { return "point.3.connected.trianglepath.dotted" }
        return "point.3.filled.connected.trianglepath.dotted"
    }

    var visibleEntryCount: Int {
        switch selectedSection {
        case .chat: chatEntries.count
        case .developer: filteredCommandEntries.count
        case .knowledge: filteredKnowledgeEntries.count
        case .mailbox: visibleDreamReports.count
        case .stats: brainStats.notes.count + brainStats.profileSnapshots.count + brainStats.sizeSnapshots.count
        case .settings: optionGroups.reduce(0) { $0 + $1.options.count }
    }
    }

    var filteredCommandEntries: [LogEntry] {
        filtered(entries: commandEntries, query: commandSearchText, kind: selectedCommandKind)
    }

    var filteredKnowledgeEntries: [LogEntry] {
        let memoryEntries = commandEntries.filter { entry in
            let searchable = "\(entry.title) \(entry.body) \(entry.metadata.values.joined(separator: " "))"
            return searchable.localizedCaseInsensitiveContains("memory")
                || searchable.localizedCaseInsensitiveContains("reminder")
                || searchable.localizedCaseInsensitiveContains("dream")
                || searchable.localizedCaseInsensitiveContains("attention")
        }
        return filtered(entries: memoryEntries, query: knowledgeSearchText, kind: nil)
    }

    var selectedSettingsGroups: [RuntimeOptionGroup] {
        optionGroups.filter { $0.scope == selectedSettingsScope }
    }

    var visibleDreamReports: [DreamReport] {
        dreamReports
            .filter { Self.isDreamReportVisible($0, showsArchived: showsArchivedDreamReports) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.dreamID.localizedCaseInsensitiveCompare($1.dreamID) == .orderedAscending
            }
    }

    var selectedDreamReport: DreamReport? {
        guard let selectedDreamReportID else { return visibleDreamReports.first }
        return dreamReports.first { $0.id == selectedDreamReportID }
    }

    var unreadDreamReportCount: Int {
        dreamReports.filter { !$0.isRead && !$0.isArchived }.count
    }

    static func hasAnyProviderCredential() -> Bool {
        !keychainCredentialValues().isEmpty
    }

    static func saveProviderCredentials(_ credentials: [ProviderCredentialKey: String]) throws {
        for (key, rawCredential) in credentials {
            let credential = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !credential.isEmpty else { continue }
            try credentialStore.saveCredential(credential, for: key)
        }
    }

    var dirtyOptionCount: Int {
        optionGroups.reduce(0) { total, group in
            total + group.options.filter(\.isDirty).count
        }
    }

    var restartDirtyCount: Int {
        optionGroups.reduce(0) { total, group in
            total + group.options.filter { $0.isDirty && $0.requiresRestart }.count
        }
    }

    var autonomyActionBudget: Int {
        max(runtimeOptionIntValue(for: Self.autonomyBudgetOptionKey) ?? 0, 0)
    }

    var currentBrainSizeText: String {
        BrainStatsFormatter.bytes(brainStats.latestSizeSnapshot?.bytes ?? 0)
    }

    func loadBrainStats() {
        do {
            brainStats = try BrainStatsJournal.load(from: brain.statsJournalURL)
            canWriteBrainStats = true
        } catch {
            brainStats = BrainStatsJournal()
            canWriteBrainStats = false
            statusText = "Stats file needs repair: \(error.localizedDescription)"
        }
    }

    func recordBrainSizeSnapshotIfNeeded(force: Bool = false) {
        guard canWriteBrainStats else { return }
        let rootURL = brain.rootURL
        Task {
            let bytes = await Task.detached {
                FileManager.default.approximateDirectorySize(at: rootURL)
            }.value
            var journal = brainStats
            guard journal.recordSize(bytes, force: force) else { return }
            saveBrainStats(journal, successStatus: force ? "Updated brain stats" : nil)
        }
    }

    func addBrainNote() {
        var journal = brainStats
        journal.addNote(brainNoteText)
        guard journal != brainStats else { return }
        brainNoteText = ""
        saveBrainStats(journal)
    }

    func addBrainProfileSnapshot() {
        var journal = brainStats
        journal.addProfileSnapshot(
            traits: brainTraitsText,
            goals: brainGoalsText,
            recentMemories: brainRecentMemoriesText
        )
        guard journal != brainStats else { return }
        brainTraitsText = ""
        brainGoalsText = ""
        brainRecentMemoriesText = ""
        saveBrainStats(journal)
    }

    private func saveBrainStats(_ journal: BrainStatsJournal, successStatus: String? = "Updated brain stats") {
        guard canWriteBrainStats else {
            statusText = "Stats file needs repair before Affective can save new stats."
            return
        }
        do {
            try journal.write(to: brain.statsJournalURL)
            brainStats = journal
            if let successStatus {
                statusText = successStatus
            }
        } catch {
            statusText = "Stats update failed: \(error.localizedDescription)"
        }
    }

    func loadDreamReports() {
        dreamReports = DreamReportJournal.load(from: brain.dreamReportsURL).reports
        if selectedDreamReportID == nil {
            selectedDreamReportID = visibleDreamReports.first?.id
        }
    }

    func refreshDreamReports() {
        Task {
            await collectDreamReports()
        }
    }

    func enterDreamOnLoadIfNeeded(now: Date = Date()) async {
        guard runtimeOptionStringValue(for: Self.makeUpLostDreamTimeOptionKey) == "on" else { return }
        guard !didCheckDreamOnLoad else { return }
        didCheckDreamOnLoad = true
        let journal = DreamReportJournal(reports: dreamReports)
        guard DreamReportCollector.shouldEnterDreamOnLoad(brain: brain, journal: journal, now: now) else {
            appendCommand(kind: .state, title: "dream load check", body: "Brain has dreamed in the past 24 hours.")
            return
        }

        appendCommand(kind: .sent, title: "dream load check", body: "No dream found in the past 24 hours; entering dream.")
        await callCoreTool(name: "dream", title: "Dream", arguments: [:], mirrorToChat: true)
    }

    func collectDreamReports() async {
        let journal = DreamReportJournal(reports: dreamReports)
        let updated: DreamReportJournal
        do {
            updated = try await DreamReportCollector.collect(brain: brain, existing: journal)
        } catch {
            statusText = "Dream report update failed: \(error.localizedDescription)"
            return
        }
        let mergedReports = Self.mergedDreamReports(scanned: updated.reports, current: dreamReports)
        dreamReports = mergedReports
        if mergedReports != updated.reports {
            do {
                try DreamReportJournal(reports: mergedReports).write(to: brain.dreamReportsURL)
            } catch {
                statusText = "Mailbox update failed: \(error.localizedDescription)"
            }
        }
        if selectedDreamReportID == nil || !visibleDreamReports.contains(where: { $0.id == selectedDreamReportID }) {
            selectedDreamReportID = visibleDreamReports.first?.id
        }
    }

    func selectDreamReport(_ report: DreamReport) {
        selectedDreamReportID = report.id
        setDreamReport(report.id, isRead: true)
    }

    func setDreamReport(_ reportID: DreamReport.ID, isRead: Bool) {
        mutateDreamReport(reportID) { report in
            report.isRead = isRead
        }
    }

    func setDreamReport(_ reportID: DreamReport.ID, isArchived: Bool) {
        mutateDreamReport(reportID) { report in
            report.isArchived = isArchived
        }
        if isArchived, selectedDreamReportID == reportID {
            selectedDreamReportID = visibleDreamReports.first?.id
        }
    }

    private func mutateDreamReport(_ reportID: DreamReport.ID, update: (inout DreamReport) -> Void) {
        guard let index = dreamReports.firstIndex(where: { $0.id == reportID }) else { return }
        update(&dreamReports[index])
        saveDreamReports()
    }

    private func saveDreamReports() {
        do {
            try DreamReportJournal(reports: dreamReports).write(to: brain.dreamReportsURL)
            statusText = "Updated mailbox"
        } catch {
            statusText = "Mailbox update failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func mergedDreamReports(scanned: [DreamReport], current: [DreamReport]) -> [DreamReport] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var mergedByID = currentByID

        for scannedReport in scanned {
            if let currentReport = currentByID[scannedReport.id] {
                var report = scannedReport
                report.isRead = currentReport.isRead
                report.isArchived = currentReport.isArchived
                mergedByID[scannedReport.id] = report
            } else {
                mergedByID[scannedReport.id] = scannedReport
            }
        }

        return Array(mergedByID.values).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.dreamID.localizedCaseInsensitiveCompare($1.dreamID) == .orderedAscending
        }
    }

    nonisolated static func isDreamReportVisible(_ report: DreamReport, showsArchived: Bool) -> Bool {
        showsArchived ? report.isArchived : !report.isArchived
    }

}

enum HostPipelineHold: Equatable {
    case none
    case cameraPermission
    case orientationPermission
    case cameraCapture
    case speechOutput

    var statusText: String {
        switch self {
        case .none:
            return "Ready"
        case .cameraPermission:
            return "Waiting for camera permission"
        case .orientationPermission:
            return "Waiting for orientation permission"
        case .cameraCapture:
            return "Sensing with camera"
        case .speechOutput:
            return "Affective is speaking"
        }
    }
}

enum HostPipelineAction {
    case interrupt(userText: String, reason: String, interruptedAction: String?, canceledQueuedActionCount: Int)
    case typedText(text: String, stimulusContext: StimulusContext)
    case imageText(prompt: String, attachment: [String: JSONValue], stimulusContext: StimulusContext)
    case coreTool(name: String, title: String, arguments: [String: JSONValue], mirrorToChat: Bool, requiresCamera: Bool = false)
    case coreTouch(name: String, title: String)
    case pokeSequence([PokePulse])
    case pushedMotionGesture(MotionGestureObservation)
    case refreshBrainState
}

nonisolated struct RecentStimulus: Equatable {
    let id: Int
    let kind: String
    let occurredAt: Date
    let summary: String
    let salience: Double
    let metadata: [String: String]
}

nonisolated struct RecentStimulusSnapshot: Equatable {
    let id: Int
    let kind: String
    let ageSeconds: Double
    let summary: String
    let salience: Double
    let metadata: [String: String]

    var eventArguments: [String: JSONValue] {
        [
            "id": .number(Double(id)),
            "kind": .string(kind),
            "age_seconds": .number(ageSeconds),
            "summary": .string(summary),
            "salience": .number(salience),
            "metadata": .object(metadata.mapValues { .string($0) }),
        ]
    }
}

nonisolated struct StimulusInventoryRecord: Equatable {
    var kind: String
    var totalCount = 0
    var lastOccurredAt: Date
    var lastSummary: String
    var lastMetadata: [String: String]
}

nonisolated struct StimulusInventorySnapshot: Equatable {
    let kind: String
    let totalCount: Int
    let recentCount: Int
    let lastAgeSeconds: Double
    let lastSummary: String
    let lastMetadata: [String: String]

    var eventArguments: [String: JSONValue] {
        [
            "kind": .string(kind),
            "total_count": .number(Double(totalCount)),
            "recent_count": .number(Double(recentCount)),
            "last_age_seconds": .number(lastAgeSeconds),
            "last_summary": .string(lastSummary),
            "last_metadata": .object(lastMetadata.mapValues { .string($0) }),
        ]
    }
}

nonisolated struct ConversationTurnRecord: Equatable {
    let speakerRole: String
    let speakerName: String?
    let text: String
    let occurredAt: Date
    let source: String
    let salience: Double
    let metadata: [String: String]
}

nonisolated struct ConversationTurnSnapshot: Equatable {
    let speakerRole: String
    let speakerName: String?
    let text: String
    let occurredAtUnixMS: Double
    let ageSeconds: Double
    let source: String
    let salience: Double
    let metadata: [String: String]

    var eventArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "role": .string(speakerRole),
            "speaker_role": .string(speakerRole),
            "text": .string(text),
            "occurred_at_unix_ms": .number(occurredAtUnixMS),
            "age_seconds": .number(ageSeconds),
            "source": .string(source),
            "salience": .number(salience),
            "metadata": .object(metadata.mapValues { .string($0) }),
        ]
        if let speakerName {
            arguments["speaker_name"] = .string(speakerName)
        }
        return arguments
    }
}

nonisolated struct ConversationContextSnapshot: Equatable {
    let mode: String
    let rollingSummary: String
    let activeThreads: [String]
    let unresolvedQuestions: [String]
    let recentTurns: [ConversationTurnSnapshot]

    var eventArguments: [String: JSONValue] {
        [
            "mode": .string(mode),
            "rolling_summary": .string(rollingSummary),
            "active_threads": .array(activeThreads.map { .string($0) }),
            "unresolved_questions": .array(unresolvedQuestions.map { .string($0) }),
            "recent_turns": .array(recentTurns.map { .object($0.eventArguments) }),
        ]
    }
}

nonisolated struct ConversationWorkingState: Equatable {
    var mode = "winding_conversation"
    var rollingSummary = ""
    var activeThreads: [String] = []
    var unresolvedQuestions: [String] = []
    var recentTurns: [ConversationTurnRecord] = []
}

nonisolated struct StimulusContext: Equatable {
    let kind: String
    let receivedDuring: String
    let ongoingAction: String?
    let hostHold: String?
    let queuedActionCount: Int
    let speechOutputActive: Bool
    let awaitingSocialResponse: Bool
    let socialTurnResponseWindowRemainingSeconds: Double
    let counterpartActive: Bool
    let counterpartActivityWindowRemainingSeconds: Double
    let recentStimuli: [RecentStimulusSnapshot]
    let senseInventory: [StimulusInventorySnapshot]
    let localTime: Date
    let conversationContext: ConversationContextSnapshot

    var eventArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "kind": .string(kind),
            "received_during": .string(receivedDuring),
            "queued_action_count": .number(Double(queuedActionCount)),
            "speech_output_active": .bool(speechOutputActive),
            "awaiting_social_response": .bool(awaitingSocialResponse),
            "social_turn_response_window_remaining_seconds": .number(socialTurnResponseWindowRemainingSeconds),
            "counterpart_active": .bool(counterpartActive),
            "counterpart_activity_window_remaining_seconds": .number(counterpartActivityWindowRemainingSeconds),
            "local_time_unix_ms": .number((localTime.timeIntervalSince1970 * 1000).rounded()),
            "local_time_iso8601": .string(Self.localTimeFormatter.string(from: localTime)),
            "conversation_context": .object(conversationContext.eventArguments),
        ]
        if !recentStimuli.isEmpty {
            arguments["recent_stimuli"] = .array(recentStimuli.map { .object($0.eventArguments) })
        }
        if !senseInventory.isEmpty {
            arguments["sense_inventory"] = .array(senseInventory.map { .object($0.eventArguments) })
        }
        if let ongoingAction {
            arguments["ongoing_action"] = .string(ongoingAction)
        }
        if let hostHold {
            arguments["host_hold"] = .string(hostHold)
        }
        return arguments
    }

    private static let localTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
