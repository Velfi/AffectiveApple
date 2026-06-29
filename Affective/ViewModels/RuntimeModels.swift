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
        .init(title: "Autonomy", note: "Self-directed action budget, replenishment, and scheduling.", isExpanded: true, options: [
            .select(
                key: "autonomy_mode",
                label: "Autonomy mode",
                value: "off",
                choices: [
                    RuntimeOptionChoice(value: "off", label: "Off"),
                    RuntimeOptionChoice(value: "limited", label: "Limited"),
                    RuntimeOptionChoice(value: "full", label: "Full"),
                ]
            ),
            .number(key: "autonomy_interval_seconds", label: "Autonomy tick interval", value: "300", unit: "sec"),
            .select(key: "autonomy_sleep", label: "Start asleep", value: "off", choices: ["off", "on"]),
            .timeRange(key: "autonomy_quiet_hours", label: "Quiet hours", value: "22:00-08:00"),
            .number(key: "autonomy_limited_max_capacity", label: "Limited max capacity", value: "25", unit: "points"),
            .number(key: "autonomy_full_max_capacity", label: "Full max capacity", value: "50", unit: "points"),
            .number(key: "autonomy_limited_replenish_actions_per_minute", label: "Limited replenish rate", value: "2.0", unit: "points/min"),
            .number(key: "autonomy_full_replenish_actions_per_minute", label: "Full replenish rate", value: "8.0", unit: "points/min"),
            .number(key: "autonomy_social_engagement_boost", label: "User-turn engagement boost", value: "3", unit: "points"),
            .number(key: "autonomy_limited_threshold_bias", label: "Limited threshold bias", value: "0.20"),
            .number(key: "autonomy_full_threshold_bias", label: "Full threshold bias", value: "0.00"),
            .number(key: "autonomy_social_reserve", label: "Social reserve", value: "0.12"),
            .number(key: "autonomy_safety_reserve", label: "Safety reserve", value: "0.20"),
            .number(key: "autonomy_opportunity_reserve", label: "Opportunity reserve", value: "0.15"),
            .number(key: AffectiveViewModel.autonomyBudgetOptionKey, label: "Extra action budget", value: "0", unit: "points"),
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
        let choices = speechVoiceChoices
        return choices.first { $0.localizedCaseInsensitiveCompare("Fred") == .orderedSame }
            ?? choices.first
            ?? "System Voice"
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
