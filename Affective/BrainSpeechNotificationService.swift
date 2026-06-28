//
//  BrainSpeechNotificationService.swift
//  Affective
//

import Foundation
import UserNotifications

enum BrainSpeechNotificationAuthorizationStatus: String, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
}

private enum BrainSpeechNotificationKeys {
    static let brainSpeechKind = "brain_speech"
    static let brainID = "brain_id"
    static let kind = "kind"
}

enum BrainSpeechNotificationPolicy {
    static func shouldNotify(isForeground: Bool, text: String) -> Bool {
        !isForeground && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldSpeakAloud(isForeground: Bool, brainVoiceEnabled: Bool) -> Bool {
        isForeground && brainVoiceEnabled
    }
}

@MainActor
protocol BrainSpeechNotificationClient: AnyObject {
    func requestAuthorizationIfNeeded() async -> BrainSpeechNotificationAuthorizationStatus
    func authorizationStatus() async -> BrainSpeechNotificationAuthorizationStatus
    func postIfAuthorized(brainID: String, brainName: String, text: String) async -> Bool
    func registerDelegateIfNeeded()
}

@MainActor
final class SystemBrainSpeechNotificationService: NSObject, BrainSpeechNotificationClient, UNUserNotificationCenterDelegate {
    static let shared = SystemBrainSpeechNotificationService()

    private static let maxBodyLength = 200

    private let center = UNUserNotificationCenter.current()
    private var didRegisterDelegate = false
    static var didRequestAuthorizationThisLaunch = false

    func registerDelegateIfNeeded() {
        guard !didRegisterDelegate else { return }
        center.delegate = self
        didRegisterDelegate = true
    }

    func requestAuthorizationIfNeeded() async -> BrainSpeechNotificationAuthorizationStatus {
        registerDelegateIfNeeded()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                return granted ? .authorized : .denied
            } catch {
                return .denied
            }
        }
        return mapAuthorizationStatus(settings.authorizationStatus)
    }

    func authorizationStatus() async -> BrainSpeechNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        return mapAuthorizationStatus(settings.authorizationStatus)
    }

    func postIfAuthorized(brainID: String, brainName: String, text: String) async -> Bool {
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            return false
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let content = UNMutableNotificationContent()
        content.title = brainName
        content.body = trimmed.count > Self.maxBodyLength
            ? String(trimmed.prefix(Self.maxBodyLength))
            : trimmed
        content.sound = .default
        content.userInfo = [
            BrainSpeechNotificationKeys.brainID: brainID,
            BrainSpeechNotificationKeys.kind: BrainSpeechNotificationKeys.brainSpeechKind,
        ]

        let identifier = "affective.brain_speech.\(brainID)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func mapAuthorizationStatus(_ status: UNAuthorizationStatus) -> BrainSpeechNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .denied
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let kind = userInfo[BrainSpeechNotificationKeys.kind] as? String,
           kind == BrainSpeechNotificationKeys.brainSpeechKind,
           let brainID = userInfo[BrainSpeechNotificationKeys.brainID] as? String {
            DispatchQueue.main.async {
                AffectiveAppIntentBridge.requestOpenBrain(id: brainID)
            }
        }
        completionHandler()
    }
}
