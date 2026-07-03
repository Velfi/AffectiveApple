//
//  BrainSyncManager.swift
//  Affective
//

import Combine
import Compression
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

nonisolated protocol BrainCloudArchiveStore {
    func listManifests() async throws -> [BrainCloudManifest]
    func loadManifest(brainID: String) async throws -> BrainCloudManifest?
    func importState(for manifest: BrainCloudManifest) async throws -> BrainCloudImportState
    func downloadArchive(brainID: String, to localURL: URL) async throws -> BrainCloudManifest
    func uploadArchive(from localURL: URL, manifest: BrainCloudManifest) async throws
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
    case missingArchive
    case invalidArchivePath(String)
    case invalidArchive
    case conflictRequiresChoice

    var errorDescription: String? {
        switch self {
        case .unavailableICloudContainer:
            return "iCloud Drive is unavailable for this Apple ID or app container."
        case .missingArchive:
            return "The iCloud brain archive is missing."
        case .invalidArchivePath(let path):
            return "The brain archive contains an unsafe path: \(path)."
        case .invalidArchive:
            return "The brain archive is invalid."
        case .conflictRequiresChoice:
            return "Choose whether to keep the local brain or the iCloud brain."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unavailableICloudContainer:
            return "Open System Settings, make sure iCloud Drive is enabled for this Apple ID, then reopen Affective and try again."
        case .missingArchive:
            return "Wait for iCloud Drive to finish syncing, then try Import Brain (iCloud) again. If it still is not available, export the brain from the other device and use Import Brain."
        case .invalidArchivePath, .invalidArchive:
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

    private let store: BrainCloudArchiveStore
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let deviceID: String
    private var inFlightTasks: [BrainDescriptor.ID: Task<Void, Never>] = [:]

    init(
        store: BrainCloudArchiveStore = ICloudBrainArchiveStore(),
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
        let archiveURL = scratch.appendingPathComponent(BrainCloudArchive.archiveFileName(for: manifest.brainID))
        let downloadedManifest = try await store.downloadArchive(brainID: manifest.brainID, to: archiveURL)
        guard downloadedManifest.archiveHash == manifest.archiveHash else {
            throw BrainSyncError.invalidArchive
        }

        let brain = try await library.importBrainFileWithCore(from: archiveURL)
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
        await BrainFileAccessGate.runExclusive(brainID: brain.id) {
            await runSyncBody(brain: brain)
        }
    }

    private func runSyncBody(brain: BrainDescriptor) async {
        setState(.checking, for: brain.id)
        do {
            let includeBiometricData = BiometricDataPolicy.load(for: brain).shouldIncludeInExport
            let localArchive = try await createCloudArchive(
                for: brain,
                revision: nil,
                includeBiometricData: includeBiometricData
            )
            defer { try? fileManager.removeItem(at: localArchive.scratchRoot) }

            let cloudManifest = try await store.loadManifest(brainID: brain.id)
            guard let cloudManifest else {
                setState(.uploading, for: brain.id)
                var manifest = localArchive.manifest
                manifest.revision = 1
                manifest.uploadedAt = Date()
                try await store.uploadArchive(from: localArchive.archiveURL, manifest: manifest)
                saveMetadata(.init(archiveHash: manifest.archiveHash, cloudArchiveHash: manifest.archiveHash, revision: manifest.revision, cloudModifiedAt: manifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
                return
            }

            let metadata = loadMetadata(for: brain.id)
            let localChanged = metadata.map { $0.archiveHash != localArchive.manifest.archiveHash } ?? (localArchive.manifest.archiveHash != cloudManifest.archiveHash)
            let cloudChanged = metadata.map { $0.cloudArchiveHash != cloudManifest.archiveHash || $0.revision != cloudManifest.revision } ?? (localArchive.manifest.archiveHash != cloudManifest.archiveHash)

            if localArchive.manifest.archiveHash == cloudManifest.archiveHash {
                saveMetadata(.init(archiveHash: localArchive.manifest.archiveHash, cloudArchiveHash: cloudManifest.archiveHash, revision: cloudManifest.revision, cloudModifiedAt: cloudManifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
            } else if localChanged && cloudChanged {
                setState(.conflict, for: brain.id)
            } else if cloudChanged {
                try await downloadCloudArchive(brain: brain, cloudManifest: cloudManifest)
            } else {
                setState(.uploading, for: brain.id)
                var manifest = localArchive.manifest
                manifest.revision = cloudManifest.revision + 1
                manifest.uploadedAt = Date()
                try await store.uploadArchive(from: localArchive.archiveURL, manifest: manifest)
                saveMetadata(.init(archiveHash: manifest.archiveHash, cloudArchiveHash: manifest.archiveHash, revision: manifest.revision, cloudModifiedAt: manifest.uploadedAt), for: brain.id)
                setState(.synced, for: brain.id)
            }
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func uploadLocalWinner(brain: BrainDescriptor) async {
        await BrainFileAccessGate.runExclusive(brainID: brain.id) {
            await uploadLocalWinnerBody(brain: brain)
        }
    }

    private func uploadLocalWinnerBody(brain: BrainDescriptor) async {
        setState(.uploading, for: brain.id)
        do {
            let cloudManifest = try await store.loadManifest(brainID: brain.id)
            let includeBiometricData = BiometricDataPolicy.load(for: brain).shouldIncludeInExport
            let localArchive = try await createCloudArchive(
                for: brain,
                revision: (cloudManifest?.revision ?? 0) + 1,
                includeBiometricData: includeBiometricData
            )
            defer { try? fileManager.removeItem(at: localArchive.scratchRoot) }
            try await store.uploadArchive(from: localArchive.archiveURL, manifest: localArchive.manifest)
            saveMetadata(.init(archiveHash: localArchive.manifest.archiveHash, cloudArchiveHash: localArchive.manifest.archiveHash, revision: localArchive.manifest.revision, cloudModifiedAt: localArchive.manifest.uploadedAt), for: brain.id)
            setState(.synced, for: brain.id)
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func downloadCloudWinner(brain: BrainDescriptor, library: BrainLibrary) async {
        setState(.downloading, for: brain.id)
        do {
            let manifest = try await store.loadManifest(brainID: brain.id) ?? {
                throw BrainSyncError.missingArchive
            }()
            try await downloadCloudArchive(brain: brain, cloudManifest: manifest)
            library.refresh()
        } catch {
            setState(.failed(error.localizedDescription), for: brain.id)
        }
    }

    private func downloadCloudArchive(brain: BrainDescriptor, cloudManifest: BrainCloudManifest) async throws {
        setState(.downloading, for: brain.id)
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("AffectiveCloudDownload-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archiveURL = scratch.appendingPathComponent(BrainCloudArchive.archiveFileName(for: brain.id))
        let manifest = try await store.downloadArchive(brainID: brain.id, to: archiveURL)
        guard manifest.archiveHash == cloudManifest.archiveHash else {
            throw BrainSyncError.invalidArchive
        }
        let restoredRoot = scratch.appendingPathComponent(brain.id, isDirectory: true)
        _ = try await BrainLibrary.importBrainFileWithCore(from: archiveURL, to: restoredRoot, expectedBrainID: brain.id)
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

    private func createCloudArchive(
        for brain: BrainDescriptor,
        revision: Int?,
        includeBiometricData: Bool
    ) async throws -> BrainCloudArchive.Created {
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("AffectiveBrainArchive-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = scratch.appendingPathComponent(BrainCloudArchive.archiveFileName(for: brain.id))
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)

        let exportRoot = scratch.appendingPathComponent("export-root", isDirectory: true)
        try BrainLibrary.copyBrain(
            from: brain.rootURL,
            to: exportRoot,
            includeBiometricData: includeBiometricData,
            fileManager: fileManager
        )
        _ = try BrainCloudArchive.createArchive(
            from: exportRoot,
            brainID: brain.id,
            to: archiveURL,
            fileManager: fileManager
        )

        let archiveHash = try BrainCloudArchive.archiveHash(at: archiveURL)
        let modifiedAt = brain.modifiedAt ?? Date()
        return BrainCloudArchive.Created(
            archiveURL: archiveURL,
            scratchRoot: scratch,
            manifest: BrainCloudManifest(
                brainID: brain.id,
                displayName: brain.displayName,
                schemaVersion: Self.schemaVersion,
                archiveHash: archiveHash,
                createdAt: modifiedAt,
                modifiedAt: modifiedAt,
                uploadedAt: Date(),
                deviceID: deviceID,
                revision: revision ?? 0
            )
        )
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

nonisolated struct ICloudBrainArchiveStore: BrainCloudArchiveStore {
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
            let archiveURL = root.appendingPathComponent(BrainCloudArchive.archiveFileName(for: manifest.brainID))
            guard fileManager.fileExists(atPath: manifestURL.path),
                  fileManager.fileExists(atPath: archiveURL.path) else {
                return .syncing
            }
            if Self.isUbiquitousItemStillSyncing(manifestURL) || Self.isUbiquitousItemStillSyncing(archiveURL) {
                return .syncing
            }

            do {
                let data = try Data(contentsOf: archiveURL)
                let hash = BrainCloudArchive.sha256Hex(data)
                guard hash == manifest.archiveHash else {
                    return .invalid("The archive checksum does not match its manifest.")
                }
                try BrainCloudArchive.validateArchiveData(data)
                return .available
            } catch let error as BrainSyncError {
                return .invalid(error.localizedDescription)
            } catch {
                return .invalid(error.localizedDescription)
            }
        }
    }

    func downloadArchive(brainID: String, to localURL: URL) async throws -> BrainCloudManifest {
        try await performFileAccess { root, fileManager in
            let manifestURL = root.appendingPathComponent("\(brainID).manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw BrainSyncError.missingArchive
            }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder.brainSync.decode(BrainCloudManifest.self, from: data)
            let archiveURL = root.appendingPathComponent(BrainCloudArchive.archiveFileName(for: brainID))
            guard fileManager.fileExists(atPath: archiveURL.path) else {
                throw BrainSyncError.missingArchive
            }
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: archiveURL, to: localURL)
            return manifest
        }
    }

    func uploadArchive(from localURL: URL, manifest: BrainCloudManifest) async throws {
        try await performFileAccess { root, fileManager in
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let archiveURL = root.appendingPathComponent(BrainCloudArchive.archiveFileName(for: manifest.brainID))
            let manifestURL = root.appendingPathComponent("\(manifest.brainID).manifest.json")
            let archiveTempURL = root.appendingPathComponent(".\(manifest.brainID).brain.uploading-\(UUID().uuidString)")
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

nonisolated enum BrainCloudArchive {
    struct Created {
        var archiveURL: URL
        var scratchRoot: URL
        var manifest: BrainCloudManifest
    }

    private static let magic = Data([0x41, 0x46, 0x46, 0x45, 0x43, 0x54, 0x49, 0x56, 0x45, 0x5F, 0x42, 0x52, 0x41, 0x49, 0x4E, 0x00, 0x01])
    private static let excludedComponentNames: Set<String> = [
        "provider_credentials.json",
        "secrets.json",
        "pairing_secrets.json",
        "host_permissions.json",
        "host_permission_grants.json",
        "host_pairing.json",
        "pairing_secret",
    ]

    static func archiveFileName(for brainID: String) -> String {
        "\(brainID).brain"
    }

    static func archiveHash(at archiveURL: URL) throws -> String {
        try sha256Hex(Data(contentsOf: archiveURL))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateArchiveData(_ data: Data) throws {
        guard data.starts(with: magic) else {
            throw BrainSyncError.invalidArchive
        }
    }

    static func createArchive(
        from rootURL: URL,
        brainID: String,
        to archiveURL: URL,
        fileManager: FileManager = .default
    ) throws -> JSONValue {
        var components: [[String: Any]] = []
        var totalBytes = 0
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BrainSyncError.invalidArchive
        }

        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
            if shouldExclude(relativePath) {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: fileURL)
            totalBytes += data.count
            components.append([
                "path": relativePath,
                "bytes": data.count,
                "sha256": sha256Hex(data),
                "data_base64": data.base64EncodedString(),
            ])
        }

        components.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        let archive: [String: Any] = [
            "format_version": 1,
            "compression": "zlib",
            "brain_id": brainID,
            "brain_settings": ["brain_id": brainID],
            "component_count": components.count,
            "total_bytes": totalBytes,
            "components": components,
        ]
        let json = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        var output = magic
        output.append(try zlibCompress(json))
        try output.write(to: archiveURL, options: .atomic)
        return try manifestValue(brainID: brainID, components: components)
    }

    static func extractArchive(
        from archiveURL: URL,
        to destinationRoot: URL,
        expectedBrainID: String? = nil,
        fileManager: FileManager = .default
    ) throws -> (brainID: String, manifest: JSONValue) {
        let data = try Data(contentsOf: archiveURL)
        try validateArchiveData(data)
        let jsonData = try zlibDecompress(data.dropFirst(magic.count))
        guard let archive = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let brainID = archive["brain_id"] as? String,
              let components = archive["components"] as? [[String: Any]]
        else {
            throw BrainSyncError.invalidArchive
        }
        if let expectedBrainID, expectedBrainID != brainID {
            throw BrainSyncError.invalidArchive
        }
        guard !fileManager.fileExists(atPath: destinationRoot.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for component in components {
            guard let relativePath = component["path"] as? String,
                  isSafeRelativePath(relativePath),
                  let encoded = component["data_base64"] as? String,
                  let bytes = Data(base64Encoded: encoded)
            else {
                throw BrainSyncError.invalidArchive
            }
            if let expectedBytes = component["bytes"] as? Int, expectedBytes != bytes.count {
                throw BrainSyncError.invalidArchive
            }
            if let expectedHash = component["sha256"] as? String, expectedHash != sha256Hex(bytes) {
                throw BrainSyncError.invalidArchive
            }
            let destination = destinationRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
        }
        return (brainID, try manifestValue(brainID: brainID, components: components))
    }

    private static func shouldExclude(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { excludedComponentNames.contains(String($0)) }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private static func manifestValue(brainID: String, components: [[String: Any]]) throws -> JSONValue {
        let infos = components.map { component -> [String: Any] in
            [
                "path": component["path"] as? String ?? "",
                "bytes": component["bytes"] as? Int ?? 0,
                "sha256": component["sha256"] as? String ?? "",
            ]
        }
        let totalBytes = infos.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) }
        let manifest: [String: Any] = [
            "format_version": 1,
            "compression": "zlib",
            "brain_id": brainID,
            "component_count": infos.count,
            "total_bytes": totalBytes,
            "components": infos,
        ]
        return try .object(JSONValue.decodedObject(from: try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])))
    }

    private static func zlibCompress(_ data: Data) throws -> Data {
        let outputCapacity = max(8192, data.count + data.count / 8 + data.count / 16 + 4096)
        var output = Data(count: outputCapacity)
        let written = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    outputCapacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw BrainSyncError.invalidArchive }
        output.count = written
        return output
    }

    private static func zlibDecompress(_ data: Data.SubSequence) throws -> Data {
        let input = Data(data)
        var capacity = max(8192, input.count * 4)
        while capacity <= 1024 * 1024 * 1024 {
            let outputCapacity = capacity
            var output = Data(count: capacity)
            let written = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        outputCapacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 && written < outputCapacity {
                output.count = written
                return output
            }
            capacity *= 2
        }
        throw BrainSyncError.invalidArchive
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
