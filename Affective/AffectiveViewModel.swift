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
    static let boredomIntervalOptionKey = "boredom_interval_seconds"
    static let boredomIntervalMinSeconds = 60
    static let makeUpLostDreamTimeOptionKey = "make_up_lost_dream_time"
    static let llmQualityOptionKey = "llm_quality"
    static let speechVoiceOptionKey = "speech_voice"
    static let cameraDeviceIDOptionKey = "camera_device_id"
    nonisolated static let cameraCaptureEnabledOptionKey = "camera_capture_enabled"
    nonisolated static let textProviderPreferenceOptionKey = "text_provider_preference"
    nonisolated static let motionGestureEnabledOptionKey = "motion_gesture_enabled"
    static let automaticCameraDeviceID = "automatic"
    static let recentStimulusLimit = 10
    static let recentStimulusRetentionSeconds: TimeInterval = 90
    static let sensePacketWindowSeconds: TimeInterval = 12
    static let sensePacketDigestItemLimit = 6
    static let visibleLogEntryLimit = 600
    static let logSearchIndexCacheLimit = 4_000
    static let socialTurnResponseWindowSeconds: TimeInterval = 8
    static let autonomySensePollSeconds = 5
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
    let brainSpeechNotifications: any BrainSpeechNotificationClient
    var pokeStartedAt: Date?
    var lastPokeEndedAt: Date?
    var pendingPokePulses: [PokePulse] = []
    var stimulusInbox = StimulusInbox()
    var conversationWorkingState = ConversationWorkingState()
    var pokeFlushTask: Task<Void, Never>?
    var boredomSenseTask: Task<Void, Never>?
    var boredomSenseGeneration = 0
    var autonomySenseTask: Task<Void, Never>?
    var autonomySenseGeneration = 0
    var lastHostStimulusAt = Date()
    var lastSocialSenseInputAt: Date?
    var lastAutonomyTickAt = Date()
    var awaitingSocialResponseUntil: Date?
    var counterpartActiveUntil: Date?
    @Published private(set) var brain: BrainDescriptor
    @Published var brainPresentationName: String?
    @Published var isBrainConnected = false
    @Published private(set) var hasAttemptedInitialCoreLoad = false
    @Published var isToolRunning = false
    @Published var isDreamTimeInFlight = false
    @Published var isBrainConnectionInFlight = false
    var hostPipelineQueue: [HostPipelineAction] = []
    var isHostPipelineRunning = false
    var currentHostPipelineAction: HostPipelineAction?
    var currentHostPipelineActionIsAwaitingChatResponse = false
    var pendingChatResponseCount = 0
    var conversationDispatchGeneration = 0
    @Published var hostPipelineHold: HostPipelineHold = .none

    @Published var selectedSection: WorkspaceSection = .chat
    @Published var eventSearchText = ""
    @Published var selectedEventKind: LogKind?
    @Published var developerEventSort: DeveloperEventSort = .newestFirst
    @Published var selectedEventEntryID: LogEntry.ID?
    @Published var knowledgeSearchText = ""
    @Published var selectedKnowledgeEntryID: LogEntry.ID?
    @Published var selectedSettingsScope: SettingsScope = .brain
    @Published var focusedSettingsGroupTitle: String?
    @Published var messageText = ""
    @Published var statusText = "Ready"
    @Published var coreLoadProgressLabel = ""
    @Published var coreLoadProgressDetail = ""
    @Published private(set) var lastCoreLoadMetrics: CoreLoadMetricsReport?
    @Published var isPoking = false
    @Published var canSend = true
    @Published var brainMode = "waking"
    var stimulusInboxPendingCount = 0
    @Published var innerStateSummary = ""
    @Published var innerStateSummaryCore = ""
    @Published var brainVoiceEnabled = true
    @Published var isAwaitingChatResponse = false
    @Published var brainLoopPhase: BrainLoopPhase?
    @Published var activeProcessGoal: String?
    @Published var activeProcessState: String?
    @Published var activeProcessStepName: String?
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
    @Published var autonomyMode = "pause"
    @Published var optionGroups: [RuntimeOptionGroup]
    @Published var credentialTestResults: [ProviderCredentialKey: CredentialTestStatus] = [:]
    private var canWriteBrainStats = true
    private var didCheckDreamOnLoad = false
    var cameraPermissionRequestTask: Task<HostCameraPermissionStatus, Never>?
    var pendingCameraRequestID: String?
    var didLogCoalescedCameraRequest = false
    var coalescedPullSenseLoggedForActiveRequest: [String: String] = [:]
    var pendingOrientationRequestID: String?
    var inFlightPullSenseRequestIDs: [String: String] = [:]
    var activePullSenseFulfillmentCount = 0
    var cameraPhotoCaptureOverride: (() async throws -> Data)?
    var activeCameraCaptureCancel: (() -> Void)?
    var speechSpeakOverride: ((String, String?, @escaping () -> Void) -> Void)?
    var orientationObservationOverride: (() async throws -> OrientationObservation)?
    var hostCapabilityPendingSince: [String: Date] = [:]
    var closedPullSenseRequestIDs: Set<String> = []
    var terminalPullSenseRequestIDs: Set<String> = []
    var recentVisibleCoreEventSignatures: [String: Date] = [:]
    var logSearchTextCache: [LogEntry.ID: String] = [:]
    var coreAwaitingHostSenseMarker: CoreAwaitingHostSenseMarker?
    var hostPipelineActionStartedAt: Date?
    var lastHostPipelineProgressAt = Date()
    var pullSenseFulfillmentStartedAt: Date?
    var readModelsRefreshTask: Task<Void, Never>?
    var hostPipelineHealthTask: Task<Void, Never>?
    var hostPipelineHealthGeneration = 0
    var lastReportedDeadlockKind: HostPipelineDeadlockKind?
    var hostPipelineDeadlockDismissedID: UUID?
    @Published var hostPipelineDeadlock: HostPipelineDeadlock?
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
    @Published var autonomyControlBlockedReason = "none"
    @Published var appIsForeground = true
    var scenePhaseIsActive = true
    #if os(macOS)
    var macForegroundObservers: [any NSObjectProtocol] = []
    #endif

    init(
        brain: BrainDescriptor,
        brainCore: (any BrainCoreClient)? = nil,
        brainSpeechNotifications: (any BrainSpeechNotificationClient)? = nil
    ) {
        self.brain = brain
        self.brainCore = brainCore ?? BrainCore(brain: brain)
        self.brainSpeechNotifications = brainSpeechNotifications ?? SystemBrainSpeechNotificationService.shared
        let storedValues = Self.storedValuesForLaunch(brain: brain)
        brainVoiceEnabled = UserDefaults.standard.object(forKey: Self.brainVoiceEnabledKey) as? Bool ?? true
        autonomyMode = Self.normalizeAutonomyMode(storedValues["autonomy_mode"] ?? "play")
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
        refreshKnowledgeEntries()
        resetAvatarFacialExpression()
        #if os(macOS)
        macForegroundObservers.append(
            NotificationCenter.default.addObserver(
                forName: BrainLibrary.avatarDidUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak viewModel = self] notification in
                guard let viewModel,
                      let brainID = notification.userInfo?[BrainLibrary.avatarDidUpdateBrainIDKey] as? String else {
                    return
                }
                MainActor.assumeIsolated {
                    viewModel.handleAvatarDidUpdate(for: brainID)
                }
            }
        )
        #endif
    }

    func reloadBrain(_ updated: BrainDescriptor) {
        guard updated.id == brain.id else { return }
        brain = updated
        refreshKnowledgeEntries()
        resetAvatarFacialExpression()
    }

    deinit {
        boredomSenseTask?.cancel()
        autonomySenseTask?.cancel()
        hostPipelineHealthTask?.cancel()
        motionGestureMonitor?.stop()
        #if os(macOS)
        for observer in macForegroundObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    func setScenePhaseActive(_ active: Bool) {
        scenePhaseIsActive = active
        refreshAppIsForeground()
    }

    func refreshAppIsForeground() {
        appIsForeground = AppForegroundMonitor.isForeground(scenePhaseActive: scenePhaseIsActive)
    }

    #if os(macOS)
    func installMacForegroundObserversIfNeeded() {
        guard macForegroundObservers.isEmpty else { return }
        macForegroundObservers = AppForegroundMonitor.installMacActiveStateHandler { [weak self] _ in
            self?.refreshAppIsForeground()
        }
    }
    #endif

    func recordCoreLoadMetrics(_ report: CoreLoadMetricsReport) {
        lastCoreLoadMetrics = report
    }

    func markInitialCoreLoadAttempted() {
        hasAttemptedInitialCoreLoad = true
    }

    var workspaceBrainTitle: String {
        brainPresentationName ?? brain.displayName
    }

    var showsCoreConnectingScreen: Bool {
        if isDreamTimeInFlight { return true }
        guard !isBrainConnected else { return false }
        if hasAttemptedInitialCoreLoad { return false }
        return isBrainConnectionInFlight || !hasAttemptedInitialCoreLoad
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
        let filteredEntries = filtered(entries: eventEntries, query: eventSearchText, kind: selectedEventKind)
        switch developerEventSort {
        case .newestFirst:
            return filteredEntries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .oldestFirst:
            return filteredEntries.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    var inspectedEventEntry: LogEntry? {
        let entries = filteredEventEntries
        if let selectedEventEntryID,
           let selected = entries.first(where: { $0.id == selectedEventEntryID }) {
            return selected
        }
        return entries.first
    }

    var filteredKnowledgeEntries: [LogEntry] {
        let sessionEntries = eventEntries.filter(BrainKnowledgeReader.isKnowledgeRelated)
        let combined = deduplicatedKnowledgeEntries(storedKnowledgeEntries + sessionEntries)
        return filtered(entries: combined, query: knowledgeSearchText, kind: nil)
    }

    var inspectedKnowledgeEntry: LogEntry? {
        let entries = filteredKnowledgeEntries
        if let selectedKnowledgeEntryID,
           let selected = entries.first(where: { $0.id == selectedKnowledgeEntryID }) {
            return selected
        }
        return entries.first
    }

    func refreshKnowledgeEntries() {
        do {
            storedKnowledgeEntries = try BrainKnowledgeReader.loadEntries(from: brain)
        } catch {
            appendEventLog(
                kind: .error,
                title: "knowledge_load failed",
                body: error.localizedDescription,
                metadata: ["brain": brain.id, "memory_path": brain.memoryDatabaseURL.path]
            )
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

    func showAttentionSettings() {
        selectedSection = .settings
        selectedSettingsScope = .brain
        focusedSettingsGroupTitle = "Attention"
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

    var normalizedAutonomyMode: String {
        Self.normalizeAutonomyMode(autonomyMode)
    }

    var autonomyIsEnabled: Bool {
        normalizedAutonomyMode == "play"
    }

    var backgroundAgencyIsEnabled: Bool {
        autonomyIsEnabled
    }

    var attentionIsPaused: Bool {
        runtimeOptionStringValue(for: "autonomy_sleep") == "on"
    }

    var attentionIsInSleepHours: Bool {
        autonomyControlBlockedReason == "sleep" && !attentionIsPaused && isInConfiguredQuietHours()
    }

    func isInConfiguredQuietHours(now: Date = Date()) -> Bool {
        guard let range = runtimeOptionStringValue(for: "autonomy_quiet_hours") else { return false }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return Self.quietHoursRangeContains(range, minuteOfDay: minuteOfDay)
    }

    nonisolated static func quietHoursRangeContains(_ range: String, minuteOfDay: Int) -> Bool {
        let parts = range.split(separator: "-")
        guard parts.count == 2,
              let start = clockMinute(String(parts[0])),
              let end = clockMinute(String(parts[1])) else {
            return false
        }
        if start == end { return false }
        if start < end { return minuteOfDay >= start && minuteOfDay < end }
        return minuteOfDay >= start || minuteOfDay < end
    }

    nonisolated static func clockMinute(_ text: String) -> Int? {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard pieces.count == 2,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    var cameraCaptureIsEnabled: Bool {
        runtimeOptionStringValue(for: Self.cameraCaptureEnabledOptionKey) != "off"
    }

    var attentionStatusTitle: String {
        if attentionIsInSleepHours { return "Sleep hours" }
        if attentionIsPaused || autonomyControlBlockedReason == "sleep" { return "Resting" }
        if autonomyControlBlockedReason == "quiet_hours_bias" { return "Quiet" }
        if brainLoopPhase != nil || isAwaitingChatResponse { return "Thinking" }
        if hostPipelineHold != .none { return "Waiting" }
        if stimulusInboxPendingCount > 0 { return "Curious" }
        return "Active"
    }

    func autonomyStatusLine(at _: Date = Date()) -> String {
        if attentionIsInSleepHours {
            return "Sleep hours are active."
        }

        if attentionIsPaused || autonomyControlBlockedReason == "sleep" {
            return "Attention is resting."
        }

        if autonomyControlBlockedReason == "quiet_hours_bias" {
            return "Attention is quiet."
        }
        return "Attention is \(attentionStatusTitle.lowercased())."
    }

    func innerStateSummary(at date: Date = Date()) -> String {
        composedInnerStateSummary(at: date)
    }

    func composedInnerStateSummary(at date: Date = Date()) -> String {
        let autonomy = autonomyStatusLine(at: date)
        let parts = [autonomy, innerStateSummaryCore].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    func syncInnerStateSummary(at date: Date = Date()) {
        innerStateSummary = composedInnerStateSummary(at: date)
    }

    static func normalizeAutonomyMode(_ rawMode: String) -> String {
        switch rawMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pause", "paused", "off", "false", "0":
            return "pause"
        case "play", "playing", "full", "limited", "on", "true", "1":
            return "play"
        default:
            return "play"
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
        guard isBrainConnected, !isBrainConnectionInFlight else { return }
        enqueueHostPipelineAction(.collectMailbox)
    }

    func enterDreamOnLoadIfNeeded(
        now: Date = Date(),
        loadSession: CoreLoadPerformanceSession? = nil
    ) async {
        guard runtimeOptionStringValue(for: Self.makeUpLostDreamTimeOptionKey) == "on" else { return }
        guard !didCheckDreamOnLoad else { return }
        didCheckDreamOnLoad = true
        guard Self.shouldRequestDreamTimeFromMailbox(mailboxItems, now: now) else {
            appendEventLog(kind: .state, title: "dream load check", body: "Brain has dreamed in the past 24 hours.")
            return
        }

        appendEventLog(kind: .sent, title: "dream load check", body: "No mailbox dream found in the past 24 hours; requesting Dream Time.")
        isDreamTimeInFlight = true
        defer {
            isDreamTimeInFlight = false
            coreLoadProgressLabel = ""
            coreLoadProgressDetail = ""
            refreshUserSendAvailability()
        }

        brainMode = "dreaming"
        canSend = false
        statusText = brainModeStatusText
        do {
            let response: BrainMailboxResponse
            if let loadSession {
                response = try await loadSession.measure(
                    id: "request_dream_time",
                    label: "Running Dream Time",
                    detail: "Synthesizing mailbox dream"
                ) {
                    try await brainCore.requestDreamTime(prompt: nil)
                }
            } else {
                coreLoadProgressLabel = "Running Dream Time"
                coreLoadProgressDetail = "Synthesizing mailbox dream"
                response = try await brainCore.requestDreamTime(prompt: nil)
            }
            appendEventLog(
                kind: .result,
                title: "request_dream_time",
                body: response.item.title,
                metadata: response.metadata
            )
            await refreshBrainMode()
            await collectMailboxItems()
            refreshKnowledgeEntries()
            if !isBrainUnavailableForConversation {
                statusText = "Ready"
            } else {
                statusText = brainModeStatusText
            }
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
                    .resolvingArtifact(in: brain.memoryDatabaseURL, brainID: brain.id)
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
            enqueueHostPipelineAction(.mailboxMarkRead(itemID))
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

nonisolated enum HostPipelineHold: Equatable {
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

enum HostStimulusDelivery: Equatable {
    case hostNarration
    case counterpartSpeech(name: String?, source: LanguageInputSource = .typedText)

    var languageInputSource: LanguageInputSource {
        switch self {
        case .hostNarration:
            return .typedText
        case .counterpartSpeech(_, let source):
            return source
        }
    }
}

enum HostPipelineAction {
    case interrupt(userText: String, reason: String, interruptedAction: String?, canceledQueuedActionCount: Int)
    case typedText(text: String, stimulusContext: StimulusContext, delivery: HostStimulusDelivery = .counterpartSpeech(name: nil, source: .typedText))
    case imageText(prompt: String, attachment: [String: JSONValue], mediaPayload: String, stimulusContext: StimulusContext)
    case pullSenseRequest(BrainEvent, BrainEventPresentation)
    case coreTouch(name: String, title: String)
    case pokeSequence([PokePulse])
    case pushedMotionGesture(MotionGestureObservation)
    case boredomStimulus(text: String, stimulusContext: StimulusContext)
    case refreshBrainState
    case collectMailbox
    case mailboxMarkRead(String)
}

nonisolated enum StimulusContextPurpose: Equatable {
    case directUserStimulus
    case autonomyTick
}

nonisolated enum StimulusDeliveryState: String, Equatable {
    case pending
    case delivered
}

nonisolated struct StimulusRecord: Equatable {
    let id: Int
    let kind: String
    let sense: String?
    let source: String?
    let occurredAt: Date
    let summary: String
    let salience: Double
    let metadata: [String: String]
    let features: [String]
    let digestKey: String?
    let rawPayloadReference: String?
    let rawPayloadAvailable: Bool
    let processingState: String
    let receivedDuring: String
    let activeProcessGoal: String?
    let activeProcessState: String?
    let activeProcessStepName: String?
    var deliveryState: StimulusDeliveryState
}

typealias RecentStimulus = StimulusRecord

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

nonisolated struct SensePacketDigestItemSnapshot: Equatable {
    let sequenceIDs: [Int]
    let kind: String
    let count: Int
    let firstAgeSeconds: Double
    let lastAgeSeconds: Double
    let latestSummary: String
    let salience: Double
    let processingState: String
    let rawPayloadAvailable: Bool
    let rawPayloadReference: String?
    let metadata: [String: String]
    let features: [String]

    var eventArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "sequence_ids": .array(sequenceIDs.map { .number(Double($0)) }),
            "kind": .string(kind),
            "count": .number(Double(count)),
            "first_age_seconds": .number(firstAgeSeconds),
            "last_age_seconds": .number(lastAgeSeconds),
            "latest_summary": .string(latestSummary),
            "salience": .number(salience),
            "processing_state": .string(processingState),
            "raw_payload_available": .bool(rawPayloadAvailable),
            "metadata": .object(metadata.mapValues { .string($0) }),
            "features": .array(features.map { .string($0) }),
        ]
        if let rawPayloadReference {
            arguments["raw_payload_reference"] = .string(rawPayloadReference)
        }
        return arguments
    }
}

nonisolated struct SensePacketDigestSnapshot: Equatable {
    let windowSeconds: Double
    let totalItemCount: Int
    let coalescedItemCount: Int
    let highestSalience: Double
    let items: [SensePacketDigestItemSnapshot]

    var eventArguments: [String: JSONValue] {
        [
            "window_seconds": .number(windowSeconds),
            "total_item_count": .number(Double(totalItemCount)),
            "coalesced_item_count": .number(Double(coalescedItemCount)),
            "highest_salience": .number(highestSalience),
            "processing_policy": .string("capture_all_digest_selectively_promote"),
            "items": .array(items.map { .object($0.eventArguments) }),
        ]
    }
}

nonisolated struct SensePacketSnapshot: Equatable {
    let packetID: String
    let triggerKind: String
    let windowSeconds: Double
    let openedAt: Date
    let closedAt: Date
    let records: [RecentStimulusSnapshot]
    let digest: SensePacketDigestSnapshot?
    let inventory: [StimulusInventorySnapshot]

    var sequenceIDs: [Int] {
        records.map(\.id)
    }

    var eventArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "packet_id": .string(packetID),
            "trigger_kind": .string(triggerKind),
            "window_seconds": .number(windowSeconds),
            "opened_at_unix_ms": .number((openedAt.timeIntervalSince1970 * 1000).rounded()),
            "closed_at_unix_ms": .number((closedAt.timeIntervalSince1970 * 1000).rounded()),
            "record_count": .number(Double(records.count)),
            "records": .array(records.map { .object($0.eventArguments) }),
        ]
        if let digest {
            arguments["digest"] = .object(digest.eventArguments)
        }
        if !inventory.isEmpty {
            arguments["sense_inventory"] = .array(inventory.map { .object($0.eventArguments) })
        }
        return arguments
    }
}

struct StimulusInbox: Equatable {
    var records: [StimulusRecord] = []
    var inventory: [String: StimulusInventoryRecord] = [:]
    var nextSequence = 1
    var lastDeliveredAutonomySequence = 0

    var pendingCount: Int {
        records.filter { $0.deliveryState == .pending }.count
    }

    mutating func record(
        kind: String,
        summary: String,
        metadata: [String: String],
        context: StimulusRecordContext,
        now: Date = Date()
    ) -> StimulusRecord {
        pruneContinuityTail(now: now)
        let salience = Self.salience(from: metadata)
        let id = nextSequence
        nextSequence += 1
        let rawReference = Self.rawPayloadReference(from: metadata)
        let features = Self.features(kind: kind, metadata: metadata, rawPayloadReference: rawReference)
        let record = StimulusRecord(
            id: id,
            kind: kind,
            sense: metadata["sense"] ?? metadata["sense_kind"],
            source: metadata["source"],
            occurredAt: now,
            summary: summary,
            salience: salience,
            metadata: metadata,
            features: features,
            digestKey: Self.digestKey(kind: kind, metadata: metadata),
            rawPayloadReference: rawReference,
            rawPayloadAvailable: rawReference != nil || metadata["raw_payload_available"] == "true",
            processingState: Self.processingState(from: metadata, salience: salience),
            receivedDuring: context.receivedDuring,
            activeProcessGoal: context.activeProcessGoal,
            activeProcessState: context.activeProcessState,
            activeProcessStepName: context.activeProcessStepName,
            deliveryState: .pending
        )
        inventory[kind] = StimulusInventoryRecord(
            kind: kind,
            totalCount: (inventory[kind]?.totalCount ?? 0) + 1,
            lastOccurredAt: now,
            lastSummary: summary,
            lastMetadata: metadata
        )
        records.append(record)
        if records.count > AffectiveViewModel.recentStimulusLimit * 4 {
            records.removeFirst(records.count - AffectiveViewModel.recentStimulusLimit * 4)
        }
        return record
    }

    mutating func recentSnapshots(now: Date = Date()) -> [RecentStimulusSnapshot] {
        pruneContinuityTail(now: now)
        return recentRecords(now: now)
            .sorted { lhs, rhs in
                if lhs.salience == rhs.salience {
                    return lhs.occurredAt > rhs.occurredAt
                }
                return lhs.salience > rhs.salience
            }
            .map { stimulus in
                RecentStimulusSnapshot(
                    id: stimulus.id,
                    kind: stimulus.kind,
                    ageSeconds: max(0, now.timeIntervalSince(stimulus.occurredAt)),
                    summary: stimulus.summary,
                    salience: stimulus.salience,
                    metadata: stimulus.metadata
                )
            }
    }

    func inventorySummary(now: Date = Date()) -> [StimulusInventorySnapshot] {
        let recentCounts = Dictionary(grouping: recentRecords(now: now), by: \.kind).mapValues(\.count)
        return inventory.values
            .sorted { lhs, rhs in
                if lhs.lastOccurredAt == rhs.lastOccurredAt {
                    return lhs.kind < rhs.kind
                }
                return lhs.lastOccurredAt > rhs.lastOccurredAt
            }
            .map { record in
                StimulusInventorySnapshot(
                    kind: record.kind,
                    totalCount: record.totalCount,
                    recentCount: recentCounts[record.kind] ?? 0,
                    lastAgeSeconds: max(0, now.timeIntervalSince(record.lastOccurredAt)),
                    lastSummary: record.lastSummary,
                    lastMetadata: record.lastMetadata
                )
            }
    }

    func fullContext(now: Date = Date()) -> (
        recent: [RecentStimulusSnapshot],
        packet: SensePacketSnapshot?,
        inventory: [StimulusInventorySnapshot]
    ) {
        var copy = self
        return (
            recent: copy.recentSnapshots(now: now),
            packet: sensePacket(for: .directUserStimulus, triggerKind: "direct_user_stimulus", now: now),
            inventory: inventorySummary(now: now)
        )
    }

    func sensePacket(
        for purpose: StimulusContextPurpose,
        triggerKind: String,
        now: Date = Date()
    ) -> SensePacketSnapshot? {
        let packetRecords = recordsForPacket(purpose: purpose, now: now)
        guard !packetRecords.isEmpty else { return nil }
        let windowSeconds = packetWindowSeconds(for: purpose, records: packetRecords, now: now)
        let oldest = packetRecords.map(\.occurredAt).min() ?? now
        let recordSnapshots = packetRecords
            .sorted { lhs, rhs in
                if lhs.occurredAt == rhs.occurredAt {
                    return lhs.id < rhs.id
                }
                return lhs.occurredAt < rhs.occurredAt
            }
            .map { stimulus in
                RecentStimulusSnapshot(
                    id: stimulus.id,
                    kind: stimulus.kind,
                    ageSeconds: max(0, now.timeIntervalSince(stimulus.occurredAt)),
                    summary: stimulus.summary,
                    salience: stimulus.salience,
                    metadata: stimulus.metadata
                )
            }
        return SensePacketSnapshot(
            packetID: "\(triggerKind)-\(packetRecords.map(\.id).min() ?? 0)-\(packetRecords.map(\.id).max() ?? 0)",
            triggerKind: triggerKind,
            windowSeconds: windowSeconds,
            openedAt: oldest,
            closedAt: now,
            records: recordSnapshots,
            digest: digest(for: purpose, now: now),
            inventory: purpose == .autonomyTick ? [] : inventorySummary(now: now)
        )
    }

    mutating func markDelivered(sequenceIDs: [Int]) {
        guard !sequenceIDs.isEmpty else { return }
        let delivered = Set(sequenceIDs)
        for index in records.indices where delivered.contains(records[index].id) {
            records[index].deliveryState = .delivered
        }
        if let maxID = sequenceIDs.max() {
            lastDeliveredAutonomySequence = max(lastDeliveredAutonomySequence, maxID)
        }
    }

    private func digest(for purpose: StimulusContextPurpose, now: Date) -> SensePacketDigestSnapshot? {
        let candidates = recordsForPacket(purpose: purpose, now: now)
        let windowSeconds = packetWindowSeconds(for: purpose, records: candidates, now: now)
        guard !candidates.isEmpty else { return nil }

        let groups = Dictionary(grouping: candidates) { stimulus in
            stimulus.digestKey ?? stimulus.kind
        }
        let items = groups.values.map { group -> SensePacketDigestItemSnapshot in
            let sorted = group.sorted { $0.occurredAt < $1.occurredAt }
            let first = sorted.first!
            let latest = sorted.last!
            let maxSalience = sorted.map(\.salience).max() ?? latest.salience
            let rawReference = sorted.reversed().compactMap(\.rawPayloadReference).first
            let mergedMetadata = sorted.reduce(into: [String: String]()) { result, stimulus in
                result.merge(stimulus.metadata) { _, new in new }
            }
            let features = sorted.flatMap(\.features).uniqued()
            return SensePacketDigestItemSnapshot(
                sequenceIDs: sorted.map(\.id),
                kind: latest.kind,
                count: sorted.count,
                firstAgeSeconds: max(0, now.timeIntervalSince(first.occurredAt)),
                lastAgeSeconds: max(0, now.timeIntervalSince(latest.occurredAt)),
                latestSummary: Self.digestSummary(for: sorted),
                salience: maxSalience,
                processingState: Self.digestProcessingState(for: sorted, salience: maxSalience),
                rawPayloadAvailable: sorted.contains { $0.rawPayloadAvailable },
                rawPayloadReference: rawReference,
                metadata: mergedMetadata,
                features: features
            )
        }
        .sorted { lhs, rhs in
            if lhs.salience == rhs.salience {
                return lhs.lastAgeSeconds < rhs.lastAgeSeconds
            }
            return lhs.salience > rhs.salience
        }
        .prefix(AffectiveViewModel.sensePacketDigestItemLimit)

        let digestItems = Array(items)
        return SensePacketDigestSnapshot(
            windowSeconds: windowSeconds,
            totalItemCount: candidates.count,
            coalescedItemCount: groups.count,
            highestSalience: digestItems.map(\.salience).max() ?? 0,
            items: digestItems
        )
    }

    private func recentRecords(now: Date) -> [StimulusRecord] {
        records.filter { now.timeIntervalSince($0.occurredAt) <= AffectiveViewModel.recentStimulusRetentionSeconds }
    }

    private func recordsForPacket(purpose: StimulusContextPurpose, now: Date) -> [StimulusRecord] {
        switch purpose {
        case .directUserStimulus:
            let windowStart = now.addingTimeInterval(-AffectiveViewModel.sensePacketWindowSeconds)
            return records.filter { $0.occurredAt >= windowStart }
        case .autonomyTick:
            let pending = records.filter { $0.deliveryState == .pending || $0.id > lastDeliveredAutonomySequence }
            let continuityTail = records
                .filter { $0.deliveryState == .delivered }
                .sorted { $0.id > $1.id }
                .prefix(3)
            return Array((pending + continuityTail).uniquedByID())
        }
    }

    private func packetWindowSeconds(
        for purpose: StimulusContextPurpose,
        records: [StimulusRecord],
        now: Date
    ) -> Double {
        switch purpose {
        case .directUserStimulus:
            return AffectiveViewModel.sensePacketWindowSeconds
        case .autonomyTick:
            guard let oldest = records.map(\.occurredAt).min() else { return 0 }
            return max(0, now.timeIntervalSince(oldest))
        }
    }

    private mutating func pruneContinuityTail(now: Date) {
        let retained = records.filter {
            $0.deliveryState == .pending
                || now.timeIntervalSince($0.occurredAt) <= AffectiveViewModel.recentStimulusRetentionSeconds
        }
        records = retained
    }

    static func salience(from metadata: [String: String]) -> Double {
        guard let rawValue = metadata["salience"], let value = Double(rawValue) else {
            return 0.5
        }
        return min(max(value, 0), 1)
    }

    static func digestKey(kind: String, metadata: [String: String]) -> String {
        switch kind {
        case "short_touch", "long_touch":
            return "touch:\(kind)"
        case "poke_sequence":
            return "touch:poke_sequence"
        case "camera_observation":
            return "camera:\(metadata["source"] ?? "unknown")"
        case "orientation_observation":
            return "orientation:\(metadata["posture"] ?? metadata["source"] ?? "unknown")"
        case "motion_gesture":
            return "motion:\(metadata["gesture"] ?? "unknown")"
        default:
            return kind
        }
    }

    static func rawPayloadReference(from metadata: [String: String]) -> String? {
        metadata["image_path"]
            ?? metadata["media_path"]
            ?? metadata["file_path"]
            ?? metadata["raw_payload_ref"]
    }

    static func processingState(from metadata: [String: String], salience: Double) -> String {
        if let explicit = metadata["processing_state"], !explicit.isEmpty {
            return explicit
        }
        if salience >= 0.8 { return "promoted" }
        if salience >= 0.5 { return "summarized" }
        return "indexed"
    }

    static func digestProcessingState(for stimuli: [StimulusRecord], salience: Double) -> String {
        if stimuli.contains(where: { $0.processingState == "promoted" }) || salience >= 0.8 {
            return "promoted"
        }
        if stimuli.contains(where: { $0.processingState == "summarized" }) || stimuli.count > 1 {
            return "summarized"
        }
        return stimuli.last?.processingState ?? "indexed"
    }

    static func digestSummary(for stimuli: [StimulusRecord]) -> String {
        guard let latest = stimuli.last else { return "" }
        guard stimuli.count > 1 else { return latest.summary }
        return "\(stimuli.count)x \(latest.kind): \(latest.summary)"
    }

    static func features(kind: String, metadata: [String: String], rawPayloadReference: String?) -> [String] {
        var features = Set<String>()
        features.insert(kind)
        if rawPayloadReference != nil {
            features.insert("raw_payload_available")
        }
        if metadata["sense_direction"] == "push" {
            features.insert("pushed_sense_update")
        }
        switch kind {
        case "short_touch":
            features.formUnion(["physical_contact", "duration_short"])
        case "long_touch":
            features.formUnion(["physical_contact", "duration_long"])
        case "poke_sequence":
            features.formUnion(["physical_contact", "repeated_pattern"])
        case "camera_observation":
            features.formUnion(["visual_observation"])
        case "orientation_observation":
            features.formUnion(["orientation_observation"])
        case "motion_gesture":
            features.formUnion(["motion_observation"])
        case "boredom":
            features.formUnion(["idle_context", "scheduled_stimulus"])
        case "user_message", "user_interrupt_message", "user_media_message":
            features.formUnion(["user_language"])
        default:
            features.insert("context_update")
        }
        if metadata["active_process_goal"] != nil {
            features.insert("during_active_process")
        }
        return features.sorted()
    }
}

nonisolated struct StimulusRecordContext: Equatable {
    let receivedDuring: String
    let activeProcessGoal: String?
    let activeProcessState: String?
    let activeProcessStepName: String?
}

private extension Array where Element == StimulusRecord {
    func uniquedByID() -> [StimulusRecord] {
        var seen = Set<Int>()
        return filter { seen.insert($0.id).inserted }
    }
}

private extension Sequence where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
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
    let inboxPendingCount: Int
    let speechOutputActive: Bool
    let awaitingSocialResponse: Bool
    let socialTurnResponseWindowRemainingSeconds: Double
    let counterpartActive: Bool
    let counterpartActivityWindowRemainingSeconds: Double
    let activeProcessGoal: String?
    let activeProcessState: String?
    let activeProcessStepName: String?
    let recentStimuli: [RecentStimulusSnapshot]
    let sensePacket: SensePacketSnapshot?
    let senseInventory: [StimulusInventorySnapshot]
    let localTime: Date
    let conversationContext: ConversationContextSnapshot

    var eventArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "kind": .string(kind),
            "received_during": .string(receivedDuring),
            "queued_action_count": .number(Double(queuedActionCount)),
            "inbox_pending_count": .number(Double(inboxPendingCount)),
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
        if let sensePacket {
            arguments["sense_packet"] = .object(sensePacket.eventArguments)
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
        if let activeProcessGoal {
            arguments["active_process_goal"] = .string(activeProcessGoal)
        }
        if let activeProcessState {
            arguments["active_process_state"] = .string(activeProcessState)
        }
        if let activeProcessStepName {
            arguments["active_process_step"] = .string(activeProcessStepName)
        }
        return arguments
    }

    private static let localTimeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
