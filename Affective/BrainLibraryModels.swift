//
//  Split from BrainLibrary.swift
//  Affective
//

import Foundation

struct BrainDescriptor: Identifiable, Equatable {
    let id: String
    let displayName: String
    let rootURL: URL
    let avatarURL: URL?
    let avatarManifest: BrainAvatarManifest?
    let modifiedAt: Date?
    let isRecent: Bool

    nonisolated var memoryDatabaseURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("people.sqlite")
    }

    nonisolated var graphDatabaseURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("relationships.sqlite")
    }

    nonisolated var scheduleURL: URL {
        rootURL.appendingPathComponent("maintenance.md")
    }

    nonisolated var maintenanceStateURL: URL {
        rootURL.appendingPathComponent("maintenance_state.json")
    }

    nonisolated var runtimeOptionsURL: URL {
        rootURL.appendingPathComponent("runtime_options.json")
    }

    nonisolated var statsJournalURL: URL {
        rootURL.appendingPathComponent("brain_stats.json")
    }

    nonisolated var mailboxUIStateURL: URL {
        rootURL.appendingPathComponent("mailbox_ui_state.json")
    }

    nonisolated var profileURL: URL {
        rootURL.appendingPathComponent("brain_profile.json")
    }

    nonisolated var faceEmbeddingsURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("face_embeddings", isDirectory: true)
    }

    nonisolated var biometricMetadataURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("biometric_identities.json")
    }

    /// Changes when layered or static avatar files on disk change, so views can force a fresh render.
    nonisolated var avatarRenderToken: String {
        let manifestURL = rootURL.appendingPathComponent("avatar.json")
        let manifestStamp = fileModificationTimestamp(at: manifestURL)
        if let avatarURL {
            let avatarStamp = fileModificationTimestamp(at: avatarURL)
            return "\(id)-\(manifestStamp)-\(avatarStamp)"
        }
        if manifestStamp > 0 {
            return "\(id)-\(manifestStamp)"
        }
        return id
    }

    var avatarClipAspectRatio: CGFloat {
        guard let manifest = avatarManifest else { return 1 }
        let clip = manifest.effectiveClip
        let rawRatio = clip.width / max(clip.height, 1)
        return rawRatio.isFinite && rawRatio > 0 ? rawRatio : 1
    }

    nonisolated private func fileModificationTimestamp(at url: URL) -> TimeInterval {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
    }

    nonisolated var favoriteThemeColor: BrainThemeColor? {
        guard
            let data = try? Data(contentsOf: profileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return BrainThemeColor.favoriteColor(in: object)
    }

    nonisolated func validateForCoreConnection(fileManager: FileManager = .default) throws {
        try Self.requireDirectory(rootURL, relativePath: rootURL.lastPathComponent, fileManager: fileManager)
        try Self.requireFile(profileURL, relativePath: "brain_profile.json", fileManager: fileManager)
        try Self.requireFile(scheduleURL, relativePath: "maintenance.md", fileManager: fileManager)
        try Self.requireFile(runtimeOptionsURL, relativePath: "runtime_options.json", fileManager: fileManager)
        try Self.requireDirectory(rootURL.appendingPathComponent("memory", isDirectory: true), relativePath: "memory/", fileManager: fileManager)
        try Self.requireDirectory(faceEmbeddingsURL, relativePath: "memory/face_embeddings/", fileManager: fileManager)

        let profileObject = try Self.loadJSONObject(at: profileURL, relativePath: "brain_profile.json")
        guard !profileObject.isEmpty else {
            throw BrainValidationError.invalidJSON("brain_profile.json", detail: "expected a non-empty JSON object")
        }
        _ = try Self.loadJSONObject(at: runtimeOptionsURL, relativePath: "runtime_options.json", allowsEmptyFile: true)
    }

    nonisolated static func requireFile(_ url: URL, relativePath: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BrainValidationError.missingFile(relativePath)
        }
    }

    nonisolated static func requireDirectory(_ url: URL, relativePath: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrainValidationError.missingDirectory(relativePath)
        }
    }

    nonisolated static func loadJSONObject(
        at url: URL,
        relativePath: String,
        allowsEmptyFile: Bool = false
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if data.isEmpty, allowsEmptyFile {
            return [:]
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw BrainValidationError.invalidJSON(relativePath, detail: "expected a JSON object")
            }
            return dictionary
        } catch let error as BrainValidationError {
            throw error
        } catch {
            throw BrainValidationError.invalidJSON(relativePath, detail: error.localizedDescription)
        }
    }

    nonisolated static func validateJSONLines(at url: URL, relativePath: String) throws {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrainValidationError.invalidJSON(relativePath, detail: "expected UTF-8 JSON Lines")
        }

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else {
                throw BrainValidationError.invalidJSON(relativePath, detail: "line \(index + 1) is not UTF-8")
            }
            do {
                _ = try JSONSerialization.jsonObject(with: lineData)
            } catch {
                throw BrainValidationError.invalidJSON(relativePath, detail: "line \(index + 1): \(error.localizedDescription)")
            }
        }
    }
}

