//
//  AffectiveApp.swift
//  Affective
//
//  Created by Zelda Hessler on 6/24/26.
//

import SQLite3
import SwiftUI
import Darwin
#if os(macOS)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif

@main
struct AffectiveApp: App {
    init() {
        SystemBrainSpeechNotificationService.shared.registerDelegateIfNeeded()
        AppleSpeechVoiceCatalog.preloadIfNeeded()
        AffectiveUnitTestHarness.prepareLaunchIfNeeded()
        #if DEBUG
        AffectiveSmokeTestHarness.prepareLaunchIfNeeded()
        AffectiveUITestHarness.prepareLaunchIfNeeded()
        AffectiveSmokeTestHarness.runAndExitIfNeeded()
        #endif
    }

    var body: some Scene {
        mainWindow
        #if os(macOS)
        avatarEditorWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            #if DEBUG
            if AffectiveUnitTestHarness.isEnabled {
                UnitTestHostPlaceholderView()
            } else if AffectiveUITestHarness.isRecognitionFlowEnabled {
                AffectiveUITestRecognitionFlowView()
            } else {
                ContentView()
                    #if os(macOS)
                    .configureWindow(minSize: NSSize(width: 900, height: 620))
                    #endif
            }
            #else
            ContentView()
                #if os(macOS)
                .configureWindow(minSize: NSSize(width: 900, height: 620))
                #endif
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 860)
        .commands {
            AvatarEditorCommands()
        }
        #endif
    }

    #if os(macOS)
    private var avatarEditorWindow: some Scene {
        WindowGroup("Avatar Editor", id: "avatar-editor", for: String.self) { $brainID in
            AvatarEditorWindow(brainID: brainID?.isEmpty == false ? brainID : nil)
                .configureWindow(minSize: NSSize(width: 1060, height: 760))
        }
        .defaultSize(width: 1120, height: 780)
    }
    #endif
}

#if os(macOS)
private struct WindowConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(view.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.minSize = minSize
        window.contentMinSize = minSize
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
}

private extension View {
    func configureWindow(minSize: NSSize) -> some View {
        background(WindowConfigurator(minSize: minSize))
    }
}

private struct AvatarEditorCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AffectiveViewModel.lastOpenedBrainIDKey) private var lastOpenedBrainID = ""

    var body: some Commands {
        CommandMenu("View") {
            Button("Avatar Editor") {
                openWindow(id: "avatar-editor", value: lastOpenedBrainID)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
#endif

#if DEBUG
private struct UnitTestHostPlaceholderView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            #if os(macOS)
            .background(UnitTestHostWindowConfigurator())
            #endif
    }
}

#if os(macOS)
private struct UnitTestHostWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(view.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.accessory)
        window?.setIsVisible(false)
        window?.orderOut(nil)
    }
}
#endif
#endif

enum AffectiveUnitTestHarness {
    /// True when `AffectiveTests` is injected into the app host process.
    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains { argument in
            argument.hasPrefix("-XCTest")
        }
        #else
        return false
        #endif
    }

    static func prepareLaunchIfNeeded() {
        #if DEBUG
        guard isEnabled else { return }
        UserDefaults.standard.set(true, forKey: "Affective.didBypassCredentialWelcome")
        AppleSpeechVoiceCatalog.preloadIfNeeded()
        #endif
    }
}

