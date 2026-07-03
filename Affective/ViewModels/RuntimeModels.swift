//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation

enum ControlTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case events = "Events"
    case options = "Options"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .events: "terminal"
        case .options: "slider.horizontal.3"
        }
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case mailbox = "Mailbox"
    case developer = "Developer"
    case knowledge = "Knowledge"
    case stats = "Stats"
    case settings = "Settings"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .mailbox: "tray.full"
        case .developer: "terminal"
        case .knowledge: "books.vertical"
        case .stats: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .chat: "Chat"
        case .mailbox: "Daily reports"
        case .developer: "Events and actions"
        case .knowledge: "Memory and recall"
        case .stats: "Growth and notes"
        case .settings: "Brain and host options"
        }
    }
}

enum SettingsScope: String, CaseIterable, Identifiable {
    case brain = "Brain"
    case host = "Host"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .brain: "brain.head.profile"
        case .host: "desktopcomputer"
        }
    }
}

nonisolated enum LogKind: String, CaseIterable, Identifiable {
    case user = "user"
    case brain = "brain"
    case emote = "emote"
    case sent = "sent"
    case result = "result"
    case state = "state"
    case process = "process"
    case error = "error"

    var id: String { rawValue }
}

nonisolated struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let kind: LogKind
    let title: String
    let body: String
    let metadata: [String: String]
    let userReaction: String?
    let createdAt: Date

    nonisolated init(
        kind: LogKind,
        title: String,
        body: String,
        metadata: [String: String] = [:],
        userReaction: String? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.metadata = metadata
        self.userReaction = userReaction
        self.createdAt = createdAt
    }
}

enum DeveloperEventSort: String, CaseIterable, Identifiable {
    case newestFirst = "Newest first"
    case oldestFirst = "Oldest first"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .newestFirst: "arrow.down"
        case .oldestFirst: "arrow.up"
        }
    }
}

enum CredentialTestStatus: Equatable {
    case testing
    case valid
    case invalid(String)

    var isTesting: Bool {
        if case .testing = self {
            return true
        }
        return false
    }
}

enum CredentialTestError: LocalizedError {
    case missingCredential(String)
    case invalidResponse(String)
    case rejected(String, Int, String?)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            return "Add or store a \(provider) key before testing."
        case .invalidResponse(let provider):
            return "\(provider) returned an unreadable validation response."
        case .rejected(let provider, let statusCode, let message):
            let detail = message.map { ": \($0)" } ?? "."
            return "\(provider) rejected the key with HTTP \(statusCode)\(detail)"
        }
    }
}

enum ProviderCredentialTester {
    static func test(key: ProviderCredentialKey, credential: String) async throws {
        var request = request(for: key, credential: credential)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CredentialTestError.invalidResponse(key.displayName)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw CredentialTestError.rejected(
                key.displayName,
                httpResponse.statusCode,
                providerErrorMessage(from: data)
            )
        }
    }

    static func providerErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return normalizedErrorMessage(message)
            }
            if let message = object["error"] as? String {
                return normalizedErrorMessage(message)
            }
            if let message = object["message"] as? String {
                return normalizedErrorMessage(message)
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return normalizedErrorMessage(text)
    }

    private static func normalizedErrorMessage(_ message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(240))
    }

    static func request(for key: ProviderCredentialKey, credential: String) -> URLRequest {
        switch key {
        case .openAI:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            return request
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        case .google:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: credential)]
            return URLRequest(url: components.url!)
        case .deepseek:
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/models")!)
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            return request
        }
    }
}