nonisolated struct BrainThemeColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static func favoriteColor(in object: [String: Any]) -> BrainThemeColor? {
        for key in favoriteColorKeys {
            if let color = color(from: object[key]) {
                return color
            }
        }

        for key in nestedProfileKeys {
            if
                let nested = object[key] as? [String: Any],
                let color = favoriteColor(in: nested)
            {
                return color
            }
        }

        return nil
    }

    private static let favoriteColorKeys = [
        "favorite_color",
        "favoriteColor",
        "favourite_color",
        "favouriteColor",
        "favorite_colour",
        "favoriteColour",
        "theme_color",
        "themeColor",
        "accent_color",
        "accentColor",
    ]

    private static let nestedProfileKeys = [
        "profile",
        "identity",
        "self",
        "preferences",
        "appearance",
        "theme",
    ]

    private static let namedColors: [String: BrainThemeColor] = [
        "red": .init(red: 0.95, green: 0.20, blue: 0.18),
        "orange": .init(red: 0.95, green: 0.46, blue: 0.12),
        "yellow": .init(red: 0.72, green: 0.56, blue: 0.05),
        "green": .init(red: 0.07, green: 0.56, blue: 0.25),
        "mint": .init(red: 0.00, green: 0.58, blue: 0.50),
        "teal": .init(red: 0.00, green: 0.50, blue: 0.58),
        "cyan": .init(red: 0.00, green: 0.45, blue: 0.78),
        "blue": .init(red: 0.00, green: 0.36, blue: 0.90),
        "indigo": .init(red: 0.32, green: 0.34, blue: 0.84),
        "purple": .init(red: 0.56, green: 0.28, blue: 0.82),
        "pink": .init(red: 0.86, green: 0.20, blue: 0.48),
        "brown": .init(red: 0.58, green: 0.36, blue: 0.20),
    ]

    private static func color(from value: Any?) -> BrainThemeColor? {
        if let string = value as? String {
            return parseColorString(string)
        }
        if let object = value as? [String: Any] {
            return color(fromObject: object)
        }
        if let array = value as? [Any], array.count >= 3 {
            return color(fromComponents: array)
        }
        return nil
    }

    static func color(fromString rawString: String) -> BrainThemeColor? {
        parseColorString(rawString)
    }

    private static func parseColorString(_ rawString: String) -> BrainThemeColor? {
        let string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        let normalizedName = string
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        if let namedColor = namedColors[normalizedName] {
            return namedColor
        }

        let hex = string
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let shift = hex.count == 8 ? 8 : 0
        return BrainThemeColor(
            red: Double((value >> UInt64(16 + shift)) & 0xff) / 255,
            green: Double((value >> UInt64(8 + shift)) & 0xff) / 255,
            blue: Double((value >> UInt64(shift)) & 0xff) / 255
        )
    }

    private static func color(fromObject object: [String: Any]) -> BrainThemeColor? {
        if let string = object["hex"] as? String ?? object["value"] as? String ?? object["name"] as? String {
            return parseColorString(string)
        }

        let red = numericValue(object["red"] ?? object["r"])
        let green = numericValue(object["green"] ?? object["g"])
        let blue = numericValue(object["blue"] ?? object["b"])
        guard let red, let green, let blue else { return nil }
        return BrainThemeColor(red: normalized(red), green: normalized(green), blue: normalized(blue))
    }

    private static func color(fromComponents components: [Any]) -> BrainThemeColor? {
        guard
            let red = numericValue(components[0]),
            let green = numericValue(components[1]),
            let blue = numericValue(components[2])
        else {
            return nil
        }
        return BrainThemeColor(red: normalized(red), green: normalized(green), blue: normalized(blue))
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func normalized(_ value: Double) -> Double {
        min(max(value > 1 ? value / 255 : value, 0), 1)
    }
}

nonisolated enum BiometricPolicyKeys {
    static let recognitionEnabled = "biometric_recognition_enabled"
    static let policyAcknowledged = "biometric_policy_acknowledged"
    static let enrollmentAllowed = "biometric_enrollment_allowed"
    static let retentionPeriod = "biometric_retention_period"
    static let exportIncluded = "biometric_export_included"
    static let exportConfirmationRequired = "biometric_export_confirmation_required"
    static let autoDeleteUnconfirmed = "biometric_auto_delete_unconfirmed"
}

