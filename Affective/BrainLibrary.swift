//
//  BrainLibrary.swift
//  Affective
//

import Foundation
import Combine
import SQLite3

final class BrainLibrary: ObservableObject {
    #if DEBUG
    static var storageRootURLOverride: URL?
    #endif

    static var persistentRootURL: URL {
        #if DEBUG
        if let storageRootURLOverride {
            return storageRootURLOverride
        }
        #endif
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent("AffectiveCore", isDirectory: true)
    }

    static var brainsRootURL: URL { persistentRootURL.appendingPathComponent("brains", isDirectory: true) }
    static var profilesRootURL: URL { persistentRootURL.appendingPathComponent("profiles", isDirectory: true) }

    private static let recentBrainIDsKey = "Affective.recentBrainIDs"

    @Published private(set) var brains: [BrainDescriptor] = []
    @Published var statusText = ""

    var recencySortedBrains: [BrainDescriptor] {
        brains
    }

    init() {
        refresh()
    }

    func refresh() {
        do {
            try FileManager.default.createDirectory(at: Self.brainsRootURL, withIntermediateDirectories: true)
            let recentIDs = Self.recentBrainIDs()
            try Self.createCompatibleBrainMetadataIfNeeded(in: Self.brainsRootURL)
            try Self.createCompatibleBrainMetadataIfNeeded(in: Self.profilesRootURL)

            let descriptors = try Self.discoverBrainDescriptors(recentIDs: recentIDs)

            brains = descriptors.sorted { first, second in
                let firstRecent = recentIDs.firstIndex(of: first.id)
                let secondRecent = recentIDs.firstIndex(of: second.id)
                if let firstRecent, let secondRecent {
                    return firstRecent < secondRecent
                }
                if firstRecent != nil { return true }
                if secondRecent != nil { return false }
                switch (first.modifiedAt, second.modifiedAt) {
                case let (firstDate?, secondDate?) where firstDate != secondDate:
                    return firstDate > secondDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
                return first.displayName.localizedCaseInsensitiveCompare(second.displayName) == .orderedAscending
            }
            statusText = brains.isEmpty ? "No installed brains found." : "Found \(brains.count) \(brains.count == 1 ? "brain" : "brains")."
        } catch {
            statusText = error.localizedDescription
            brains = []
        }
    }

    func markOpened(_ brain: BrainDescriptor) {
        var recentIDs = Self.recentBrainIDs().filter { $0 != brain.id }
        recentIDs.insert(brain.id, at: 0)
        UserDefaults.standard.set(Array(recentIDs.prefix(8)), forKey: Self.recentBrainIDsKey)
        refresh()
    }

    func createBrain(_ request: BrainCreationRequest) throws -> BrainDescriptor {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        try FileManager.default.createDirectory(at: Self.brainsRootURL, withIntermediateDirectories: true)
        let rootURL = Self.availableUUIDDestination()
        let memoryURL = rootURL.appendingPathComponent("memory", isDirectory: true)
        let faceEmbeddingsURL = memoryURL.appendingPathComponent("face_embeddings", isDirectory: true)

        try FileManager.default.createDirectory(at: faceEmbeddingsURL, withIntermediateDirectories: true)
        try Data().write(to: rootURL.appendingPathComponent("events.jsonl"), options: .atomic)
        try Data("{}".utf8).write(to: rootURL.appendingPathComponent("runtime_options.json"), options: .atomic)
        try Self.maintenanceTemplate(for: name).write(
            to: rootURL.appendingPathComponent("maintenance.md"),
            atomically: true,
            encoding: .utf8
        )
        try Self.profileObject(for: name, request: request).jsonData().write(
            to: rootURL.appendingPathComponent("brain_profile.json"),
            options: .atomic
        )
        try Self.seedMarkdown(for: name, request: request).write(
            to: rootURL.appendingPathComponent("seed.md"),
            atomically: true,
            encoding: .utf8
        )

        refresh()

        guard let created = brains.first(where: { $0.rootURL == rootURL }) else {
            throw CocoaError(.fileReadUnknown)
        }
        markOpened(created)
        statusText = "Created \(created.displayName)."
        return created
    }

    func importBrainFolder(from sourceURL: URL) throws -> BrainDescriptor {
        try importBrainDirectory(from: sourceURL)
    }

    func importBrain(from sourceURL: URL) throws -> BrainDescriptor {
        if sourceURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame {
            return try importBrainArchive(from: sourceURL)
        }
        return try importBrainDirectory(from: sourceURL)
    }

    func importBrainArchive(from sourceURL: URL, preservingBrainID preferredID: String? = nil) throws -> BrainDescriptor {
        let fileManager = FileManager.default
        let scratchRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AffectiveImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratchRoot) }

        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let restoredRoot = scratchRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)

        do {
            try BrainCheckpointArchive.restoreCheckpoint(at: sourceURL, to: restoredRoot)
            return try importBrainDirectory(from: restoredRoot, preferredID: preferredID)
        } catch {
            throw error
        }
    }

    private func importBrainDirectory(from sourceURL: URL, preferredID: String? = nil) throws -> BrainDescriptor {
        try FileManager.default.createDirectory(at: Self.brainsRootURL, withIntermediateDirectories: true)
        let brainID = preferredID?.sanitizedBrainID
        let destination = brainID.map { Self.brainsRootURL.appendingPathComponent($0, isDirectory: true) }
            ?? Self.availableUUIDDestination()

        if FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: sourceURL.standardizedFileURL, to: destination)
        refresh()

        guard let imported = brains.first(where: { $0.rootURL == destination }) else {
            throw CocoaError(.fileReadUnknown)
        }
        markOpened(imported)
        if Self.exportManifestContainsBiometricData(in: imported.rootURL) {
            statusText = "Imported \(imported.displayName). This export contains biometric data; review Biometric Privacy before using recognition."
        }
        return imported
    }

    func exportBrainZip(_ brain: BrainDescriptor, to destinationURL: URL) throws -> URL {
        let policy = BiometricDataPolicy.load(for: brain)
        let destination = destinationURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame
            ? destinationURL
            : destinationURL.appendingPathExtension("zip")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let checkpoint = try BrainCheckpointArchive.createCheckpoint(
            for: brain,
            schemaVersion: 1,
            deviceID: "export",
            revision: 1,
            includeBiometricData: policy.shouldIncludeInExport
        )
        defer { try? fileManager.removeItem(at: checkpoint.archiveURL.deletingLastPathComponent()) }
        try fileManager.copyItem(at: checkpoint.archiveURL, to: destination)
        statusText = "Exported \(brain.displayName)."
        return destination
    }

    func exportBrainFolder(_ brain: BrainDescriptor, to destinationDirectory: URL) throws -> URL {
        let policy = BiometricDataPolicy.load(for: brain)
        let exportName = "\(brain.id).affectivebrain"
        let destination = destinationDirectory.appendingPathComponent(exportName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try Self.copyBrain(
            from: brain.rootURL,
            to: destination,
            includeBiometricData: policy.shouldIncludeInExport,
            fileManager: .default
        )
        statusText = "Exported \(brain.displayName)."
        return destination
    }

    func deleteBiometricData(for brain: BrainDescriptor) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: brain.faceEmbeddingsURL.path) {
            try fileManager.removeItem(at: brain.faceEmbeddingsURL)
        }
        try fileManager.createDirectory(at: brain.faceEmbeddingsURL, withIntermediateDirectories: true)
        try BiometricCognitiveMemoryScrubber.scrubInPlace(at: brain.memoryDatabaseURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: brain.biometricMetadataURL.path) {
            try fileManager.removeItem(at: brain.biometricMetadataURL)
        }
        let receiptsURL = brain.rootURL
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("biometric_policy_receipts", isDirectory: true)
        if fileManager.fileExists(atPath: receiptsURL.path) {
            try fileManager.removeItem(at: receiptsURL)
        }
        statusText = "Deleted biometric data for \(brain.displayName)."
    }

    func disableRecognitionAndDeleteBiometricData(for brain: BrainDescriptor) throws {
        try deleteBiometricData(for: brain)
        var runtimeOptions = (try? AffectiveViewModel.loadRuntimeOptionsObject(brain: brain)) ?? [:]
        runtimeOptions[BiometricPolicyKeys.recognitionEnabled] = false
        runtimeOptions[BiometricPolicyKeys.enrollmentAllowed] = false
        runtimeOptions[BiometricPolicyKeys.exportIncluded] = false
        let data = try JSONSerialization.data(withJSONObject: runtimeOptions, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: brain.runtimeOptionsURL, options: .atomic)
        statusText = "Disabled recognition and deleted biometric data for \(brain.displayName)."
    }

    func setAvatar(for brain: BrainDescriptor, from sourceURL: URL) throws -> BrainDescriptor {
        let fileManager = FileManager.default
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(sourceExtension) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let destinationExtension = ["jpg", "jpeg"].contains(sourceExtension) ? sourceExtension : "png"
        let destination = brain.rootURL.appendingPathComponent("avatar.\(destinationExtension)")
        let imageData = try Data(contentsOf: sourceURL)

        for name in Self.directAvatarFileNames {
            let existing = brain.rootURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: existing.path) {
                try fileManager.removeItem(at: existing)
            }
        }

        try imageData.write(to: destination, options: .atomic)
        refresh()

        guard let updated = brains.first(where: { $0.id == brain.id }) else {
            throw CocoaError(.fileReadUnknown)
        }
        statusText = "Updated \(updated.displayName)'s avatar."
        return updated
    }

    func saveAvatarManifest(_ manifest: BrainAvatarManifest, for brain: BrainDescriptor) throws -> BrainDescriptor {
        let manifestURL = brain.rootURL.appendingPathComponent("avatar.json")
        try manifest.write(to: manifestURL)
        refresh()

        guard let updated = brains.first(where: { $0.id == brain.id }) else {
            let fallback = BrainDescriptor(
                id: brain.id,
                displayName: brain.displayName,
                rootURL: brain.rootURL,
                avatarURL: Self.avatarURL(for: brain.id, brainRoot: brain.rootURL),
                avatarManifest: Self.avatarManifest(for: brain.rootURL),
                modifiedAt: try? brain.rootURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                isRecent: brain.isRecent
            )
            statusText = "Updated \(fallback.displayName)'s layered avatar."
            return fallback
        }
        statusText = "Updated \(updated.displayName)'s layered avatar."
        return updated
    }

    func renameBrain(_ brain: BrainDescriptor, to newName: String) throws -> BrainDescriptor {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        try Self.updateDisplayName(trimmedName, forBrainAt: brain.rootURL)

        refresh()

        guard let updated = brains.first(where: { $0.id == brain.id }) else {
            throw CocoaError(.fileReadUnknown)
        }
        statusText = "Renamed \(updated.displayName)."
        return updated
    }

    func deleteBrain(_ brain: BrainDescriptor) throws {
        try deleteBiometricData(for: brain)
        try FileManager.default.removeItem(at: brain.rootURL)
        Self.removeRecentBrainID(brain.id)
        refresh()
        statusText = "Deleted \(brain.displayName)."
    }

    func relocateBrain(_ brain: BrainDescriptor, to destinationDirectory: URL) throws -> URL {
        let destination = destinationDirectory
            .standardizedFileURL
            .appendingPathComponent(brain.rootURL.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists)
        }

        try FileManager.default.moveItem(at: brain.rootURL, to: destination)
        Self.removeRecentBrainID(brain.id)
        refresh()
        statusText = "Moved \(brain.displayName) to \(destination.deletingLastPathComponent().path)."
        return destination
    }

    private static func recentBrainIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentBrainIDsKey) ?? []
    }

    private static func removeRecentBrainID(_ id: String) {
        let recentIDs = recentBrainIDs().filter { $0 != id }
        UserDefaults.standard.set(recentIDs, forKey: recentBrainIDsKey)
    }

    private static func isBrainRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let memoryURL = url.appendingPathComponent("memory", isDirectory: true)
        return fileManager.fileExists(atPath: url.appendingPathComponent("brain_profile.json").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("events.jsonl").path)
            && fileManager.fileExists(atPath: memoryURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func discoverBrainDescriptors(recentIDs: [String]) throws -> [BrainDescriptor] {
        let brainRoots = try candidateRoots(in: brainsRootURL)
        let profileRoots = (try? candidateRoots(in: profilesRootURL)) ?? []
        var rootsByID: [String: URL] = [:]

        for root in brainRoots {
            rootsByID[root.lastPathComponent] = root
        }

        for root in profileRoots {
            let id = root.lastPathComponent
            guard isCompatibleBrainRoot(root) else { continue }
            if let existing = rootsByID[id], isCompleteAffectiveBrainRoot(existing) {
                continue
            }
            rootsByID[id] = root
        }

        return rootsByID.map { id, url in
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return BrainDescriptor(
                id: id,
                displayName: Self.displayName(for: id, brainRoot: url),
                rootURL: url,
                avatarURL: Self.avatarURL(for: id, brainRoot: url),
                avatarManifest: Self.avatarManifest(for: url),
                modifiedAt: modifiedAt,
                isRecent: recentIDs.contains(id)
            )
        }
    }

    private static func candidateRoots(in container: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: container.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func createCompatibleBrainMetadataIfNeeded(in container: URL) throws {
        for root in try candidateRoots(in: container) where isCompatibleBrainRoot(root) {
            try repairBrainMetadataIfNeeded(root)
        }
    }

    private static func isCompatibleBrainRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.appendingPathComponent("events.jsonl").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("runtime_options.json").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("memory", isDirectory: true).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func isCompleteAffectiveBrainRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.appendingPathComponent("brain_profile.json").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("events.jsonl").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("maintenance.md").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("runtime_options.json").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("memory", isDirectory: true).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.fileExists(
                atPath: url
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent("face_embeddings", isDirectory: true)
                    .path,
                isDirectory: &isDirectory
            )
            && isDirectory.boolValue
    }

    private static func repairBrainMetadataIfNeeded(_ root: URL) throws {
        let fileManager = FileManager.default
        let id = root.lastPathComponent
        let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
        let faceEmbeddingsURL = memoryURL.appendingPathComponent("face_embeddings", isDirectory: true)

        try fileManager.createDirectory(at: faceEmbeddingsURL, withIntermediateDirectories: true)

        let profileURL = root.appendingPathComponent("brain_profile.json")
        if !fileManager.fileExists(atPath: profileURL.path) {
            let profile: [String: Any] = [
                "schema_version": 1,
                "display_name": id.brainDisplayName,
                "created_at": ISO8601DateFormatter().string(from: Date()),
                "source": "AffectiveCore legacy profile"
            ]
            try profile.jsonData().write(to: profileURL, options: .atomic)
        }

        let maintenanceURL = root.appendingPathComponent("maintenance.md")
        if !fileManager.fileExists(atPath: maintenanceURL.path) {
            try maintenanceTemplate(for: id.brainDisplayName).write(to: maintenanceURL, atomically: true, encoding: .utf8)
        }
    }

    private static func copyBrain(
        from sourceRoot: URL,
        to destinationRoot: URL,
        includeBiometricData: Bool,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            try writeBiometricExportManifest(at: destinationRoot, containsBiometricData: includeBiometricData)
            return
        }

        for case let sourceURL as URL in enumerator {
            let relativePath = String(sourceURL.standardizedFileURL.path.dropFirst(sourceRoot.standardizedFileURL.path.count + 1))
            if shouldExcludeFromExport(relativePath: relativePath, includeBiometricData: includeBiometricData) {
                if (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let destinationURL = destinationRoot.appendingPathComponent(relativePath)
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !includeBiometricData,
                   relativePath == "memory/people.sqlite",
                   let scrubbedData = try BiometricCognitiveMemoryScrubber.scrubbedDatabaseData(from: sourceURL, fileManager: fileManager) {
                    try scrubbedData.write(to: destinationURL, options: .atomic)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                }
            }
        }
        try writeBiometricExportManifest(at: destinationRoot, containsBiometricData: includeBiometricData)
    }

    nonisolated static func shouldExcludeFromExport(relativePath: String, includeBiometricData: Bool) -> Bool {
        guard !includeBiometricData else { return false }
        return relativePath == "memory/face_embeddings"
            || relativePath.hasPrefix("memory/face_embeddings/")
            || relativePath == "memory/biometric_identities.json"
            || relativePath == "memory/biometric_policy_receipts"
            || relativePath.hasPrefix("memory/biometric_policy_receipts/")
            || relativePath == "memory/people.sqlite-wal"
            || relativePath == "memory/people.sqlite-shm"
    }

    nonisolated static func biometricExportManifestData(containsBiometricData: Bool) throws -> Data {
        let manifest: [String: Any] = [
            "contains_biometric_data": containsBiometricData,
            "biometric_data_policy": [
                "storage": "local_device",
                "sharing": "user_export_only",
                "owner_managed": true,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    private static func writeBiometricExportManifest(at rootURL: URL, containsBiometricData: Bool) throws {
        let data = try biometricExportManifestData(containsBiometricData: containsBiometricData)
        try data.write(to: rootURL.appendingPathComponent("export_manifest.json"), options: .atomic)
    }

    private static func exportManifestContainsBiometricData(in rootURL: URL) -> Bool {
        let manifestURL = rootURL.appendingPathComponent("export_manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containsBiometricData = object["contains_biometric_data"] as? Bool else {
            return false
        }
        return containsBiometricData
    }

    private static func availableUUIDDestination() -> URL {
        while true {
            let candidate = brainsRootURL.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
    }

    private static func displayName(for id: String, brainRoot: URL) -> String {
        let profileURL = brainRoot.appendingPathComponent("brain_profile.json")
        guard
            let data = try? Data(contentsOf: profileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let displayName = object["display_name"] as? String,
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return id.brainDisplayName
        }
        return displayName
    }

    private static func updateDisplayName(_ displayName: String, forBrainAt brainRoot: URL) throws {
        let profileURL = brainRoot.appendingPathComponent("brain_profile.json")
        var object: [String: Any] = [:]
        if
            let data = try? Data(contentsOf: profileURL),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = existing
        }
        object["display_name"] = displayName
        try object.jsonData().write(to: profileURL, options: .atomic)
    }

    private static func profileObject(for name: String, request: BrainCreationRequest) -> [String: Any] {
        [
            "schema_version": 1,
            "display_name": name,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "wants": request.wants.seedLines,
            "goals": request.goals.seedLines,
            "initial_thoughts": request.initialThoughts.trimmingCharacters(in: .whitespacesAndNewlines),
            "notes": request.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
    }

    private static func maintenanceTemplate(for name: String) -> String {
        """
        # \(name) Maintenance

        - Review seed orientation.
        - Consolidate important early memories.
        - Notice recurring wants, goals, and preferences.
        """
    }

    private static func seedMarkdown(for name: String, request: BrainCreationRequest) -> String {
        """
        # \(name) Seed Orientation

        ## Wants
        \(request.wants.seedMarkdownList)

        ## Goals
        \(request.goals.seedMarkdownList)

        ## Initial Thoughts
        \(request.initialThoughts.seedParagraph)

        ## Notes
        \(request.notes.seedParagraph)
        """
    }

    private static func avatarURL(for id: String, brainRoot: URL) -> URL? {
        let fileManager = FileManager.default
        for name in directAvatarFileNames {
            let candidate = brainRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let profileCaptures = profilesRootURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        let captures = (try? fileManager.contentsOfDirectory(
            at: profileCaptures,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return captures
            .filter { ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .first
    }

    private static func avatarManifest(for brainRoot: URL) -> BrainAvatarManifest? {
        let manifestURL = brainRoot.appendingPathComponent("avatar.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        return try? BrainAvatarManifest.load(from: manifestURL, relativeTo: brainRoot)
    }

    private static let directAvatarFileNames = ["avatar.png", "avatar.jpg", "avatar.jpeg", "portrait.png", "portrait.jpg", "icon.png", "icon.jpg"]
}

nonisolated enum BrainLibraryError: LocalizedError {
    case biometricDatabaseReadFailed
    case biometricDatabaseWriteFailed

    var errorDescription: String? {
        switch self {
        case .biometricDatabaseReadFailed:
            "Could not read local biometric records."
        case .biometricDatabaseWriteFailed:
            "Could not update local biometric records."
        }
    }
}

nonisolated enum BiometricCognitiveMemoryScrubber {
    private static let biometricSubjectKeys: Set<String> = [
        "embeddings",
        "biometric_records",
        "representative_image_path",
        "representative_quality_score",
    ]

    static func scrubInPlace(at databaseURL: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: databaseURL.path),
              let object = try readCognitiveObject(from: databaseURL) else {
            return
        }
        try writeCognitiveObject(scrubbedCognitiveObject(object), to: databaseURL)
    }

    static func scrubbedDatabaseData(from databaseURL: URL, fileManager: FileManager = .default) throws -> Data? {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        guard let object = try readCognitiveObject(from: databaseURL) else {
            return try Data(contentsOf: databaseURL)
        }

        let scrubbedURL = fileManager.temporaryDirectory
            .appendingPathComponent("AffectiveScrubbedPeople-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: scrubbedURL) }

        try createCognitiveDatabase(at: scrubbedURL)
        try writeCognitiveObject(scrubbedCognitiveObject(object), to: scrubbedURL)
        return try Data(contentsOf: scrubbedURL)
    }

    private static func scrubbedCognitiveObject(_ object: [String: Any]) -> [String: Any] {
        var output = object
        if let subjects = object["subjects"] as? [[String: Any]] {
            output["subjects"] = subjects.map { subject in
                var scrubbed = subject
                for key in biometricSubjectKeys {
                    scrubbed.removeValue(forKey: key)
                }
                return scrubbed
            }
        }
        return output
    }

    private static func readCognitiveObject(from databaseURL: URL) throws -> [String: Any]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw BrainLibraryError.biometricDatabaseReadFailed
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        let data = Data(String(cString: textPointer).utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw BrainLibraryError.biometricDatabaseReadFailed
        }
        return dictionary
    }

    private static func createCognitiveDatabase(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw BrainLibraryError.biometricDatabaseWriteFailed
        }
        defer { sqlite3_close(database) }

        let sql = """
        PRAGMA user_version = 2;
        CREATE TABLE IF NOT EXISTS cognitive_memory (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            schema_version INTEGER NOT NULL,
            data_json TEXT NOT NULL
        );
        INSERT OR IGNORE INTO cognitive_memory (id, schema_version, data_json)
        VALUES (1, 2, '{}');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw BrainLibraryError.biometricDatabaseWriteFailed
        }
    }

    private static func writeCognitiveObject(_ object: [String: Any], to databaseURL: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let text = String(data: data, encoding: .utf8) ?? "{}"

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(database) }
            throw BrainLibraryError.biometricDatabaseWriteFailed
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = """
        INSERT INTO cognitive_memory (id, schema_version, data_json)
        VALUES (1, 2, ?)
        ON CONFLICT(id) DO UPDATE SET schema_version = excluded.schema_version, data_json = excluded.data_json
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw BrainLibraryError.biometricDatabaseWriteFailed
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindStatus = text.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, transient)
        }
        guard bindStatus == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw BrainLibraryError.biometricDatabaseWriteFailed
        }
    }
}