struct RuntimeOptionGroup: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let note: String
    var scope: SettingsScope = .brain
    var isExpanded: Bool
    var options: [RuntimeOption]

    static let defaults: [RuntimeOptionGroup] = [
        .init(title: "Quick Controls", note: "Most likely to change while Affective is running.", isExpanded: true, options: [
            .select(key: "psyche_mode", label: "Psyche", value: "on", choices: ["off", "on"]),
            .select(key: "speech_voice", label: "Speech voice", value: defaultSpeechVoiceName, choices: speechVoiceChoices),
            .number(key: "conversation_idle_timeout_seconds", label: "Conversation idle timeout", value: "120", unit: "sec"),
            .number(key: "boredom_interval_seconds", label: "Boredom interval max", value: "600", unit: "sec"),
        ]),
        .init(title: "Tuning", note: "Recognition and reasoning knobs.", isExpanded: true, options: [
            .select(
                key: AffectiveViewModel.llmQualityOptionKey,
                label: "LLM quality",
                value: "auto",
                choices: [
                    RuntimeOptionChoice(value: "frugal", label: "Frugal"),
                    RuntimeOptionChoice(value: "auto", label: "Decide for me"),
                    RuntimeOptionChoice(value: "best", label: "Best"),
                ],
                requiresRestart: true
            ),
            .number(key: "known_threshold", label: "Known face threshold", value: "0.85"),
            .number(key: "uncertain_threshold", label: "Uncertain face threshold", value: "0.60"),
            .select(key: "make_up_lost_dream_time", label: "Make up for lost dream time", value: "off", choices: ["off", "on"]),
        ]),
        .init(title: "Attention", note: "Background attention, rest, social appetite, and agency.", isExpanded: true, options: [
            .number(key: "autonomy_interval_seconds", label: "Attention tick interval", value: "300", unit: "sec"),
            .number(key: "autonomy_engaged_interval_seconds", label: "Engaged tick interval", value: "60", unit: "sec"),
            .number(key: "autonomy_engagement_decay_seconds", label: "Engagement decay", value: "600", unit: "sec"),
            .select(key: "autonomy_sleep", label: "Start resting", value: "off", choices: ["off", "on"]),
            .timeRange(key: "autonomy_quiet_hours", label: "Quiet hours", value: "22:00-08:00"),
            .number(key: "autonomy_social_engagement_boost", label: "Mutual contact reward", value: "3", unit: "points"),
            .number(key: "autonomy_limited_threshold_bias", label: "Quiet threshold bias", value: "0.20"),
            .number(key: "autonomy_full_threshold_bias", label: "Background threshold bias", value: "0.00"),
            .number(key: "autonomy_social_reserve", label: "Social appetite reserve", value: "0.12"),
            .number(key: "autonomy_safety_reserve", label: "Safety reserve", value: "0.20"),
            .number(key: "autonomy_opportunity_reserve", label: "Curiosity reserve", value: "0.15"),
        ]),
        .init(title: "Biometric Privacy", note: "Local face-template controls for this brain. Owner-managed consent is required before use.", isExpanded: true, options: [
            .select(
                key: BiometricPolicyKeys.recognitionEnabled,
                label: "Enable biometric recognition",
                value: "off",
                choices: [RuntimeOptionChoice(value: "off", label: "Off"), RuntimeOptionChoice(value: "on", label: "On")],
                requiresRestart: true
            ),
            .select(
                key: BiometricPolicyKeys.policyAcknowledged,
                label: "Biometric policy acknowledged",
                value: "off",
                choices: [RuntimeOptionChoice(value: "off", label: "Not acknowledged"), RuntimeOptionChoice(value: "on", label: "Acknowledged")],
                requiresRestart: true
            ),
            .select(
                key: BiometricPolicyKeys.enrollmentAllowed,
                label: "Allow new enrollments",
                value: "off",
                choices: [RuntimeOptionChoice(value: "off", label: "Off"), RuntimeOptionChoice(value: "on", label: "On")],
                requiresRestart: true
            ),
            .select(
                key: BiometricPolicyKeys.retentionPeriod,
                label: "Retention period",
                value: BiometricDataPolicy.defaultRetentionPeriod,
                choices: [
                    RuntimeOptionChoice(value: "until_deleted", label: "Until deleted"),
                    RuntimeOptionChoice(value: "30_days", label: "30 days"),
                    RuntimeOptionChoice(value: "1_year", label: "1 year"),
                    RuntimeOptionChoice(value: "3_years", label: "3 years"),
                    RuntimeOptionChoice(value: "delete_when_not_seen", label: "Delete when not seen"),
                ]
            ),
            .select(
                key: BiometricPolicyKeys.exportIncluded,
                label: "Include biometrics in export and iCloud upload",
                value: "off",
                choices: [RuntimeOptionChoice(value: "off", label: "Off"), RuntimeOptionChoice(value: "on", label: "On")]
            ),
            .select(
                key: BiometricPolicyKeys.exportConfirmationRequired,
                label: "Require confirmation before export",
                value: "on",
                choices: [RuntimeOptionChoice(value: "on", label: "On"), RuntimeOptionChoice(value: "off", label: "Off")]
            ),
            .select(
                key: BiometricPolicyKeys.autoDeleteUnconfirmed,
                label: "Auto-delete unconfirmed templates",
                value: "on",
                choices: [RuntimeOptionChoice(value: "on", label: "On"), RuntimeOptionChoice(value: "off", label: "Off")]
            ),
        ]),
        .init(title: "Recognition Files", note: "Host-managed biometric cache location.", isExpanded: false, options: [
            .text(key: "face_embeddings_dir", label: "Face embeddings directory", value: "~/Library/Application Support/Affective/brains/default/memory/face_embeddings", requiresRestart: true),
        ]),
        .init(title: "API Accounts", note: "Host credentials used for model calls made with the user's accounts.", scope: .host, isExpanded: true, options: [
            .select(
                key: AffectiveViewModel.textProviderPreferenceOptionKey,
                label: "Text provider",
                value: HostTextProviderPreference.random.rawValue,
                choices: HostTextProviderPreference.selectableCases.map {
                    RuntimeOptionChoice(value: $0.rawValue, label: $0.displayName)
                },
                requiresRestart: true
            ),
            .text(key: "openai_api_key", label: "OpenAI API key", value: ""),
            .text(key: "anthropic_api_key", label: "Anthropic API key", value: ""),
            .text(key: "google_api_key", label: "Google API key", value: ""),
            .text(key: "deepseek_api_key", label: "DeepSeek API key", value: ""),
        ]),
        .init(title: "Host Senses", note: "Local devices used when the brain asks the host for sensory input.", scope: .host, isExpanded: true, options: [
            .select(
                key: AffectiveViewModel.cameraCaptureEnabledOptionKey,
                label: "Camera capture",
                value: "on",
                choices: ["on", "off"]
            ),
            .select(key: "camera_device_id", label: "Camera input", value: "automatic", choices: ["automatic"]),
            .select(
                key: AffectiveViewModel.motionGestureEnabledOptionKey,
                label: "Motion gestures",
                value: "off",
                choices: ["off", "on"],
                requiresRestart: true
            ),
        ]),
    ]

    static var speechVoiceChoices: [String] {
        AppleSpeechVoiceCatalog.names
    }

    static var defaultSpeechVoiceName: String {
        AppleSpeechVoiceCatalog.defaultVoiceName
    }
}