nonisolated struct BiometricDataPolicy: Equatable {
    var recognitionEnabled: Bool
    var policyAcknowledged: Bool
    var enrollmentAllowed: Bool
    var retentionPeriod: String
    var exportIncluded: Bool
    var exportConfirmationRequired: Bool
    var autoDeleteUnconfirmed: Bool

    static let defaultRetentionPeriod = "until_deleted"

    static var disabledDefault: BiometricDataPolicy {
        BiometricDataPolicy(
            recognitionEnabled: false,
            policyAcknowledged: false,
            enrollmentAllowed: false,
            retentionPeriod: defaultRetentionPeriod,
            exportIncluded: false,
            exportConfirmationRequired: true,
            autoDeleteUnconfirmed: true
        )
    }

    var canRecognize: Bool {
        recognitionEnabled && policyAcknowledged
    }

    var canEnroll: Bool {
        canRecognize && enrollmentAllowed
    }

    var shouldIncludeInExport: Bool {
        exportIncluded
    }

    static func load(for brain: BrainDescriptor, fileManager: FileManager = .default) -> BiometricDataPolicy {
        guard fileManager.fileExists(atPath: brain.runtimeOptionsURL.path),
              let data = try? Data(contentsOf: brain.runtimeOptionsURL),
              !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .disabledDefault
        }
        return fromRuntimeOptions(object)
    }

    static func fromRuntimeOptions(_ object: [String: Any]) -> BiometricDataPolicy {
        BiometricDataPolicy(
            recognitionEnabled: boolValue(object[BiometricPolicyKeys.recognitionEnabled], default: false),
            policyAcknowledged: boolValue(object[BiometricPolicyKeys.policyAcknowledged], default: false),
            enrollmentAllowed: boolValue(object[BiometricPolicyKeys.enrollmentAllowed], default: false),
            retentionPeriod: stringValue(object[BiometricPolicyKeys.retentionPeriod], default: defaultRetentionPeriod),
            exportIncluded: boolValue(object[BiometricPolicyKeys.exportIncluded], default: false),
            exportConfirmationRequired: boolValue(object[BiometricPolicyKeys.exportConfirmationRequired], default: true),
            autoDeleteUnconfirmed: boolValue(object[BiometricPolicyKeys.autoDeleteUnconfirmed], default: true)
        )
    }

    private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: break
            }
        }
        return defaultValue
    }

    private static func stringValue(_ value: Any?, default defaultValue: String) -> String {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }
        return string
    }
}

nonisolated struct BiometricTemplateSummary: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let templateCount: Int
    let createdAt: Date?
    let lastMatchedAt: Date?
    let consentStatus: String

    static func load(from brain: BrainDescriptor, fileManager: FileManager = .default) -> [BiometricTemplateSummary] {
        var summariesByName: [String: BiometricTemplateSummary] = [:]

        if fileManager.fileExists(atPath: brain.biometricMetadataURL.path),
           let data = try? Data(contentsOf: brain.biometricMetadataURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let identities = object["identities"] as? [[String: Any]] {
            for identity in identities {
                let name = (identity["name"] as? String)
                    ?? (identity["id"] as? String)
                    ?? "Unknown"
                let templateCount = (identity["template_count"] as? NSNumber)?.intValue ?? 0
                summariesByName[name] = BiometricTemplateSummary(
                    name: name,
                    templateCount: templateCount,
                    createdAt: dateValue(identity["created_at"]),
                    lastMatchedAt: dateValue(identity["last_matched_at"]),
                    consentStatus: (identity["consent_status"] as? String) ?? "owner-managed"
                )
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: brain.faceEmbeddingsURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return summariesByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        var fileCounts: [String: (count: Int, createdAt: Date?, modifiedAt: Date?)] = [:]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let name = stem.isEmpty ? "Unlabeled" : stem
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            var current = fileCounts[name] ?? (0, nil, nil)
            current.count += 1
            if let created = values?.creationDate {
                current.createdAt = minDate(current.createdAt, created)
            }
            if let modified = values?.contentModificationDate {
                current.modifiedAt = maxDate(current.modifiedAt, modified)
            }
            fileCounts[name] = current
        }

        for (name, files) in fileCounts {
            let existing = summariesByName[name]
            summariesByName[name] = BiometricTemplateSummary(
                name: name,
                templateCount: max(existing?.templateCount ?? 0, files.count),
                createdAt: existing?.createdAt ?? files.createdAt,
                lastMatchedAt: existing?.lastMatchedAt ?? files.modifiedAt,
                consentStatus: existing?.consentStatus ?? "owner-managed"
            )
        }

        return summariesByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}

enum BrainValidationError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case missingDirectory(String)
    case invalidJSON(String, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            "This brain is incomplete. Missing required file: \(path)."
        case .missingDirectory(let path):
            "This brain is incomplete. Missing required folder: \(path)."
        case .invalidJSON(let path, let detail):
            "This brain contains invalid data in \(path): \(detail)."
        }
    }
}

struct BrainCreationRequest: Equatable {
    var name: String
    var wants: String
    var goals: String
    var initialThoughts: String
    var notes: String
}

@MainActor
extension String {
    var brainDisplayName: String {
        split(separator: "-")
            .flatMap { $0.split(separator: "_") }
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    var sanitizedBrainID: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = String(map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "imported-brain" : sanitized
    }

    var seedLines: [String] {
        components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
            }
            .filter { !$0.isEmpty }
    }

    var seedMarkdownList: String {
        let lines = seedLines
        guard !lines.isEmpty else { return "- None provided yet." }
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }

    var seedParagraph: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "None provided yet." : trimmed
    }
}

extension Dictionary where Key == String, Value == Any {
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: self, options: [.prettyPrinted, .sortedKeys])
    }
}
