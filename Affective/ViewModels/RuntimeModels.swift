//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation

enum ControlTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case commands = "Commands"
    case options = "Options"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .commands: "terminal"
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
        case .developer: "Commands and actions"
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

enum LogKind: String, CaseIterable, Identifiable {
    case user = "user"
    case brain = "brain"
    case sent = "sent"
    case result = "result"
    case state = "state"
    case error = "error"

    var id: String { rawValue }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let kind: LogKind
    let title: String
    let body: String
    let metadata: [String: String]
    let createdAt = Date()
}

struct CoreToolAction: Identifiable, Equatable {
    let id: String
    let title: String
    let toolName: String
    let symbolName: String
    let arguments: [String: JSONValue]
    let mirrorToChat: Bool

    static let primary: [CoreToolAction] = [
        .init(id: "brain-inspect", title: "Inspect", toolName: "brain_inspect", symbolName: "brain.head.profile", arguments: [:], mirrorToChat: false),
        .init(id: "memory-index", title: "Memory Index", toolName: "memory_index", symbolName: "archivebox", arguments: [:], mirrorToChat: false),
        .init(id: "attention", title: "Attention", toolName: "choose_attention", symbolName: "scope", arguments: [:], mirrorToChat: true),
        .init(id: "consolidate", title: "Consolidate", toolName: "consolidate_memory", symbolName: "square.stack.3d.up", arguments: [:], mirrorToChat: false),
        .init(id: "dream", title: "Dream", toolName: "dream", symbolName: "moon.stars", arguments: [:], mirrorToChat: true),
        .init(id: "forget-today", title: "Forget Today", toolName: "__host_forget_today", symbolName: "calendar.badge.minus", arguments: [:], mirrorToChat: false),
    ]
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
    case rejected(String, Int)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            return "Add or store a \(provider) key before testing."
        case .invalidResponse(let provider):
            return "\(provider) returned an unreadable validation response."
        case .rejected(let provider, let statusCode):
            return "\(provider) rejected the key with HTTP \(statusCode)."
        }
    }
}

enum ProviderCredentialTester {
    static func test(key: ProviderCredentialKey, credential: String) async throws {
        var request = request(for: key, credential: credential)
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CredentialTestError.invalidResponse(key.displayName)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw CredentialTestError.rejected(key.displayName, httpResponse.statusCode)
        }
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
            .select(key: "recognition_mode", label: "Recognition", value: "auto", choices: ["auto", "command", "descriptive"]),
            .select(key: "psyche_mode", label: "Psyche", value: "on", choices: ["off", "on"]),
            .select(key: "speech_voice", label: "Speech voice", value: defaultSpeechVoiceName, choices: speechVoiceChoices),
            .number(key: "conversation_idle_timeout_seconds", label: "Conversation idle timeout", value: "120", unit: "sec"),
            .number(key: "boredom_interval_seconds", label: "Boredom interval", value: "600", unit: "sec"),
        ]),
        .init(title: "Tuning", note: "Recognition, autonomy, and reasoning knobs.", isExpanded: true, options: [
            .number(key: "known_threshold", label: "Known face threshold", value: "0.85"),
            .number(key: "uncertain_threshold", label: "Uncertain face threshold", value: "0.60"),
            .number(key: "autonomy_interval_seconds", label: "Autonomy interval", value: "300", unit: "sec"),
            .select(key: "autonomy_sleep", label: "Sleep during quiet hours", value: "off", choices: ["off", "on"]),
            .timeRange(key: "autonomy_quiet_hours", label: "Quiet hours", value: "22:00-08:00"),
            .number(key: "autonomy_daily_energy", label: "Daily autonomy budget", value: "20", unit: "actions"),
            .select(key: "make_up_lost_dream_time", label: "Make up for lost dream time", value: "off", choices: ["off", "on"]),
        ]),
        .init(title: "Recognition Files", note: "Live paths used by command recognition.", isExpanded: false, options: [
            .text(key: "recognition_command", label: "Recognition command", value: "tools/affective-face-recognizer", requiresRestart: true),
            .text(key: "face_detector_model", label: "Face detector model", value: "models/face_detection_yunet_2023mar_int8.onnx", requiresRestart: true),
            .text(key: "face_recognition_model", label: "Face recognition model", value: "models/face_recognition_sface_2021dec_int8.onnx", requiresRestart: true),
            .text(key: "face_embeddings_dir", label: "Face embeddings directory", value: "~/Library/Application Support/Affective/brains/default/memory/face_embeddings", requiresRestart: true),
        ]),
        .init(title: "API Accounts", note: "Host credentials used for model calls made with the user's accounts.", scope: .host, isExpanded: true, options: [
            .text(key: "openai_api_key", label: "OpenAI API key", value: ""),
            .text(key: "anthropic_api_key", label: "Anthropic API key", value: ""),
            .text(key: "google_api_key", label: "Google API key", value: ""),
        ]),
        .init(title: "Host Senses", note: "Local devices used when the brain asks the host for sensory input.", scope: .host, isExpanded: true, options: [
            .select(key: "camera_device_id", label: "Camera input", value: "automatic", choices: ["automatic"]),
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

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