struct RuntimeOptionChoice: Identifiable, Equatable, Hashable {
    let value: String
    let label: String

    var id: String { value }
}

struct RuntimeOption: Identifiable, Equatable {
    enum FieldKind: Equatable {
        case text
        case number
        case timeRange
        case select([RuntimeOptionChoice])
    }

    let id = UUID()
    let key: String
    let label: String
    var value: String
    var committedValue: String
    var kind: FieldKind
    var unit: String?
    var requiresRestart: Bool
    var isReadOnly: Bool
    var hasStoredSecret: Bool
    var shouldDeleteSecret: Bool

    var isSecret: Bool {
        ProviderCredentialKey(rawValue: key) != nil
    }

    var isDirty: Bool {
        if isSecret {
            return shouldDeleteSecret || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return value != committedValue
    }

    var logValue: String {
        isSecret ? (shouldDeleteSecret ? "<deleted from Keychain>" : "<stored in Keychain>") : value
    }

    var jsonValue: Any {
        if BiometricPolicyKeys.booleanOptionKeys.contains(key) {
            return value == "on"
        }
        switch kind {
        case .number:
            if value.contains(".") {
                return Double(value) ?? 0
            }
            return Int(value) ?? 0
        case .text, .timeRange, .select:
            return value
        }
    }

    mutating func commit() {
        if isSecret {
            let storedReplacement = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            hasStoredSecret = shouldDeleteSecret ? false : (hasStoredSecret || storedReplacement)
            shouldDeleteSecret = false
            value = ""
        }
        committedValue = value
    }

    static func text(key: String, label: String, value: String, requiresRestart: Bool = false, isReadOnly: Bool = false) -> RuntimeOption {
        .init(key: key, label: label, value: value, committedValue: value, kind: .text, unit: nil, requiresRestart: requiresRestart, isReadOnly: isReadOnly, hasStoredSecret: false, shouldDeleteSecret: false)
    }

    static func number(key: String, label: String, value: String, unit: String? = nil, requiresRestart: Bool = false, isReadOnly: Bool = false) -> RuntimeOption {
        .init(key: key, label: label, value: value, committedValue: value, kind: .number, unit: unit, requiresRestart: requiresRestart, isReadOnly: isReadOnly, hasStoredSecret: false, shouldDeleteSecret: false)
    }

    static func timeRange(key: String, label: String, value: String, requiresRestart: Bool = false, isReadOnly: Bool = false) -> RuntimeOption {
        .init(key: key, label: label, value: value, committedValue: value, kind: .timeRange, unit: nil, requiresRestart: requiresRestart, isReadOnly: isReadOnly, hasStoredSecret: false, shouldDeleteSecret: false)
    }

    static func select(key: String, label: String, value: String, choices: [String], requiresRestart: Bool = false, isReadOnly: Bool = false) -> RuntimeOption {
        select(
            key: key,
            label: label,
            value: value,
            choices: choices.map { RuntimeOptionChoice(value: $0, label: $0.optionDisplayName) },
            requiresRestart: requiresRestart,
            isReadOnly: isReadOnly
        )
    }

    static func select(key: String, label: String, value: String, choices: [RuntimeOptionChoice], requiresRestart: Bool = false, isReadOnly: Bool = false) -> RuntimeOption {
        .init(key: key, label: label, value: value, committedValue: value, kind: .select(choices), unit: nil, requiresRestart: requiresRestart, isReadOnly: isReadOnly, hasStoredSecret: false, shouldDeleteSecret: false)
    }
}

extension BiometricPolicyKeys {
    static let booleanOptionKeys: Set<String> = [
        recognitionEnabled,
        policyAcknowledged,
        enrollmentAllowed,
        exportIncluded,
        exportConfirmationRequired,
        autoDeleteUnconfirmed,
    ]
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Host pipeline deadlock detection

nonisolated enum HostPipelineDeadlockKind: String, Equatable, Sendable {
    case coreAwaitingSenseWithoutHostWork
    case pipelineActionTimedOut
    case queuedConversationNotDraining
    case pullSenseFulfillmentTimedOut
}

nonisolated struct CoreAwaitingHostSenseMarker: Equatable, Sendable {
    let since: Date
    let sense: String?
    let purpose: String?
    let timeoutMS: Int?
    let requestID: String?
}

nonisolated struct HostPipelineDeadlock: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: HostPipelineDeadlockKind
    let title: String
    let detail: String
    let detectedAt: Date
    let diagnostics: [String: String]