#if DEBUG
enum AffectiveSmokeTestHarness {
    private static let launchArgument = "-AffectiveSmokeTestLaunch"
    private static let storageRootName = "AffectiveSmokeTest"
    private static let brainID = "affective-smoke-brain"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            || ProcessInfo.processInfo.environment["AFFECTIVE_SMOKE_TEST"] == "1"
    }

    static func prepareLaunchIfNeeded() {
        guard isEnabled else { return }
        BrainLibrary.storageRootURLOverride = storageRootURL
        UserDefaults.standard.set(true, forKey: "Affective.didBypassCredentialWelcome")
    }

    static func runAndExitIfNeeded() {
        guard isEnabled else { return }
        Task {
            do {
                try await run()
                fputs("AFFECTIVE_SMOKE_TEST: PASS\n", stderr)
                Darwin.exit(0)
            } catch {
                fputs("AFFECTIVE_SMOKE_TEST: FAIL \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
    }

    private static func run() async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: storageRootURL)
        try fileManager.createDirectory(at: BrainLibrary.brainsRootURL, withIntermediateDirectories: true)

        let brainRoot = BrainLibrary.brainsRootURL.appendingPathComponent(brainID, isDirectory: true)
        try BrainLibrary.createMinimalBrainRoot(at: brainRoot, id: brainID, displayName: "Affective Smoke Brain")
        try writeSmokeRuntimeOptions(at: brainRoot.appendingPathComponent("runtime_options.json"))
        try writeCanonicalCognitiveStore(at: brainRoot.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("people.sqlite"))

        let brain = BrainDescriptor(
            id: brainID,
            displayName: "Affective Smoke Brain",
            rootURL: brainRoot,
            avatarURL: nil,
            avatarManifest: nil,
            modifiedAt: nil,
            isRecent: true
        )
        let core = BrainCore(brain: brain)
        log("connect")
        try await core.connect()
        defer {
            Task {
                await core.disconnect()
            }
        }

        log("memory seed event")
        _ = try await core.sendExperienceEvent(
            hostID: "smoke-host",
            source: "host",
            kind: "Smoke.MemorySeed",
            payload: "remember: the smoke test likes mailbox dreams and careful recognition corrections",
            salience: 0.75,
            confidence: 0.9,
            valence: 0.2,
            arousal: 0.2,
            uncertainty: 0.1,
            causalParentIDs: [],
            retention: "durable",
            visibility: "internal"
        )
        log("conversation turn")
        _ = try await core.sendText(
            "Hello from the real app smoke test. Please acknowledge this as a normal conversation turn.",
            source: .typedText,
            attachments: [],
            stimulusContext: nil
        )
        log("identity correction event")
        _ = try await core.sendExperienceEvent(
            hostID: "smoke-host",
            source: "host",
            kind: "User.IdentityCorrection",
            payload: "correction: the person in this smoke scenario is Zelda, not an unknown visitor",
            salience: 0.8,
            confidence: 0.95,
            valence: 0.1,
            arousal: 0.2,
            uncertainty: 0.05,
            causalParentIDs: [],
            retention: "durable",
            visibility: "public"
        )

        log("dream time")
        let dreamResponse = try await core.requestDreamTime(prompt: "Smoke test dream over the conversation, memory seed, and correction.")
        guard !dreamResponse.item.mailboxID.isEmpty else {
            throw SmokeTestError.missingMailboxDream
        }
        log("mailbox list")
        let mailboxResponse = try await core.mailboxList()
        guard mailboxResponse.items.contains(where: { $0.mailboxID == dreamResponse.item.mailboxID }) else {
            throw SmokeTestError.missingMailboxDream
        }
        log("mailbox mark read")
        _ = try await core.mailboxMarkRead(mailboxID: dreamResponse.item.mailboxID)

        log("export brain")
        let exportURL = storageRootURL.appendingPathComponent("smoke.brainarchive")
        _ = try BrainCloudArchive.createArchive(from: brainRoot, brainID: brainID, to: exportURL)
        guard fileManager.fileExists(atPath: exportURL.path) else {
            throw SmokeTestError.missingExportArchive
        }
        log("import brain")
        let importedRoot = storageRootURL.appendingPathComponent("imported-brain", isDirectory: true)
        _ = try BrainCloudArchive.extractArchive(from: exportURL, to: importedRoot, expectedBrainID: brainID)
        guard fileManager.fileExists(atPath: importedRoot.appendingPathComponent("brain_profile.json").path) else {
            throw SmokeTestError.missingImportedBrain
        }
    }

    private static func log(_ step: String) {
        fputs("AFFECTIVE_SMOKE_TEST: \(step)\n", stderr)
    }

    private static func writeCanonicalCognitiveStore(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }

        let schemaSQL = """
        PRAGMA user_version = 1;
        CREATE TABLE IF NOT EXISTS cognitive_memory (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            data_json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        let dataJSON = """
        {
          "schema_version": 1
        }
        """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO cognitive_memory (id, data_json)
        VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json
        """
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, dataJSON, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func writeSmokeRuntimeOptions(at url: URL) throws {
        let credentials = CoreConfigStorage.providerCredentials()
        let provider: HostTextProviderPreference
        if credentials[.openAI] != nil {
            provider = .openAI
        } else if credentials[.anthropic] != nil {
            provider = .anthropic
        } else if credentials[.google] != nil {
            provider = .google
        } else if credentials[.deepseek] != nil {
            provider = .deepseek
        } else {
            provider = .random
        }
        let data = try JSONSerialization.data(withJSONObject: [
            AffectiveViewModel.textProviderPreferenceOptionKey: provider.rawValue,
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static var storageRootURL: URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure("Application Support directory unavailable")
        }
        return applicationSupport
            .appendingPathComponent("Affective", isDirectory: true)
            .appendingPathComponent(storageRootName, isDirectory: true)
    }

    private enum SmokeTestError: LocalizedError {
        case missingMailboxDream
        case missingExportArchive
        case missingImportedBrain

        var errorDescription: String? {
            switch self {
            case .missingMailboxDream:
                return "Dream Time did not deliver a mailbox dream."
            case .missingExportArchive:
                return "Brain export did not create an archive."
            case .missingImportedBrain:
                return "Brain import did not create a usable brain root."
            }
        }
    }
}

enum AffectiveUITestHarness {
    private static let recognitionLaunchArgument = "-AffectiveUITestRecognizeFlow"
    private static let recognitionLaunchEnvironmentKey = "AFFECTIVE_UI_TEST_RECOGNIZE_FLOW"
    private static let fixtureBrainID = "ios-recognition-e2e"

    static var isRecognitionFlowEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(recognitionLaunchArgument)
            || ProcessInfo.processInfo.environment[recognitionLaunchEnvironmentKey] == "1"
    }

    static func prepareLaunchIfNeeded() {
        guard isRecognitionFlowEnabled else { return }
        BrainLibrary.storageRootURLOverride = recognitionStorageRootURL
        UserDefaults.standard.set(true, forKey: "Affective.didBypassCredentialWelcome")
        do {
            try createRecognitionFixtureBrain()
        } catch {
            assertionFailure("Failed to prepare iOS recognition UI test fixture: \(error)")
        }
    }

    @MainActor
    static func brainToOpenIfNeeded(from brains: [BrainDescriptor]) -> BrainDescriptor? {
        guard isRecognitionFlowEnabled else { return nil }
        return brains.first { $0.id == fixtureBrainID }
    }

    static func brainCoreIfNeeded() -> (any BrainCoreClient)? {
        nil
    }

    static func recognitionFixtureBrainDescriptor() -> BrainDescriptor {
        BrainDescriptor(
            id: fixtureBrainID,
            displayName: "Recognition E2E",
            rootURL: BrainLibrary.brainsRootURL.appendingPathComponent(fixtureBrainID, isDirectory: true),
            avatarURL: nil,
            avatarManifest: nil,
            modifiedAt: nil,
            isRecent: true
        )
    }

    @MainActor
    static func configure(_ model: AffectiveViewModel) {
        guard isRecognitionFlowEnabled else { return }
        model.selectedSection = .developer
        model.cameraPermissionRequestTask = Task { .available }
        var fixtureIndex = 0
        model.cameraPhotoCaptureOverride = {
            let names = ["known_01", "known_changed_01", "unknown_01"]
            let name = names[min(fixtureIndex, names.count - 1)]
            fixtureIndex += 1
            return try Self.fixtureCameraImageData(named: name)
        }
    }

    private static func fixtureCameraImageData(named name: String) throws -> Data {
        let data = try fixtureImageData(named: name)
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output as Data
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private static func createRecognitionFixtureBrain() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: recognitionStorageRootURL)
        let root = BrainLibrary.brainsRootURL.appendingPathComponent(fixtureBrainID, isDirectory: true)

        let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
        let faceEmbeddingsURL = memoryURL.appendingPathComponent("face_embeddings", isDirectory: true)
        try fileManager.createDirectory(at: faceEmbeddingsURL, withIntermediateDirectories: true)

        let profile: [String: Any] = [
            "schema_version": 1,
            "display_name": "Recognition E2E",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "notes": "Fixture brain for iOS recognition UI tests."
        ]
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
        try profileData.write(to: root.appendingPathComponent("brain_profile.json"), options: .atomic)
        let runtimeOptions: [String: Any] = [
            BiometricPolicyKeys.recognitionEnabled: true,
            BiometricPolicyKeys.policyAcknowledged: true,
            BiometricPolicyKeys.enrollmentAllowed: true,
            BiometricPolicyKeys.retentionPeriod: BiometricDataPolicy.defaultRetentionPeriod,
            BiometricPolicyKeys.exportIncluded: false,
            BiometricPolicyKeys.exportConfirmationRequired: true,
            BiometricPolicyKeys.autoDeleteUnconfirmed: true,
        ]
        let runtimeData = try JSONSerialization.data(withJSONObject: runtimeOptions, options: [.prettyPrinted, .sortedKeys])
        try runtimeData.write(to: root.appendingPathComponent("runtime_options.json"), options: .atomic)
        try writeRecognitionMemoryStore(at: root.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("people.sqlite"))
        try "# Recognition E2E Maintenance\n".write(
            to: root.appendingPathComponent("maintenance.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func fixtureImageData(named name: String) throws -> Data {
        let subdirectories = [
            "Resources/UITestRecognitionFixtures",
            "UITestRecognitionFixtures",
        ]
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return try Data(contentsOf: url)
        }
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdirectory) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func writeRecognitionMemoryStore(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }

        let schemaSQL = """
        PRAGMA user_version = 1;
        CREATE TABLE IF NOT EXISTS cognitive_memory (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            data_json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        let dataJSON = """
        {
          "schema_version": 1
        }
        """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO cognitive_memory (id, data_json)
        VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json
        """
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, dataJSON, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor
    static func recognitionStatus(for model: AffectiveViewModel) -> String {
        let brain = model.brain
        let memory = (try? readRecognitionMemory(at: brain.memoryDatabaseURL)) ?? [:]
        let subjects = memory["subjects"] as? [[String: Any]] ?? []
        let mara = subjects.first {
            ($0["display_name"] as? String) == "Mara"
        }
        let embeddingCount = recognitionEmbeddingCount(in: brain.faceEmbeddingsURL)
        let captureCount = model.eventEntries.filter { $0.title == "camera sense" }.count
        let subjectCount = subjects.count
        let maraSightings = (mara?["sighting_count"] as? NSNumber)?.intValue ?? 0
        let maraRecords = (mara?["biometric_records"] as? [[String: Any]])?.count ?? 0
        let lastEvent = model.eventEntries.last.map {
            "\($0.title): \($0.body)"
        } ?? "none"
        let compactLastEvent = lastEvent
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(180)
        return "Recognition status: captures=\(captureCount) subjects=\(subjectCount) embeddings=\(embeddingCount) mara_records=\(maraRecords) mara_sightings=\(maraSightings) last=\(compactLastEvent)"
    }

    private static func recognitionEmbeddingCount(in url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "npy" }.count
    }

    private static func readRecognitionMemory(at url: URL) throws -> [String: Any] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return [:]
        }
        let data = Data(String(cString: textPointer).utf8)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static var recognitionStorageRootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AffectiveUITests-RecognitionFlow", isDirectory: true)
    }
}

