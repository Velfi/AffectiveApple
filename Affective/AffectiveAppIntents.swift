//
//  AffectiveAppIntents.swift
//  Affective
//

import Foundation
import AppIntents

enum AffectiveAppIntentBridge {
    static let pendingBrainIDKey = "Affective.pendingAppIntentBrainID"
    static let requestNotification = Notification.Name("Affective.appIntentRequest")

    static func requestOpenConversation(defaults: UserDefaults = .standard) {
        defaults.set("", forKey: pendingBrainIDKey)
        notifyRequest()
    }

    static func requestOpenBrain(id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: pendingBrainIDKey)
        notifyRequest()
    }

    static func recordOpenedBrain(id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: AffectiveViewModel.lastOpenedBrainIDKey)
    }

    static func pendingBrainID(defaults: UserDefaults = .standard) -> String? {
        guard defaults.object(forKey: pendingBrainIDKey) != nil else { return nil }
        return defaults.string(forKey: pendingBrainIDKey) ?? ""
    }

    static func clearPendingBrainID(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingBrainIDKey)
    }

    static func consumePendingBrainID(defaults: UserDefaults = .standard) -> String? {
        guard let id = pendingBrainID(defaults: defaults) else { return nil }
        clearPendingBrainID(defaults: defaults)
        return id
    }

    static func requestedBrain(
        from brains: [BrainDescriptor],
        requestedID: String?,
        defaults: UserDefaults = .standard
    ) -> BrainDescriptor? {
        if let requestedID, !requestedID.isEmpty {
            return brains.first { $0.id == requestedID }
        }

        if
            let lastOpenedBrainID = defaults.string(forKey: AffectiveViewModel.lastOpenedBrainIDKey),
            let brain = brains.first(where: { $0.id == lastOpenedBrainID })
        {
            return brain
        }

        return brains.first
    }

    private static func notifyRequest() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: requestNotification, object: nil)
        }
    }
}

struct OpenAffectiveConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Affective Conversation"
    static let description = IntentDescription("Opens Affective to the most recently used brain conversation.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AffectiveAppIntentBridge.requestOpenConversation()
        return .result(dialog: "Opening Affective.")
    }
}

struct OpenAffectiveBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Affective Brain"
    static let description = IntentDescription("Opens Affective and selects a brain.")
    static let openAppWhenRun = true

    @Parameter(title: "Brain")
    var brain: AffectiveBrainEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AffectiveAppIntentBridge.requestOpenBrain(id: brain.id)
        return .result(dialog: "Opening \(brain.name).")
    }
}

struct CreateAffectiveBrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Affective Brain"
    static let description = IntentDescription("Creates a new Affective brain and opens it.")
    static let openAppWhenRun = true

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Wants", default: "")
    var wants: String

    @Parameter(title: "Goals", default: "")
    var goals: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = BrainLibrary()
        let brain = try library.createBrain(.init(
            name: name,
            wants: wants,
            goals: goals,
            initialThoughts: "",
            notes: "Created from an App Intent."
        ))
        AffectiveAppIntentBridge.requestOpenBrain(id: brain.id)
        return .result(dialog: "Created \(brain.displayName).")
    }
}

struct AffectiveShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAffectiveConversationIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Start a conversation in \(.applicationName)"
            ],
            shortTitle: "Open Affective",
            systemImageName: "bubble.left.and.bubble.right"
        )

        AppShortcut(
            intent: OpenAffectiveBrainIntent(),
            phrases: [
                "Open a brain in \(.applicationName)",
                "Switch brains in \(.applicationName)"
            ],
            shortTitle: "Open Brain",
            systemImageName: "brain.head.profile"
        )

        AppShortcut(
            intent: CreateAffectiveBrainIntent(),
            phrases: [
                "Create a brain in \(.applicationName)",
                "Make a new brain in \(.applicationName)"
            ],
            shortTitle: "Create Brain",
            systemImageName: "plus.circle"
        )
    }
}
