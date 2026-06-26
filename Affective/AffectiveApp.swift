//
//  AffectiveApp.swift
//  Affective
//
//  Created by Zelda Hessler on 6/24/26.
//

import SQLite3
import SwiftUI
#if canImport(ImageIO)
import ImageIO
#endif

@main
struct AffectiveApp: App {
    init() {
        #if DEBUG
        AffectiveUITestHarness.prepareLaunchIfNeeded()
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
            if AffectiveUITestHarness.isRecognitionFlowEnabled {
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
enum AffectiveUITestHarness {
    private static let recognitionLaunchArgument = "-AffectiveUITestRecognizeFlow"
    private static let fixtureBrainID = "ios-recognition-e2e"

    static var isRecognitionFlowEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(recognitionLaunchArgument)
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
        try Data().write(to: root.appendingPathComponent("events.jsonl"), options: .atomic)
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
        PRAGMA user_version = 2;
        CREATE TABLE IF NOT EXISTS cognitive_memory (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            schema_version INTEGER NOT NULL,
            data_json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }

        let dataJSON = """
        {
          "schema_version": 2,
          "traces": [],
          "beliefs": [],
          "subjects": [],
          "artifacts": [],
          "dreams": []
        }
        """
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statement: OpaquePointer?
        let insertSQL = """
        INSERT INTO cognitive_memory (id, schema_version, data_json)
        VALUES (1, 2, ?)
        ON CONFLICT(id) DO UPDATE SET schema_version = excluded.schema_version, data_json = excluded.data_json
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
        let captureCount = model.commandEntries.filter { $0.title == "camera sense" }.count
        let subjectCount = subjects.count
        let maraSightings = (mara?["sighting_count"] as? NSNumber)?.intValue ?? 0
        let maraRecords = (mara?["biometric_records"] as? [[String: Any]])?.count ?? 0
        let lastCommand = model.commandEntries.last.map {
            "\($0.title): \($0.body)"
        } ?? "none"
        let compactLastCommand = lastCommand
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(180)
        return "Recognition status: captures=\(captureCount) subjects=\(subjectCount) embeddings=\(embeddingCount) mara_records=\(maraRecords) mara_sightings=\(maraSightings) last=\(compactLastCommand)"
    }

    static func ensureRecognitionSubject(named name: String, in brain: BrainDescriptor) throws {
        let url = brain.memoryDatabaseURL
        var memory = (try? readRecognitionMemory(at: url)) ?? [
            "schema_version": 2,
            "traces": [],
            "beliefs": [],
            "subjects": [],
            "artifacts": [],
            "dreams": [],
        ]
        var subjects = memory["subjects"] as? [[String: Any]] ?? []
        if subjects.contains(where: { ($0["display_name"] as? String) == name }) {
            return
        }
        let createdAt = ISO8601DateFormatter().string(from: Date())
        subjects.append([
            "subject_id": "person_001",
            "display_name": name,
            "relationship_status": "known",
            "biometric_records": [],
            "lifecycle": [
                "created_at": createdAt,
                "updated_at": createdAt,
            ],
        ])
        memory["subjects"] = subjects
        memory["schema_version"] = 2
        try writeRecognitionMemory(memory, to: url)
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

    private static func writeRecognitionMemory(_ memory: [String: Any], to url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }

        let jsonData = try JSONSerialization.data(withJSONObject: memory, options: [.prettyPrinted, .sortedKeys])
        let json = String(decoding: jsonData, as: UTF8.self)
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO cognitive_memory (id, schema_version, data_json)
        VALUES (1, 2, ?)
        ON CONFLICT(id) DO UPDATE SET schema_version = excluded.schema_version, data_json = excluded.data_json
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, json, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
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
                    ForEach(model.commandEntries) { entry in
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
            model.appendCommand(kind: .sent, title: "camera sense", body: storedImage.url.path, metadata: metadata)
            latestCapturedImagePath = storedImage.url.path
            _ = try await model.brainCore.cameraObservation(
                path: storedImage.url.path,
                mimeType: storedImage.mimeType,
                source: "affective_requested_capture",
                requestID: nil,
                presentation: .log
            )

            let result = try FaceRecognitionService().identify(.init(
                imagePath: storedImage.url.path,
                memoryPath: model.brain.memoryDatabaseURL.path,
                embeddingsDir: model.brain.faceEmbeddingsURL.path,
                detectorModel: nil,
                recognizerModel: nil,
                knownThreshold: 0.85,
                uncertainThreshold: 0.60
            ))
            latestRecognitionMatch = result.matchStatus
            if result.candidateName == "Mara", result.matchStatus == "known" || result.matchStatus == "uncertain" {
                maraRecognitionHits += 1
            }
            refreshRecognitionStatus()
        } catch {
            latestRecognitionMatch = "error"
            model.appendCommand(kind: .error, title: "recognition e2e failed", body: error.localizedDescription)
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
            try AffectiveUITestHarness.ensureRecognitionSubject(named: "Mara", in: model.brain)
            let result = try FaceRecognitionService().enroll(.init(
                imagePath: imagePath,
                memoryPath: model.brain.memoryDatabaseURL.path,
                embeddingsDir: model.brain.faceEmbeddingsURL.path,
                detectorModel: nil,
                recognizerModel: nil,
                personID: nil,
                name: "Mara",
                keepExisting: false
            ))
            model.appendCommand(
                kind: .result,
                title: "register face",
                body: "Registered \(result.displayName ?? result.personID) embedding at \(result.embeddingPath)"
            )
            refreshRecognitionStatus()
        } catch {
            model.appendCommand(kind: .error, title: "registration e2e failed", body: error.localizedDescription)
            refreshRecognitionStatus()
        }
    }

    private func refreshRecognitionStatus() {
        recognitionStatus = "\(AffectiveUITestHarness.recognitionStatus(for: model)) direct_match=\(latestRecognitionMatch) mara_hits=\(maraRecognitionHits)"
    }
}
#endif
