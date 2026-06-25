//
//  BrainSyncManager.swift
//  Affective
//

import Combine
import CryptoKit
import Foundation

nonisolated struct BrainCloudManifest: Codable, Equatable, Sendable {
    var brainID: String
    var displayName: String
    var schemaVersion: Int
    var archiveHash: String
    var createdAt: Date
    var modifiedAt: Date
    var uploadedAt: Date
    var deviceID: String
    var revision: Int
}

nonisolated enum BrainCloudImportState: Equatable, Sendable {
    case available
    case syncing
    case invalid(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var statusTitle: String {
        switch self {
        case .available:
            return "Ready to import"
        case .syncing:
            return "Still syncing"
        case .invalid:
            return "Needs a fresh export"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            return "This iCloud brain is fully downloaded and passed validation."
        case .syncing:
            return "iCloud has the brain record, but the archive is not fully available on this device yet. Wait for iCloud Drive to finish syncing, then try again."
        case .invalid(let reason):
            return "The iCloud copy could not be imported because it looks damaged or incomplete. \(reason)"
        }
    }
}

nonisolated struct BrainCloudImport: Equatable, Sendable {
    var manifest: BrainCloudManifest
    var state: BrainCloudImportState
}

nonisolated protocol BrainCloudCheckpointStore {
    func listManifests() async throws -> [BrainCloudManifest]
    func loadManifest(brainID: String) async throws -> BrainCloudManifest?
    func importState(for manifest: BrainCloudManifest) async throws -> BrainCloudImportState
    func downloadCheckpoint(brainID: String, to localURL: URL) async throws -> BrainCloudManifest
    func uploadCheckpoint(from localURL: URL, manifest: BrainCloudManifest) async throws
}

nonisolated enum BrainSyncState: Equatable {
    case notSynced
    case checking
    case downloading
    case uploading
    case synced
    case conflict
    case failed(String)

    var blocksOpening: Bool {
        switch self {
        case .checking, .downloading, .conflict:
            return true
        case .notSynced, .uploading, .synced, .failed:
            return false
        }
    }

    var showsLoader: Bool {
        switch self {
        case .checking, .downloading, .uploading:
            return true
        case .notSynced, .synced, .conflict, .failed:
            return false
        }
    }

    var label: String? {
        switch self {
        case .notSynced:
            return nil
        case .checking:
            return "Checking iCloud"
        case .downloading:
            return "Downloading brain"
        case .uploading:
            return "Uploading brain"
        case .synced:
            return "iCloud synced"
        case .conflict:
            return "Sync conflict"
        case .failed(let message):
            return "Sync failed: \(message)"
        }
    }
}

nonisolated enum BrainSyncError: Error, LocalizedError {
    case unavailableICloudContainer
    case missingCheckpoint
    case invalidCheckpointPath(String)
    case invalidCheckpoint
    case conflictRequiresChoice

    var errorDescription: String? {
        switch self {
        case .unavailableICloudContainer:
            return "iCloud Drive is unavailable for this Apple ID or app container."
        case .missingCheckpoint:
            return "The iCloud brain checkpoint is missing."
        case .invalidCheckpointPath(let path):
            return "The brain checkpoint contains an unsafe path: \(path)."
        case .invalidCheckpoint:
            return "The brain checkpoint is invalid."
        case .conflictRequiresChoice:
            return "Choose whether to keep the local brain or the iCloud brain."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unavailableICloudContainer:
            return "Open System Settings, make sure iCloud Drive is enabled for this Apple ID, then reopen Affective and try again."
        case .missingCheckpoint:
            return "Wait for iCloud Drive to finish syncing, then try Import Brain (iCloud) again. If it still is not available, export the brain from the other device and use Import Brain."
        case .invalidCheckpointPath, .invalidCheckpoint:
            return "The iCloud copy looks damaged or incompatible. Re-export the brain from the source device, then import that file locally."
        case .conflictRequiresChoice:
            return "Pick the local brain or the iCloud brain before importing another copy."
        }
    }
}

@MainActor
final class BrainSyncManager: ObservableObject {
    private static let syncedBrainIDKey = "Affective.syncedBrainID"
    private static let metadataKeyPrefix = "Affective.brainSync.metadata."
    private static let schemaVersion = 1

    @Published private(set) var syncedBrainID: BrainDescriptor.ID?
    @Published private var states: [BrainDescriptor.ID: BrainSyncState] = [:]
    @Published private(set) var importableCloudBrains: [BrainCloudManifest] = []
    @Published private(set) var unavailableCloudImports: [BrainCloudImport] = []

    private let store: BrainCloudCheckpointStore
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let deviceID: String
    private var inFlightTasks: [BrainDescriptor.ID: Task<Void, Never>] = [:]

    init(
        store: BrainCloudCheckpointStore = ICloudBrainCheckpointStore(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        deviceID: String = HostDeviceID.current(userDefaults: .standard)
    ) {
        self.store = store
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.deviceID = deviceID
        let stored = userDefaults.string(forKey: Self.syncedBrainIDKey)
        syncedBrainID = stored?.isEmpty == false ? stored : nil
    }

    func state(for brain: BrainDescriptor) -> BrainSyncState {
        guard brain.id == syncedBrainID else { return .notSynced }
        return states[brain.id] ?? .synced
    }

    func canOpen(_ brain: BrainDescriptor) -> Bool {
        !state(for: brain).blocksOpening
    }

    func selectBrainForSync(_ brain: BrainDescriptor) {
        syncedBrainID = brain.id
        userDefaults.set(brain.id, forKey: Self.syncedBrainIDKey)
        states = states.filter { $0.key == brain.id }
        syncNow(brain)
    }

    func stopSyncingDeletedBrain(_ brain: BrainDescriptor) {
        guard brain.id == syncedBrainID else { return }
        inFlightTasks[brain.id]?.cancel()
        inFlightTasks[brain.id] = nil
        states[brain.id] = nil
        syncedBrainID = nil
        userDefaults.removeObject(forKey: Self.syncedBrainIDKey)
    }

    func syncOnAppStart(brains: [BrainDescriptor]) {
        guard let syncedBrainID, let brain = brains.first(where: { $0.id == syncedBrainID }) else { return }
        syncNow(brain)
    }

    func refreshCloudImports(installedBrains: [BrainDescriptor]) {
        Task { [weak self] in
            await self?.loadImportableCloudBrains(installedBrains: installedBrains)
        }
    }

    func importCloudBrain(_ manifest: BrainCloudManifest, library: BrainLibrary) async throws -> BrainDescriptor {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("AffectiveCloudImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archiveURL = scratch.appendingPathComponent(BrainCheckpointArchive.archiveFileName(for: manifest.brainID))
        let downloadedManifest = try await store.downloadCheckpoint(brainID: manifest.brainID, to: archiveURL)
        guard downloadedManifest.archiveHash == manifest.archiveHash else {
            throw BrainSyncError.invalidCheckpoint
        }

        let brain = try library.importBrainArchive(from: archiveURL, preservingBrainID: manifest.brainID)
        syncedBrainID = brain.id
        userDefaults.set(brain.id, forKey: Self.syncedBrainIDKey)
        saveMetadata(.init(
            archiveHash: downloadedManifest.archiveHash,
            cloudArchiveHash: downloadedManifest.archiveHash,
            revision: downloadedManifest.revision,
            cloudModifiedAt: downloadedManifest.uploadedAt
        ), for: brain.id)
        setState(.synced, for: brain.id)
        importableCloudBrains.removeAll { $0.brainID == manifest.brainID }
        unavailableCloudImports.removeAll { $0.manifest.brainID == manifest.brainID }
        return brain
    }

    func syncNow(_ brain: BrainDescriptor) {
        guard brain.id == syncedBrainID else { return }
        inFlightTasks[brain.id]?.cancel()
        setState(.checking, for: brain.id)
        inFlightTasks[brain.id] = Task { [weak self] in
            await self?.runSync(brain: brain)
        }
    }

    private func loadImportableCloudBrains(installedBrains: [BrainDescriptor]) async {
        do {
            let installedIDs = Set(installedBrains.map(\.id))
            let manifests = try await store.listManifests()
            var cloudImports: [BrainCloudImport] = []
            for manifest in manifests where !installedIDs.contains(manifest.brainID) {
                let state = try await store.importState(for: manifest)
                cloudImports.append(BrainCloudImport(manifest: manifest, state: state))
            }
            let sortedImports = cloudImports
                .sorted {
                    if $0.manifest.uploadedAt != $1.manifest.uploadedAt { return $0.manifest.uploadedAt > $1.manifest.uploadedAt }
                    return $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending
                }
            importableCloudBrains = sortedImports
                .filter(\.state.isAvailable)
                .map(\.manifest)
            unavailableCloudImports = sortedImports
                .filter { !$0.state.isAvailable }
        } catch {
            importableCloudBrains = []
            unavailableCloudImports = []
        }
    }

    func uploadOnCloseIfNeeded(_ brain: BrainDescriptor?) {
        guard let brain, brain.id == syncedBrainID else { return }
        syncNow(brain)
    }

    func resolveConflictUsingLocal(_ brain: BrainDescriptor) {
        guard brain.id == syncedBrainID else { return }
        inFlightTasks[brain.id]?.cancel()
        inFlightTasks[brain.id] = Task { [weak self] in
            await self?.uploadLocalWinner(brain: brain)
        }
    }

    func resolveConflictUsingICloud(_ brain: BrainDescriptor, library: BrainLibrary) {
        guard brain.id == syncedBrainID else { return }
        inFlightTasks[brain.id]?.cancel()
        inFlightTasks[brain.id] = Task { [weak self, weak library] in
            guard let library else { return }
            await self?.downloadCloudWinner(brain: brain, library: library)
        }
    }

    private func runSync(brain: BrainDescriptor) async {
        setState(.checking, for: brain.id)
        do {
            let localCheckpoint = try BrainCheckpointArchive.createCheckpoint(
                for: brain,
                schemaVersion: Self.schemaVersion,
                deviceID: deviceID,
                revision: nil,
                fileManager: fileManager
            )
            defer { try? fileManager.removeItem(at: localCheckpoint.archiveURL.deletingLastPathComponent()) }

            let cloudManifest = try await store.loadManifest(brainID: brain.id)
            guard let cloudManifest else {
                setState(.uploading, for: brain.id)
                var manifest = localCheckpoint.manifest
                manifest.revision = 1
                manifest.uploadedAt = Date()
                try await store.uploadCheckpoint(from: localCheckpoint.archiveURL, manifest: manifest)
                saveMetadata(.init(archiveHash: manifest.archiveHash, cloudArchiveHash: manifest.archiveHash, revision: manifest.revision, cloudModifiedAt: manifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
                return
            }

            let metadata = loadMetadata(for: brain.id)
            let localChanged = metadata.map { $0.archiveHash != localCheckpoint.manifest.archiveHash } ?? (localCheckpoint.manifest.archiveHash != cloudManifest.archiveHash)
            let cloudChanged = metadata.map { $0.cloudArchiveHash != cloudManifest.archiveHash || $0.revision != cloudManifest.revision } ?? (localCheckpoint.manifest.archiveHash != cloudManifest.archiveHash)

            if localCheckpoint.manifest.archiveHash == cloudManifest.archiveHash {
                saveMetadata(.init(archiveHash: localCheckpoint.manifest.archiveHash, cloudArchiveHash: cloudManifest.archiveHash, revision: cloudManifest.revision, cloudModifiedAt: cloudManifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
            } else if localChanged && cloudChanged {
                setState(.conflict, for: brain.id)
            } else if cloudChanged {
                try await downloadCloudCheckpoint(brain: brain, cloudManifest: cloudManifest)
            } else {
                setState(.uploading, for: brain.id)
                var manifest = localCheckpoint.manifest
                manifest.revision = cloudManifest.revision + 1
                manifest.uploadedAt = Date()
                try await store.uploadCheckpoint(from: localCheckpoint.archiveURL, manifest: manifest)
                saveMetadata(.init(archiveHash: manifest.archiveHash, cloudArchiveHash: manifest.archiveHash, revision: manifest.revision, cloudModifiedAt: manifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
            }
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func uploadLocalWinner(brain: BrainDescriptor) async {
        setState(.uploading, for: brain.id)
        do {
            let cloudManifest = try await store.loadManifest(brainID: brain.id)
            let localCheckpoint = try BrainCheckpointArchive.createCheckpoint(
                for: brain,
                schemaVersion: Self.schemaVersion,
                deviceID: deviceID,
                revision: (cloudManifest?.revision ?? 0) + 1,
                fileManager: fileManager
            )
            defer { try? fileManager.removeItem(at: localCheckpoint.archiveURL.deletingLastPathComponent()) }
            try await store.uploadCheckpoint(from: localCheckpoint.archiveURL, manifest: localCheckpoint.manifest)
            saveMetadata(.init(archiveHash: localCheckpoint.manifest.archiveHash, cloudArchiveHash: localCheckpoint.manifest.archiveHash, revision: localCheckpoint.manifest.revision, cloudModifiedAt: localCheckpoint.manifest.uploadedAt), for: brain.id)
            setState(.synced, for: brain.id)
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func downloadCloudWinner(brain: BrainDescriptor, library: BrainLibrary) async {
        setState(.downloading, for: brain.id)
        do {
            let manifest = try await store.loadManifest(brainID: brain.id) ?? {
                throw BrainSyncError.missingCheckpoint
            }()
            try await downloadCloudCheckpoint(brain: brain, cloudManifest: manifest)
            library.refresh()
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func downloadCloudCheckpoint(brain: BrainDescriptor, cloudManifest: BrainCloudManifest) async throws {
        setState(.downloading, for: brain.id)
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("AffectiveCloudDownload-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archiveURL = scratch.appendingPathComponent(BrainCheckpointArchive.archiveFileName(for: brain.id))
        let manifest = try await store.downloadCheckpoint(brainID: brain.id, to: archiveURL)
        guard manifest.archiveHash == cloudManifest.archiveHash else {
            throw BrainSyncError.invalidCheckpoint
        }
        let restoredRoot = scratch.appendingPathComponent(brain.id, isDirectory: true)
        try BrainCheckpointArchive.restoreCheckpoint(at: archiveURL, to: restoredRoot, fileManager: fileManager)
        let restored = BrainDescriptor(
            id: brain.id,
            displayName: brain.displayName,
            rootURL: restoredRoot,
            avatarURL: nil,
            avatarManifest: nil,
            modifiedAt: nil,
            isRecent: brain.isRecent
        )
        try restored.validateForCoreConnection(fileManager: fileManager)
        try replaceBrainRoot(at: brain.rootURL, with: restoredRoot)
        saveMetadata(.init(archiveHash: manifest.archiveHash, cloudArchiveHash: manifest.archiveHash, revision: manifest.revision, cloudModifiedAt: manifest.uploadedAt), for: brain.id)
        setState(.synced, for: brain.id)
    }

    private func replaceBrainRoot(at destination: URL, with restoredRoot: URL) throws {
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).sync-backup-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: restoredRoot, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func setState(_ state: BrainSyncState, for brainID: BrainDescriptor.ID) {
        states[brainID] = state
    }

    private func metadataKey(for brainID: String) -> String {
        Self.metadataKeyPrefix + brainID
    }

    private func loadMetadata(for brainID: String) -> BrainSyncMetadata? {
        guard let data = userDefaults.data(forKey: metadataKey(for: brainID)) else { return nil }
        return try? JSONDecoder.brainSync.decode(BrainSyncMetadata.self, from: data)
    }

    private func saveMetadata(_ metadata: BrainSyncMetadata, for brainID: String) {
        guard let data = try? JSONEncoder.brainSync.encode(metadata) else { return }
        userDefaults.set(data, forKey: metadataKey(for: brainID))
    }
}

nonisolated struct ICloudBrainCheckpointStore: BrainCloudCheckpointStore {
    var containerIdentifier: String?
    var fileManager: FileManager = .default

    func listManifests() async throws -> [BrainCloudManifest] {
        try await performFileAccess { root, fileManager in
            guard fileManager.fileExists(atPath: root.path) else { return [] }
            return try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasSuffix(".manifest.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.brainSync.decode(BrainCloudManifest.self, from: data)
            }
        }
    }

    func loadManifest(brainID: String) async throws -> BrainCloudManifest? {
        try await performFileAccess { root, fileManager in
            let manifestURL = root.appendingPathComponent("\(brainID).manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder.brainSync.decode(BrainCloudManifest.self, from: data)
        }
    }

    func importState(for manifest: BrainCloudManifest) async throws -> BrainCloudImportState {
        try await performFileAccess { root, fileManager in
            let manifestURL = root.appendingPathComponent("\(manifest.brainID).manifest.json")
            let archiveURL = root.appendingPathComponent(BrainCheckpointArchive.archiveFileName(for: manifest.brainID))
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: archiveURL.path) else {
                return .syncing
            }
            if Self.isUbiquitousItemStillSyncing(manifestURL) || Self.isUbiquitousItemStillSyncing(archiveURL) {
                return .syncing
            }

            do {
                let data = try Data(contentsOf: archiveURL)
                let hash = BrainCheckpointArchive.sha256Hex(data)
                guard hash == manifest.archiveHash else {
                    return .invalid("The archive checksum does not match its manifest.")
                }
                try BrainCheckpointArchive.validateCheckpointPayload(data, expectedBrainID: manifest.brainID)
                return .available
            } catch let error as BrainSyncError {
                return .invalid(error.localizedDescription)
            } catch {
                return .invalid(error.localizedDescription)
            }
        }
    }

    func downloadCheckpoint(brainID: String, to localURL: URL) async throws -> BrainCloudManifest {
        try await performFileAccess { root, fileManager in
            let manifestURL = root.appendingPathComponent("\(brainID).manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw BrainSyncError.missingCheckpoint
            }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder.brainSync.decode(BrainCloudManifest.self, from: data)
            let archiveURL = root.appendingPathComponent(BrainCheckpointArchive.archiveFileName(for: brainID))
            guard fileManager.fileExists(atPath: archiveURL.path) else {
                throw BrainSyncError.missingCheckpoint
            }
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: archiveURL, to: localURL)
            return manifest
        }
    }

    func uploadCheckpoint(from localURL: URL, manifest: BrainCloudManifest) async throws {
        try await performFileAccess { root, fileManager in
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let archiveURL = root.appendingPathComponent(BrainCheckpointArchive.archiveFileName(for: manifest.brainID))
            let manifestURL = root.appendingPathComponent("\(manifest.brainID).manifest.json")
            let archiveTempURL = root.appendingPathComponent(".\(manifest.brainID).affectivebrain.uploading-\(UUID().uuidString)")
            let manifestTempURL = root.appendingPathComponent(".\(manifest.brainID).manifest.uploading-\(UUID().uuidString)")
            if fileManager.fileExists(atPath: archiveTempURL.path) {
                try fileManager.removeItem(at: archiveTempURL)
            }
            try fileManager.copyItem(at: localURL, to: archiveTempURL)
            try JSONEncoder.brainSync.encode(manifest).write(to: manifestTempURL, options: .atomic)
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }
            if fileManager.fileExists(atPath: manifestURL.path) {
                try fileManager.removeItem(at: manifestURL)
            }
            try fileManager.moveItem(at: archiveTempURL, to: archiveURL)
            try fileManager.moveItem(at: manifestTempURL, to: manifestURL)
        }
    }

    private func performFileAccess<T: Sendable>(
        _ operation: @escaping @Sendable (URL, FileManager) throws -> T
    ) async throws -> T {
        let containerIdentifier = containerIdentifier
        let fileManager = fileManager
        return try await Task.detached(priority: .utility) {
            let root = try Self.rootURL(containerIdentifier: containerIdentifier, fileManager: fileManager)
            return try operation(root, fileManager)
        }.value
    }

    private static func rootURL(containerIdentifier: String?, fileManager: FileManager) throws -> URL {
        guard let container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw BrainSyncError.unavailableICloudContainer
        }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(".brain-cloud", isDirectory: true)
    }

    private static func isUbiquitousItemStillSyncing(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]), values.isUbiquitousItem == true else {
            return false
        }
        if values.ubiquitousItemIsDownloading == true {
            return true
        }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}

nonisolated enum BrainCheckpointArchive {
    private static let formatVersion = 1
    private static let excludedNames: Set<String> = [
        ".DS_Store",
        "provider_credentials.json",
        "secrets.json",
        "pairing_secrets.json",
        "host_permissions.json",
    ]

    struct Created {
        var archiveURL: URL
        var manifest: BrainCloudManifest
    }

    static func archiveFileName(for brainID: String) -> String {
        "\(brainID).affectivebrain.zip"
    }

    static func createCheckpoint(
        for brain: BrainDescriptor,
        schemaVersion: Int,
        deviceID: String,
        revision: Int?,
        fileManager: FileManager = .default
    ) throws -> Created {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("AffectiveBrainCheckpoint-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archiveURL = scratch.appendingPathComponent(archiveFileName(for: brain.id))
        let components = try collectComponents(from: brain.rootURL, fileManager: fileManager)
        let payload = Payload(formatVersion: formatVersion, brainID: brain.id, components: components)
        let data = try JSONEncoder.brainSync.encode(payload)
        try data.write(to: archiveURL, options: .atomic)
        let hash = sha256Hex(data)
        let modifiedAt = brain.modifiedAt ?? Date()
        let now = Date()
        return Created(
            archiveURL: archiveURL,
            manifest: BrainCloudManifest(
                brainID: brain.id,
                displayName: brain.displayName,
                schemaVersion: schemaVersion,
                archiveHash: hash,
                createdAt: modifiedAt,
                modifiedAt: modifiedAt,
                uploadedAt: now,
                deviceID: deviceID,
                revision: revision ?? 0
            )
        )
    }

    static func restoreCheckpoint(at archiveURL: URL, to destinationRoot: URL, fileManager: FileManager = .default) throws {
        let data = try Data(contentsOf: archiveURL)
        let payload = try JSONDecoder.brainSync.decode(Payload.self, from: data)
        guard payload.formatVersion == formatVersion, !payload.brainID.isEmpty else {
            throw BrainSyncError.invalidCheckpoint
        }
        if fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.removeItem(at: destinationRoot)
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for component in payload.components {
            try validateRelativePath(component.path)
            let destination = destinationRoot.appendingPathComponent(component.path)
            if component.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                guard let dataBase64 = component.dataBase64, let bytes = Data(base64Encoded: dataBase64) else {
                    throw BrainSyncError.invalidCheckpoint
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: destination, options: .atomic)
            }
        }
    }

    static func archiveHash(at archiveURL: URL) throws -> String {
        try sha256Hex(Data(contentsOf: archiveURL))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateCheckpointPayload(_ data: Data, expectedBrainID: String) throws {
        let payload = try JSONDecoder.brainSync.decode(Payload.self, from: data)
        guard payload.formatVersion == formatVersion, payload.brainID == expectedBrainID else {
            throw BrainSyncError.invalidCheckpoint
        }
        for component in payload.components {
            try validateRelativePath(component.path)
            if !component.isDirectory {
                guard let dataBase64 = component.dataBase64, Data(base64Encoded: dataBase64) != nil else {
                    throw BrainSyncError.invalidCheckpoint
                }
            }
        }
    }

    private static func collectComponents(from rootURL: URL, fileManager: FileManager) throws -> [Component] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var components: [Component] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if excludedNames.contains(name) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let relativePath = try relativePath(for: url, root: rootURL)
            try validateRelativePath(relativePath)
            if values.isDirectory == true {
                components.append(Component(path: relativePath, isDirectory: true, dataBase64: nil))
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: url)
                components.append(Component(path: relativePath, isDirectory: false, dataBase64: data.base64EncodedString()))
            }
        }
        return components.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.path < $1.path
        }
    }

    private static func relativePath(for url: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw BrainSyncError.invalidCheckpointPath(path)
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw BrainSyncError.invalidCheckpointPath(path)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            throw BrainSyncError.invalidCheckpointPath(path)
        }
        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else {
                throw BrainSyncError.invalidCheckpointPath(path)
            }
        }
        guard !path.contains("\n"), !path.contains("\r") else {
            throw BrainSyncError.invalidCheckpointPath(path)
        }
    }

    private struct Payload: Codable {
        var formatVersion: Int
        var brainID: String
        var components: [Component]
    }

    private struct Component: Codable {
        var path: String
        var isDirectory: Bool
        var dataBase64: String?
    }
}

private nonisolated struct BrainSyncMetadata: Codable, Equatable {
    var archiveHash: String
    var cloudArchiveHash: String
    var revision: Int
    var cloudModifiedAt: Date
}

private nonisolated enum HostDeviceID {
    private static let key = "Affective.hostDeviceID"

    static func current(userDefaults: UserDefaults) -> String {
        if let stored = userDefaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let created = UUID().uuidString
        userDefaults.set(created, forKey: key)
        return created
    }
}

private extension JSONEncoder {
    nonisolated static var brainSync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var brainSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