@MainActor
private struct AffectiveUITestRecognitionFlowView: View {
    @StateObject private var model: AffectiveViewModel
    @State private var recognitionStatus = "Recognition status: connecting"
    @State private var latestRecognitionMatch = "none"
    @State private var latestCapturedImagePath: String?
    @State private var maraRecognitionHits = 0

    init() {
        let viewModel = AffectiveViewModel(
            brain: AffectiveUITestHarness.recognitionFixtureBrainDescriptor()
        )
        AffectiveUITestHarness.configure(viewModel)
        _model = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recognition E2E")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Recognize") {
                    Task {
                        await recognizeFixtureImage()
                    }
                }
                .accessibilityIdentifier("recognize-ui-test-button")

                Button("Register") {
                    Task {
                        await registerLatestFixtureImage()
                    }
                }
                .accessibilityIdentifier("register-ui-test-button")
            }

            Text(recognitionStatus)
                .accessibilityIdentifier("recognition-e2e-status")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.eventEntries) { entry in
                        Text(entry.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.chatEntries) { entry in
                        Text(entry.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.connectToBrain()
            recognitionStatus = "Recognition status: ready captures=0 subjects=0 embeddings=0 mara_records=0 mara_sightings=0"
        }
    }

    private func recognizeFixtureImage() async {
        do {
            let data = try await model.captureWebcamPhotoData()
            let imageInfo = try model.validateCapturedImageData(data)
            let storedImage = try model.storeChatImage(data: data, suggestedName: "recognition-e2e-\(UUID().uuidString)")
            let metadata = [
                "media_kind": "image",
                "image_path": storedImage.url.path,
                "mime_type": storedImage.mimeType,
                "source": "affective_requested_capture",
                "byte_count": "\(data.count)",
                "pixel_width": "\(imageInfo.width)",
                "pixel_height": "\(imageInfo.height)",
            ]
            model.appendEventLog(kind: .sent, title: "camera sense", body: storedImage.url.path, metadata: metadata)
            latestCapturedImagePath = storedImage.url.path
            _ = try await model.brainCore.cameraObservation(
                path: storedImage.url.path,
                mimeType: storedImage.mimeType,
                source: "affective_requested_capture",
                requestID: nil,
                presentation: .log
            )

            latestRecognitionMatch = "core_observed"
            refreshRecognitionStatus()
        } catch {
            latestRecognitionMatch = "error"
            model.appendEventLog(kind: .error, title: "recognition e2e failed", body: error.localizedDescription)
            refreshRecognitionStatus()
        }
    }

    private func registerLatestFixtureImage() async {
        do {
            guard let imagePath = latestCapturedImagePath else {
                throw NSError(
                    domain: "AffectiveUITestRecognitionFlow",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no captured image available to register"]
                )
            }
            _ = try await model.brainCore.sendExperienceEvent(
                hostID: "recognition-e2e-host",
                source: "user",
                kind: "User.IdentityCorrection",
                payload: "correction: the person in the latest camera observation at \(imagePath) is Mara",
                salience: 0.8,
                confidence: 0.95,
                valence: 0.1,
                arousal: 0.2,
                uncertainty: 0.05,
                causalParentIDs: [],
                retention: "durable",
                visibility: "public"
            )
            latestRecognitionMatch = "core_corrected"
            maraRecognitionHits += 1
            model.appendEventLog(
                kind: .result,
                title: "identity correction",
                body: "Sent core identity correction for Mara using \(imagePath)"
            )
            refreshRecognitionStatus()
        } catch {
            model.appendEventLog(kind: .error, title: "registration e2e failed", body: error.localizedDescription)
            refreshRecognitionStatus()
        }
    }

    private func refreshRecognitionStatus() {
        recognitionStatus = "\(AffectiveUITestHarness.recognitionStatus(for: model)) core_match=\(latestRecognitionMatch) correction_events=\(maraRecognitionHits)"
    }
}
#endif