    init(
        id: UUID = UUID(),
        kind: HostPipelineDeadlockKind,
        title: String,
        detail: String,
        detectedAt: Date,
        diagnostics: [String: String]
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.detectedAt = detectedAt
        self.diagnostics = diagnostics
    }

    var stalledSeconds: TimeInterval {
        Date().timeIntervalSince(detectedAt)
    }

    var sortedDiagnostics: [(key: String, value: String)] {
        diagnostics
            .map { (key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}

nonisolated struct HostPipelineHealthInput: Equatable, Sendable {
    let now: Date
    let isBrainConnected: Bool
    let coreAwaitingHostSense: CoreAwaitingHostSenseMarker?
    let isHostPipelineRunning: Bool
    let hostPipelineActionStartedAt: Date?
    let hostPipelineActionKind: String?
    let hostPipelineHold: HostPipelineHold
    let queuedConversationActionCount: Int
    let lastHostPipelineProgressAt: Date
    let activePullSenseFulfillmentCount: Int
    let pullSenseFulfillmentStartedAt: Date?
    let pendingCameraRequestID: String?
    let pendingOrientationRequestID: String?
    let hasPullSenseInQueue: Bool
    let isToolRunning: Bool
}

nonisolated enum CoreEventApplicationContext: Equatable, Sendable {
    case dispatchResponse(operation: String, requestID: String?)
    case eventSink
    case senseObservation(requestID: String?)
    case diagnosticStatus

    var sourceLane: String {
        switch self {
        case .dispatchResponse:
            return "conversation"
        case .eventSink:
            return "event_sink"
        case .senseObservation:
            return "sense"
        case .diagnosticStatus:
            return "diagnostic"
        }
    }

    var allowsHostRequests: Bool {
        switch self {
        case .dispatchResponse, .eventSink:
            return true
        case .senseObservation, .diagnosticStatus:
            return false
        }
    }

    var allowsHostStatusRequests: Bool {
        switch self {
        case .dispatchResponse, .diagnosticStatus:
            return true
        case .eventSink, .senseObservation:
            return false
        }
    }

    var operationName: String {
        switch self {
        case .dispatchResponse(let operation, _):
            return operation
        case .eventSink:
            return "event_sink"
        case .senseObservation:
            return "sense_observation"
        case .diagnosticStatus:
            return "diagnostic_status"
        }
    }

    var requestID: String? {
        switch self {
        case .dispatchResponse(_, let requestID), .senseObservation(let requestID):
            return requestID
        case .eventSink, .diagnosticStatus:
            return nil
        }
    }
}

enum HostPipelineHealthEvaluator {
    static let queuedConversationGraceSeconds: TimeInterval = 10
    static let defaultPipelineActionTimeoutSeconds: TimeInterval = 90
    static let conversationPipelineActionTimeoutSeconds: TimeInterval = 180
    static let coreTouchPipelineActionTimeoutSeconds: TimeInterval = 120
    static let pullSenseExtraGraceSeconds: TimeInterval = 12
    static let minimumPullSenseTimeoutSeconds: TimeInterval = 30

    static func evaluate(_ input: HostPipelineHealthInput) -> HostPipelineDeadlock? {
        guard input.isBrainConnected else { return nil }

        if let deadlock = coreAwaitingSenseDeadlock(input) {
            return deadlock
        }
        if let deadlock = pipelineActionDeadlock(input) {
            return deadlock
        }
        if let deadlock = queuedConversationDeadlock(input) {
            return deadlock
        }
        if let deadlock = pullSenseFulfillmentDeadlock(input) {
            return deadlock
        }
        return nil
    }

    static func coreAwaitingSenseDeadlock(_ input: HostPipelineHealthInput) -> HostPipelineDeadlock? {
        guard let marker = input.coreAwaitingHostSense else { return nil }
        let timeoutSeconds = max(8, Double(marker.timeoutMS ?? 8_000) / 1_000)
        let grace = timeoutSeconds + 5
        let elapsed = input.now.timeIntervalSince(marker.since)
        guard elapsed > grace else { return nil }
        guard !hostIsWorkingOnSense(marker.sense, input: input) else { return nil }

        var diagnostics: [String: String] = [
            "stalled_seconds": String(format: "%.0f", elapsed),
            "awaited_sense": marker.sense ?? "unknown",
            "host_pipeline_running": String(input.isHostPipelineRunning),
            "queued_conversation_actions": "\(input.queuedConversationActionCount)",
            "active_pull_sense_fulfillments": "\(input.activePullSenseFulfillmentCount)",
            "pending_camera_request_id": input.pendingCameraRequestID ?? "none",
            "host_pipeline_hold": String(describing: input.hostPipelineHold),
        ]
        if let purpose = marker.purpose, !purpose.isEmpty {
            diagnostics["awaited_purpose"] = purpose
        }
        if let requestID = marker.requestID, !requestID.isEmpty {
            diagnostics["request_id"] = requestID
        }
        if let actionKind = input.hostPipelineActionKind, !actionKind.isEmpty {
            diagnostics["current_pipeline_action"] = actionKind
        }

        let senseLabel = marker.sense ?? "host sense"
        let purposeSuffix = marker.purpose.map { " (\($0))" } ?? ""
        return HostPipelineDeadlock(
            kind: .coreAwaitingSenseWithoutHostWork,
            title: "Brain is waiting for \(senseLabel)\(purposeSuffix)",
            detail: "The core paused for \(senseLabel), but the host is not fulfilling that sense request.",
            detectedAt: input.now,
            diagnostics: diagnostics
        )
    }

    static func pipelineActionDeadlock(_ input: HostPipelineHealthInput) -> HostPipelineDeadlock? {
        guard input.isHostPipelineRunning,
              let startedAt = input.hostPipelineActionStartedAt else {
            return nil
        }
        let limit = pipelineActionTimeoutSeconds(for: input.hostPipelineActionKind)
        let elapsed = input.now.timeIntervalSince(startedAt)
        guard elapsed > limit else { return nil }

        let actionLabel = input.hostPipelineActionKind ?? "unknown"
        return HostPipelineDeadlock(
            kind: .pipelineActionTimedOut,
            title: "Host pipeline action timed out",
            detail: "The host has been running \(actionLabel) for \(Int(elapsed))s without finishing.",
            detectedAt: input.now,
            diagnostics: [
                "stalled_seconds": String(format: "%.0f", elapsed),
                "timeout_seconds": String(format: "%.0f", limit),
                "current_pipeline_action": actionLabel,
                "host_pipeline_hold": String(describing: input.hostPipelineHold),
                "queued_conversation_actions": "\(input.queuedConversationActionCount)",
                "is_tool_running": String(input.isToolRunning),
            ]
        )
    }

    static func queuedConversationDeadlock(_ input: HostPipelineHealthInput) -> HostPipelineDeadlock? {
        guard input.queuedConversationActionCount > 0,
              !input.isHostPipelineRunning,
              input.hostPipelineHold == .none,
              !input.isToolRunning else {
            return nil
        }
        let elapsed = input.now.timeIntervalSince(input.lastHostPipelineProgressAt)
        guard elapsed > queuedConversationGraceSeconds else { return nil }

        return HostPipelineDeadlock(
            kind: .queuedConversationNotDraining,
            title: "Queued messages are not sending",
            detail: "\(input.queuedConversationActionCount) conversation action(s) are queued, but the host pipeline is idle.",
            detectedAt: input.now,
            diagnostics: [
                "stalled_seconds": String(format: "%.0f", elapsed),
                "queued_conversation_actions": "\(input.queuedConversationActionCount)",
                "host_pipeline_running": String(input.isHostPipelineRunning),
                "host_pipeline_hold": String(describing: input.hostPipelineHold),
                "is_tool_running": String(input.isToolRunning),
                "active_pull_sense_fulfillments": "\(input.activePullSenseFulfillmentCount)",
            ]
        )
    }

    static func pullSenseFulfillmentDeadlock(_ input: HostPipelineHealthInput) -> HostPipelineDeadlock? {
        guard input.activePullSenseFulfillmentCount > 0,
              let startedAt = input.pullSenseFulfillmentStartedAt else {
            return nil
        }
        guard hasConcretePullSenseWork(input) else {
            return nil
        }
        let senseTimeout = Double(input.coreAwaitingHostSense?.timeoutMS ?? 8_000) / 1_000
        let limit = max(minimumPullSenseTimeoutSeconds, senseTimeout + pullSenseExtraGraceSeconds)
        let elapsed = input.now.timeIntervalSince(startedAt)
        guard elapsed > limit else { return nil }

        return HostPipelineDeadlock(
            kind: .pullSenseFulfillmentTimedOut,
            title: "Pull sense fulfillment timed out",
            detail: "A host sense request has been in flight for \(Int(elapsed))s without completing.",
            detectedAt: input.now,
            diagnostics: [
                "stalled_seconds": String(format: "%.0f", elapsed),
                "timeout_seconds": String(format: "%.0f", limit),
                "pending_camera_request_id": input.pendingCameraRequestID ?? "none",
                "pending_orientation_request_id": input.pendingOrientationRequestID ?? "none",
                "host_pipeline_hold": String(describing: input.hostPipelineHold),
                "awaited_sense": input.coreAwaitingHostSense?.sense ?? "unknown",
            ]
        )
    }

    static func hasConcretePullSenseWork(_ input: HostPipelineHealthInput) -> Bool {
        if let sense = input.coreAwaitingHostSense?.sense?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sense.isEmpty,
           sense != "unknown" {
            return true
        }
        if input.pendingCameraRequestID != nil || input.pendingOrientationRequestID != nil {
            return true
        }
        if input.hasPullSenseInQueue {
            return true
        }
        if let actionKind = input.hostPipelineActionKind,
           actionKind.hasPrefix("pull_sense:"),
           actionKind != "pull_sense:unknown" {
            return true
        }
        switch input.hostPipelineHold {
        case .cameraPermission, .orientationPermission, .cameraCapture:
            return true
        case .none, .speechOutput:
            return false
        }
    }

    static func hostIsWorkingOnSense(_ sense: String?, input: HostPipelineHealthInput) -> Bool {
        if input.activePullSenseFulfillmentCount > 0 { return true }
        if input.hasPullSenseInQueue { return true }
        if input.isHostPipelineRunning,
           let actionKind = input.hostPipelineActionKind,
           actionKind.hasPrefix("pull_sense:") {
            return true
        }

        switch input.hostPipelineHold {
        case .cameraPermission:
            if sense == nil || sense == "camera" { return true }
        case .orientationPermission:
            if sense == nil || sense == "orientation" { return true }
        case .none, .cameraCapture, .speechOutput:
            break
        }

        if sense == nil || sense == "camera", input.pendingCameraRequestID != nil {
            return true
        }
        if sense == nil || sense == "orientation", input.pendingOrientationRequestID != nil {
            return true
        }
        return false
    }

    static func pipelineActionTimeoutSeconds(for actionKind: String?) -> TimeInterval {
        guard let actionKind, !actionKind.isEmpty else {
            return defaultPipelineActionTimeoutSeconds
        }
        if actionKind.hasPrefix("pull_sense:") {
            return minimumPullSenseTimeoutSeconds + pullSenseExtraGraceSeconds
        }
        switch actionKind {
        case "experience:counterpart_speech", "image_text", "experience:interrupt":
            return conversationPipelineActionTimeoutSeconds
        case "short_touch", "long_touch", "experience:poke_sequence":
            return coreTouchPipelineActionTimeoutSeconds
        default:
            return defaultPipelineActionTimeoutSeconds
        }
    }
}
