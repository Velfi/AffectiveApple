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
    static let autonomyBudgetOptionKey = "autonomy_daily_energy"
    static let autonomyLimitedMaxCapacityOptionKey = "autonomy_limited_max_capacity"
    static let autonomyFullMaxCapacityOptionKey = "autonomy_full_max_capacity"
    static let boredomIntervalOptionKey = "boredom_interval_seconds"
    static let boredomIntervalMinSeconds = 60
    static let makeUpLostDreamTimeOptionKey = "make_up_lost_dream_time"
    static let speechVoiceOptionKey = "speech_voice"
    static let cameraDeviceIDOptionKey = "camera_device_id"
    nonisolated static let textProviderPreferenceOptionKey = "text_provider_preference"
    nonisolated static let motionGestureEnabledOptionKey = "motion_gesture_enabled"
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
    let notificationSounds = BrainNotificationSounds.shared
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
    @Published private(set) var brain: BrainDescriptor
    @Published var brainPresentationName: String?
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
    @Published var eventSearchText = ""
    @Published var selectedEventKind: LogKind?
    @Published var knowledgeSearchText = ""
    @Published var selectedSettingsScope: SettingsScope = .brain
    @Published var messageText = ""
    @Published var statusText = "Ready"
    @Published var isPoking = false
    @Published var canSend = true
    @Published var brainMode = "waking"
    @Published var brainVoiceEnabled = true
    @Published var isAwaitingChatResponse = false
    @Published var droppedImageName: String?
    @Published var eventEntries: [LogEntry] = []
    @Published var chatEntries: [LogEntry] = []
    @Published private(set) var storedKnowledgeEntries: [LogEntry] = []
    @Published var memoryQuery = ""
    @Published var memoryText = ""
    @Published var memoryTags = ""
    @Published var reminderSchedule = "in 10 minutes"
    @Published var reminderText = ""
    @Published var brainStats = BrainStatsJournal()
    @Published var mailboxItems: [MailboxItem] = []
    @Published var selectedMailboxItemID: MailboxItem.ID?
    @Published var showsArchivedMailboxItems = false
    private var mailboxUIState = MailboxUIStateJournal()
    @Published var brainNoteText = ""
    @Published var brainTraitsText = ""
    @Published var brainGoalsText = ""
    @Published var brainRecentMemoriesText = ""
    @Published var autonomyMode = "off"
    @Published var optionGroups: [RuntimeOptionGroup]
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
    @Published var avatarEyeSprite: String?
    @Published var avatarMouthSprite: String?
    var facialExpressionRevertTask: Task<Void, Never>?
    var queuedFacialExpressions: [QueuedFacialExpression] = []
    var applyingQueuedFacialExpression = false
    @Published var autonomyControlCapacity: Double = 1.0
    @Published var autonomyMaxCapacity: Double = 1.0

    init(brain: BrainDescriptor, brainCore: (any BrainCoreClient)? = nil) {
        self.brain = brain
        self.brainCore = brainCore ?? BrainCore(brain: brain)
        let storedValues = Self.storedValuesForLaunch(brain: brain)
        brainVoiceEnabled = UserDefaults.standard.object(forKey: Self.brainVoiceEnabledKey) as? Bool ?? true
        autonomyMode = Self.normalizeAutonomyMode(storedValues["autonomy_mode"] ?? "off")
        optionGroups = Self.loadOptionGroups(storedValues: storedValues, brain: brain)
        UserDefaults.standard.set(brain.id, forKey: Self.lastOpenedBrainIDKey)
        statusText = "Opening \(brain.displayName)"
        eventEntries = [
            .init(kind: .state, title: "brain selected", body: brain.rootURL.path, metadata: ["brain": brain.id]),
        ]
        chatEntries = [
            .init(kind: .brain, title: "Brain Loaded", body: "Loaded \(brain.displayName). Chat by typing or with the poke button.", metadata: ["brain": brain.id]),
        ]
        loadBrainStats()
        loadMailboxItems()
        recordBrainSizeSnapshotIfNeeded()
        refreshMailboxItems()
        refreshKnowledgeEntries()
        resetAvatarFacialExpression()
    }

    func reloadBrain(_ updated: BrainDescriptor) {
        guard updated.id == brain.id else { return }
        brain = updated
        refreshKnowledgeEntries()
        resetAvatarFacialExpression()
    }

    deinit {
        boredomSenseTask?.cancel()
        motionGestureMonitor?.stop()
    }

    var workspaceBrainTitle: String {
        brainPresentationName ?? brain.displayName
    }

    var coreStatusText: String {
        if isBrainConnectionInFlight { return "connecting" }
        if isBrainConnected { return "connected" }
        return "disconnected"
    }

    var isBrainUnavailableForConversation: Bool {
        Self.conversationBlockedBrainModes.contains(brainMode)
    }

    var brainModeStatusText: String {
        switch brainMode {
        case "drowsy": return "Brain is drowsy"
        case "dreaming": return "Brain is dreaming"
        case "waking_up": return "Brain is waking up"
        case "unavailable": return "Brain is unavailable"
        default: return "Ready"
        }
    }

    static let conversationBlockedBrainModes: Set<String> = [
        "drowsy",
        "dreaming",
        "waking_up",
        "unavailable",
    ]

    var coreStatusSymbolName: String {
        if isBrainConnectionInFlight { return "arrow.triangle.2.circlepath" }
        if isBrainConnected { return "point.3.connected.trianglepath.dotted" }
        return "point.3.filled.connected.trianglepath.dotted"
    }

    var visibleEntryCount: Int {
        switch selectedSection {
        case .chat: chatEntries.count
        case .developer: filteredEventEntries.count
        case .knowledge: filteredKnowledgeEntries.count
        case .mailbox: visibleMailboxItems.count
        case .stats: brainStats.notes.count + brainStats.profileSnapshots.count + brainStats.sizeSnapshots.count
        case .settings: optionGroups.reduce(0) { $0 + $1.options.count }
    }
    }

    var filteredEventEntries: [LogEntry] {
        filtered(entries: eventEntries, query: eventSearchText, kind: selectedEventKind)
    }

    var filteredKnowledgeEntries: [LogEntry] {
        let sessionEntries = eventEntries.filter(BrainKnowledgeReader.isKnowledgeRelated)
        let combined = deduplicatedKnowledgeEntries(storedKnowledgeEntries + sessionEntries)
        return filtered(entries: combined, query: knowledgeSearchText, kind: nil)
    }

    func refreshKnowledgeEntries() {
        do {
            storedKnowledgeEntries = try BrainKnowledgeReader.loadEntries(from: brain)
        } catch {
            appendEventLog(kind: .error, title: "knowledge_load failed", body: error.localizedDescription)
        }
    }

    func deduplicatedKnowledgeEntries(_ entries: [LogEntry]) -> [LogEntry] {
        var seenSourceIDs = Set<String>()
        var output: [LogEntry] = []
        for entry in entries {
            if let sourceID = entry.metadata["knowledge_source_id"] {
                guard seenSourceIDs.insert(sourceID).inserted else { continue }
            }
            output.append(entry)
        }
        return output
    }

    var selectedSettingsGroups: [RuntimeOptionGroup] {
        optionGroups.filter { $0.scope == selectedSettingsScope }
    }

    var visibleMailboxItems: [MailboxItem] {
        mailboxItems
            .filter { Self.isMailboxItemVisible($0, showsArchived: showsArchivedMailboxItems) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.sourceDreamID.localizedCaseInsensitiveCompare($1.sourceDreamID) == .orderedAscending
            }
    }

    var selectedMailboxItem: MailboxItem? {
        guard let selectedMailboxItemID else { return visibleMailboxItems.first }
        return mailboxItems.first { $0.id == selectedMailboxItemID }
    }

    var unreadMailboxItemCount: Int {
        mailboxItems.filter { !$0.isRead && !$0.isArchived }.count
    }

    static func hasAnyProviderCredential() -> Bool {
        !resolvedProviderCredentials().isEmpty
    }

    static func resolvedProviderCredentials() -> [ProviderCredentialKey: String] {
        ProviderCredentialKey.resolvedCredentials(using: credentialStore)
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

    var normalizedAutonomyMode: String {
        Self.normalizeAutonomyMode(autonomyMode)
    }

    var autonomyIsEnabled: Bool {
        normalizedAutonomyMode != "off"
    }

    var autonomyCapacityFraction: Double {
        guard autonomyMaxCapacity > 0 else { return 0 }
        return min(max(autonomyControlCapacity / autonomyMaxCapacity, 0), 1)
    }

    var autonomyCapacityPercentText: String {
        "\(Int((autonomyCapacityFraction * 100).rounded()))%"
    }

    static func normalizeAutonomyMode(_ rawMode: String) -> String {
        switch rawMode {
        case "full", "limited", "off":
            return rawMode
        case "on":
            return "full"
        default:
            return "off"
        }
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

    func loadMailboxItems() {
        mailboxUIState = Self.loadMailboxUIState(brain: brain)
        if selectedMailboxItemID == nil {
            selectedMailboxItemID = visibleMailboxItems.first?.id
        }
    }

    func refreshMailboxItems() {
        Task {
            await collectMailboxItems()
        }
    }

    func enterDreamOnLoadIfNeeded(now: Date = Date()) async {
        guard runtimeOptionStringValue(for: Self.makeUpLostDreamTimeOptionKey) == "on" else { return }
        guard !didCheckDreamOnLoad else { return }
        didCheckDreamOnLoad = true
        guard Self.shouldRequestDreamTimeFromMailbox(mailboxItems, now: now) else {
            appendEventLog(kind: .state, title: "dream load check", body: "Brain has dreamed in the past 24 hours.")
            return
        }

        appendEventLog(kind: .sent, title: "dream load check", body: "No mailbox dream found in the past 24 hours; requesting Dream Time.")
        brainMode = "dreaming"
        canSend = false
        statusText = brainModeStatusText
        do {
            _ = try await brainCore.requestDreamTime(prompt: nil)
            await refreshBrainMode()
            await collectMailboxItems()
        } catch {
            statusText = "Dream Time failed: \(error.localizedDescription)"
            appendEventLog(kind: .error, title: "request_dream_time failed", body: error.localizedDescription)
            await refreshBrainMode()
        }
    }

    func collectMailboxItems() async {
        do {
            let response = try await brainCore.mailboxList()
            let stateByID = mailboxUIState.stateByMailboxID
            mailboxItems = response.items.map {
                MailboxItem(mailbox: $0, state: stateByID[$0.mailboxID])
                    .resolvingArtifact(in: brain.memoryDatabaseURL)
            }
        } catch {
            statusText = "Mailbox update failed: \(error.localizedDescription)"
            return
        }
        if selectedMailboxItemID == nil || !visibleMailboxItems.contains(where: { $0.id == selectedMailboxItemID }) {
            selectedMailboxItemID = visibleMailboxItems.first?.id
        }
    }

    func selectMailboxItem(_ item: MailboxItem) {
        selectedMailboxItemID = item.id
        setMailboxItem(item.id, isRead: true)
    }

    func setMailboxItem(_ itemID: MailboxItem.ID, isRead: Bool) {
        mailboxUIState.set(mailboxID: itemID, isRead: isRead)
        mutateMailboxItem(itemID) { item in
            item.isRead = isRead
        }
        if isRead {
            Task { try? await brainCore.mailboxMarkRead(mailboxID: itemID) }
        }
    }

    func setMailboxItem(_ itemID: MailboxItem.ID, isArchived: Bool) {
        mailboxUIState.set(mailboxID: itemID, isArchived: isArchived)
        mutateMailboxItem(itemID) { item in
            item.isArchived = isArchived
        }
        if isArchived, selectedMailboxItemID == itemID {
            selectedMailboxItemID = visibleMailboxItems.first?.id
        }
    }

    private func mutateMailboxItem(_ itemID: MailboxItem.ID, update: (inout MailboxItem) -> Void) {
        guard let index = mailboxItems.firstIndex(where: { $0.id == itemID }) else { return }
        update(&mailboxItems[index])
        saveMailboxItems()
    }

    private func saveMailboxItems() {
        do {
            try mailboxUIState.write(to: brain.mailboxUIStateURL)
            statusText = "Updated mailbox"
        } catch {
            statusText = "Mailbox update failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func mergedMailboxItems(scanned: [MailboxItem], current: [MailboxItem]) -> [MailboxItem] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var mergedByID = currentByID

        for scannedItem in scanned {
            if let currentItem = currentByID[scannedItem.id] {
                var item = scannedItem
                item.isRead = currentItem.isRead
                item.isArchived = currentItem.isArchived
                mergedByID[scannedItem.id] = item
            } else {
                mergedByID[scannedItem.id] = scannedItem
            }
        }

        return Array(mergedByID.values).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.sourceDreamID.localizedCaseInsensitiveCompare($1.sourceDreamID) == .orderedAscending
        }
    }

    nonisolated static func isMailboxItemVisible(_ item: MailboxItem, showsArchived: Bool) -> Bool {
        showsArchived ? item.isArchived : !item.isArchived
    }

    nonisolated static func shouldRequestDreamTimeFromMailbox(_ items: [MailboxItem], now: Date = Date()) -> Bool {
        guard let latest = items.map(\.createdAt).max() else { return true }
        return now.timeIntervalSince(latest) >= MailboxItem.recentMailboxDeliveryInterval
    }

    nonisolated static func loadMailboxUIState(brain: BrainDescriptor) -> MailboxUIStateJournal {
        MailboxUIStateJournal.load(from: brain.mailboxUIStateURL)
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
    case imageText(prompt: String, attachment: [String: JSONValue], mediaPayload: String, stimulusContext: StimulusContext)
    case coreTouch(name: String, title: String)
    case pokeSequence([PokePulse])
    case pushedMotionGesture(MotionGestureObservation)
    case boredomStimulus(text: String, stimulusContext: StimulusContext)
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
