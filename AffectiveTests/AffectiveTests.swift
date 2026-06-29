//
//  AffectiveTests.swift
//  AffectiveTests
//

import XCTest
import AppIntents
import CoreSpotlight
import SQLite3
#if canImport(ImageIO)
import ImageIO
#endif

@testable import Affective

final class AffectiveTests: XCTestCase {
  private var temporaryRoots: [URL] = []

  override func setUpWithError() throws {
    let libraryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveTests-Library-\(UUID().uuidString)", isDirectory: true)
    BrainLibrary.storageRootURLOverride = libraryRoot
    temporaryRoots.append(libraryRoot)
    UserDefaults.standard.removeObject(forKey: AffectiveViewModel.brainVoiceEnabledKey)
    UserDefaults.standard.removeObject(forKey: AffectiveViewModel.orientationPermissionStatusKey)
  }

  override func tearDownWithError() throws {
    UserDefaults.standard.removeObject(forKey: AffectiveViewModel.brainVoiceEnabledKey)
    UserDefaults.standard.removeObject(forKey: AffectiveViewModel.orientationPermissionStatusKey)
    for url in temporaryRoots {
      try? FileManager.default.removeItem(at: url)
    }
    temporaryRoots = []
    BrainLibrary.storageRootURLOverride = nil
  }

  func testValidBrainShapePassesCoreValidation() throws {
    let brain = try makeBrain()

    XCTAssertNoThrow(try brain.validateForCoreConnection())
  }

  func testBrainCoreHasNoOperationFallbackRuntimePath() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sourceURL = projectRoot.appendingPathComponent("Affective/Core/BrainCore.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("unavailable(operation:"))
    XCTAssertFalse(source.contains("func unavailable(operation:"))
    XCTAssertFalse(source.contains("#if os(iOS) || os(macOS)"))
    XCTAssertFalse(source.contains("api_e2e needs the AffectiveCore Zig core linked"))
  }

  func testBrainLibraryUsesOnlyCoreBrainArchivesForImportExport() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let checkedFiles = [
      "Affective/BrainLibrary.swift",
      "Affective/Views/BrainLibrary/BrainHomeView.swift",
      "Affective/Views/BrainLibrary/BrainCardViews.swift",
    ]
    let forbidden = [
      "importBrain" + "Folder",
      "importBrain" + "Directory",
      "exportBrain" + "Folder",
      "Export " + "Folder",
    ]

    for relativePath in checkedFiles {
      let sourceURL = projectRoot.appendingPathComponent(relativePath)
      let source = try String(contentsOf: sourceURL, encoding: .utf8)
      for token in forbidden {
        XCTAssertFalse(source.contains(token), "\(relativePath) still contains \(token)")
      }
    }
  }

  @MainActor
  func testMailboxReadsBrainOwnedItemsAndPersistsOnlyHostUIState() async throws {
    let brain = try makeBrain()
    let item = BrainMailboxItem(
      mailboxID: "mail_dream_1",
      kind: "DreamMail",
      title: "Rain Door",
      text: "A dream linked the workshop light to a door opening into rain.",
      imageArtifactID: "artifact_dream_1",
      imageSpecJSON: #"{"subject":"door","mood":"quiet"}"#,
      wakingThought: "Ask before assuming the old pattern is still true.",
      visibleLesson: "Pause before recognition confidence rises.",
      debugDetails: "source=unit-test",
      sourceEventIDs: ["event_day_residue"],
      sourceDreamID: "dream_1",
      createdAtMS: 1_782_515_600_000
    )
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "artifacts": [
        {
          "artifact_id": "artifact_dream_1",
          "kind": "image",
          "path": "generated/images/dream-1.png",
          "mime_type": "image/png",
          "provenance": "dream_time_internal_synthesis",
          "source_event_ids": ["event_dream_artifact"]
        }
      ]
    }
    """)
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "mailbox_list"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      mailboxItems: [item]
    )
    let model = AffectiveViewModel(brain: brain, brainCore: core)

    await model.collectMailboxItems()

    XCTAssertEqual(model.mailboxItems.count, 1)
    XCTAssertEqual(model.mailboxItems.first?.mailboxID, "mail_dream_1")
    XCTAssertEqual(model.mailboxItems.first?.summary, "Rain Door")
    XCTAssertEqual(model.mailboxItems.first?.bodyText, item.text)
    XCTAssertEqual(model.mailboxItems.first?.sourceEventIDs, ["event_day_residue"])
    XCTAssertEqual(model.mailboxItems.first?.artifactID, "artifact_dream_1")
    XCTAssertEqual(model.mailboxItems.first?.imagePath, "generated/images/dream-1.png")
    XCTAssertEqual(model.mailboxItems.first?.imageMimeType, "image/png")
    XCTAssertEqual(model.mailboxItems.first?.imageSpec, item.imageSpecJSON)

    let mailboxItem = try XCTUnwrap(model.mailboxItems.first)
    model.selectMailboxItem(mailboxItem)

    let savedState = MailboxUIStateJournal.load(from: brain.mailboxUIStateURL)
    XCTAssertEqual(savedState.items, [MailboxUIState(mailboxID: "mail_dream_1", isRead: true, isArchived: false)])
    try await Task.sleep(nanoseconds: 50_000_000)
    let markReadIDs = await core.mailboxMarkReadIDs
    XCTAssertEqual(markReadIDs, ["mail_dream_1"])
  }

  func testBrainSemanticEntityUsesStableBrainIdentity() throws {
    guard #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) else {
      throw XCTSkip("Affective semantic entities require IndexedEntity support.")
    }

    let brain = try makeBrain()
    let entity = AffectiveBrainEntity(brain: brain)

    XCTAssertEqual(entity.id, brain.id)
    XCTAssertEqual(entity.name, brain.displayName)
    XCTAssertEqual(entity.rootPath, brain.rootURL.path)
    XCTAssertEqual(entity.attributeSet.identifier, "affective-brain:\(brain.id)")
    XCTAssertEqual(entity.attributeSet.domainIdentifier, AffectiveSemanticSchema.brainDomainIdentifier)
    XCTAssertTrue(entity.attributeSet.keywords?.contains(brain.displayName) == true)
  }

  func testProviderCredentialTesterExtractsJSONErrorMessage() throws {
    let data = Data(#"{"error":{"message":"API key is invalid."}}"#.utf8)

    XCTAssertEqual(
      ProviderCredentialTester.providerErrorMessage(from: data),
      "API key is invalid.")
  }

  func testProviderCredentialTesterExtractsPlainTextErrorMessage() throws {
    let data = Data("  upstream validation failed  \n".utf8)

    XCTAssertEqual(
      ProviderCredentialTester.providerErrorMessage(from: data),
      "upstream validation failed")
  }

  func testFaceRecognitionServiceEnrollsAndIdentifiesFixtureImages() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
      {
        "schema_version": 1,
        "traces": [],
        "beliefs": [],
        "subjects": [
          {
            "subject_id": "person_001",
            "display_name": "Mara",
            "relationship_status": "visitor",
            "stable_notes": [],
            "recent_notes": [],
            "biometric_records": [],
            "representative_image_path": null,
            "representative_quality_score": 0,
            "lifecycle": { "created_at": "1", "updated_at": "1" }
          }
        ],
        "artifacts": [],
        "dreams": []
      }
    """)

    let service = FaceRecognitionService()
    let known = try fixtureURL("known_01", extension: "png", subdirectory: "Fixtures/visitors")
    let changed = try fixtureURL("known_changed_01", extension: "png", subdirectory: "Fixtures/visitors")
    let unknown = try fixtureURL("unknown_01", extension: "png", subdirectory: "Fixtures/visitors")
    try skipPlaceholderImageFixtures([known, changed, unknown])
    let knownCameraImage = try cameraJPEGFixture(from: known, named: "known_01", in: brain.rootURL)
    let changedCameraImage = try cameraJPEGFixture(from: changed, named: "known_changed_01", in: brain.rootURL)
    let unknownCameraImage = try cameraJPEGFixture(from: unknown, named: "unknown_01", in: brain.rootURL)
    XCTAssertEqual(knownCameraImage.pathExtension, "jpg")
    XCTAssertEqual(changedCameraImage.pathExtension, "jpg")
    XCTAssertEqual(unknownCameraImage.pathExtension, "jpg")
    XCTAssertFalse(knownCameraImage.path.contains(".xctest"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: knownCameraImage.path))

    let enroll = try service.enroll(.init(
      imagePath: knownCameraImage.path,
      memoryPath: brain.memoryDatabaseURL.path,
      embeddingsDir: brain.faceEmbeddingsURL.path,
      detectorModel: nil,
      recognizerModel: nil,
      personID: "person_001",
      name: nil,
      keepExisting: false
    ))
    XCTAssertEqual(enroll.personID, "person_001")
    XCTAssertTrue(FileManager.default.fileExists(atPath: enroll.embeddingPath))

    let changedResult = try service.identify(.init(
      imagePath: changedCameraImage.path,
      memoryPath: brain.memoryDatabaseURL.path,
      embeddingsDir: brain.faceEmbeddingsURL.path,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: 0.85,
      uncertainThreshold: 0.60
    ))
    XCTAssertTrue(["known", "uncertain"].contains(changedResult.matchStatus))
    XCTAssertEqual(changedResult.personID, "person_001")

    let unknownResult = try service.identify(.init(
      imagePath: unknownCameraImage.path,
      memoryPath: brain.memoryDatabaseURL.path,
      embeddingsDir: brain.faceEmbeddingsURL.path,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: 0.85,
      uncertainThreshold: 0.60
    ))
    XCTAssertEqual(unknownResult.matchStatus, "unknown")

  }

  func testFaceRecognitionServiceFixtureMatrix() throws {
    guard FaceRecognitionService.bundledModelsAvailable else {
      throw XCTSkip("Bundled ONNX recognition models are not available in this test bundle.")
    }

    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
      {
        "schema_version": 1,
        "traces": [],
        "beliefs": [],
        "subjects": [
          {
            "subject_id": "person_mara",
            "display_name": "Mara",
            "relationship_status": "visitor",
            "stable_notes": [],
            "recent_notes": [],
            "biometric_records": [],
            "representative_image_path": null,
            "representative_quality_score": 0,
            "lifecycle": { "created_at": "1", "updated_at": "1" }
          }
        ],
        "artifacts": [],
        "dreams": []
      }
    """)

    let service = FaceRecognitionService()
    let requestBase = (
      memoryPath: brain.memoryDatabaseURL.path,
      embeddingsDir: brain.faceEmbeddingsURL.path,
      knownThreshold: Float(0.85),
      uncertainThreshold: Float(0.60)
    )

    let emptyRoom = try fixtureURL("empty_room_01", extension: "jpg", subdirectory: "Fixtures/empty")
    try skipPlaceholderImageFixtures([emptyRoom])
    let emptyResult = try service.identify(.init(
      imagePath: emptyRoom.path,
      memoryPath: requestBase.memoryPath,
      embeddingsDir: requestBase.embeddingsDir,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: requestBase.knownThreshold,
      uncertainThreshold: requestBase.uncertainThreshold
    ))
    XCTAssertFalse(emptyResult.personPresent)
    XCTAssertEqual(emptyResult.matchStatus, "none")
    XCTAssertEqual(emptyResult.peopleCount, 0)

    let unknown = try fixtureURL("unknown_01", extension: "png", subdirectory: "Fixtures/visitors")
    try skipPlaceholderImageFixtures([unknown])
    let unknownImage = try cameraJPEGFixture(from: unknown, named: "matrix_unknown_01", in: brain.rootURL)
    let unknownResult = try service.identify(.init(
      imagePath: unknownImage.path,
      memoryPath: requestBase.memoryPath,
      embeddingsDir: requestBase.embeddingsDir,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: requestBase.knownThreshold,
      uncertainThreshold: requestBase.uncertainThreshold
    ))
    XCTAssertTrue(unknownResult.personPresent)
    XCTAssertEqual(unknownResult.matchStatus, "unknown")
    XCTAssertEqual(unknownResult.peopleCount, 1)

    let known = try fixtureURL("known_01", extension: "png", subdirectory: "Fixtures/visitors")
    try skipPlaceholderImageFixtures([known])
    let knownImage = try cameraJPEGFixture(from: known, named: "matrix_known_01", in: brain.rootURL)
    _ = try service.enroll(.init(
      imagePath: knownImage.path,
      memoryPath: requestBase.memoryPath,
      embeddingsDir: requestBase.embeddingsDir,
      detectorModel: nil,
      recognizerModel: nil,
      personID: "person_mara",
      name: nil,
      keepExisting: false
    ))
    let knownResult = try service.identify(.init(
      imagePath: knownImage.path,
      memoryPath: requestBase.memoryPath,
      embeddingsDir: requestBase.embeddingsDir,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: requestBase.knownThreshold,
      uncertainThreshold: requestBase.uncertainThreshold
    ))
    XCTAssertTrue(["known", "uncertain"].contains(knownResult.matchStatus))
    XCTAssertEqual(knownResult.personID, "person_mara")
    XCTAssertEqual(knownResult.candidateName, "Mara")
  }

  @MainActor
  func testSpecialPokeCuriosityIdentifiesUnknownThenEnrollsAfterIntroduction() async throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
      {
        "schema_version": 1,
        "traces": [],
        "beliefs": [],
        "subjects": [
          {
            "subject_id": "person_mara",
            "display_name": "Mara",
            "relationship_status": "introduced",
            "stable_notes": [],
            "recent_notes": ["Introduced herself after a poke-triggered curiosity check."],
            "biometric_records": [],
            "representative_image_path": null,
            "representative_quality_score": 0,
            "lifecycle": { "created_at": "1", "updated_at": "1" }
          }
        ],
        "artifacts": [],
        "dreams": []
      }
    """)

    let visitor = try fixtureURL("known_01", extension: "png", subdirectory: "Fixtures/visitors")
    try skipPlaceholderImageFixtures([visitor])
    let cameraImage = try cameraJPEGFixture(from: visitor, named: "poke-curiosity-mara", in: brain.rootURL)
    let hostServices = EmbeddedHostServices(
      credentialProvider: { [:] },
      providerPicker: { $0.first },
      textProviderPreference: .random,
      textRoutePicker: { $0.first }
    )
    let curiosityResponse = Self.toolResponse(
      toolName: "poke_sequence",
      events: [
        attentionStatusEvent(
          id: "poke-curiosity",
          title: "Curiosity",
          summary: "Curious after a poke; trying to identify the person nearby."
        ),
      ],
      result: .object(["summary": .string("Poke made the brain curious about who is here.")]),
      requestID: "poke-curiosity"
    )
    let core = ScriptedBrainCore(
      toolResponse: curiosityResponse,
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: brain, brainCore: core)
    model.isBrainConnected = true
    model.pendingPokePulses = [
      PokePulse(pressMilliseconds: 120, pauseBeforeMilliseconds: 0),
    ]

    await model.flushPokeSequence()

    let pokes = await waitForPokeSequenceCount(1, in: core)
    XCTAssertEqual(pokes.count, 1)
    XCTAssertEqual(pokes.first?.first?.pressMilliseconds, 120)
    XCTAssertEqual(model.eventEntries.last { $0.title == "Curiosity" }?.body, "Curious after a poke; trying to identify the person nearby.")
    XCTAssertEqual(model.statusText, "Poke sent")

    let identifyBody = try recognitionRequestData([
      "image_path": cameraImage.path,
      "memory_path": brain.memoryDatabaseURL.path,
      "embeddings_dir": brain.faceEmbeddingsURL.path,
      "known_threshold": 0.85,
      "uncertain_threshold": 0.60,
    ])
    let unknownResult: RecognitionIdentityResponse = try postRecognitionResponse(
      body: identifyBody,
      to: "affective-host://recognize/identify",
      using: hostServices
    )
    XCTAssertEqual(unknownResult.personPresent, true)
    XCTAssertEqual(unknownResult.matchStatus, "unknown")
    XCTAssertNil(unknownResult.personID)

    _ = await model.applyCoreEvents([
      expressionEvent(
        title: "Other",
        text: "I'm Mara.",
        expressionID: "mara-introduction-expression",
        role: .other,
        source: .user
      )
    ], mirrorChatMessages: true, speak: false)

    let enrollBody = try recognitionRequestData([
      "image_path": cameraImage.path,
      "memory_path": brain.memoryDatabaseURL.path,
      "embeddings_dir": brain.faceEmbeddingsURL.path,
      "name": "Mara",
      "keep_existing": false,
    ])
    let enrollResult: RecognitionEnrollResponse = try postRecognitionResponse(
      body: enrollBody,
      to: "affective-host://recognize/enroll",
      using: hostServices
    )
    XCTAssertEqual(enrollResult.personID, "person_mara")
    XCTAssertEqual(enrollResult.displayName, "Mara")
    XCTAssertTrue(FileManager.default.fileExists(atPath: enrollResult.embeddingPath))

    let knownResult: RecognitionIdentityResponse = try postRecognitionResponse(
      body: identifyBody,
      to: "affective-host://recognize/identify",
      using: hostServices
    )
    XCTAssertTrue(["known", "uncertain"].contains(knownResult.matchStatus))
    XCTAssertEqual(knownResult.personID, "person_mara")
    XCTAssertEqual(knownResult.candidateName, "Mara")
  }

  func testConversationSemanticEntityUsesBrainScopedIdentifier() throws {
    guard #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) else {
      throw XCTSkip("Affective semantic entities require IndexedEntity support.")
    }

    let entry = LogEntry(
      kind: .brain,
      title: "AMBI",
      body: "I can remember the soldering lesson.",
      metadata: ["brain": "test-brain", "topic": "memory"]
    )
    let entity = AffectiveConversationEntryEntity(entry: entry, brainID: "test-brain")

    XCTAssertEqual(entity.id, entry.id)
    XCTAssertEqual(entity.brainID, "test-brain")
    XCTAssertEqual(entity.attributeSet.identifier, "affective-conversation-entry:test-brain:\(entry.id.uuidString)")
    XCTAssertEqual(entity.attributeSet.relatedUniqueIdentifier, "affective-brain:test-brain")
    XCTAssertEqual(entity.attributeSet.domainIdentifier, AffectiveSemanticSchema.conversationDomainIdentifier)
    XCTAssertTrue(entity.conversationKeywords.contains("memory"))
    XCTAssertFalse(
      AffectiveConversationEntryEntity.self is any IndexedEntity.Type,
      "Conversation entries should not advertise App Intents query support until persisted transcript storage can resolve IDs.")
  }

  func testBrainCoreConnectsToAffectiveCore() async throws {
    let brain = try makeBrain()
    let core = BrainCore(brain: brain)

    try await withConnectedCore(core) {}
  }

  func testEmbeddedProtocolContractMatchesWrapperHostManifest() throws {
    let manifestData = Data(CoreConfigStorage.hostManifestJSON(hasProvider: false).utf8)
    let manifest = try JSONValue.decodedObject(from: manifestData)

    XCTAssertEqual(manifest["max_envelope_bytes"], .number(16 * 1024))
    XCTAssertEqual(manifest["max_event_count"], .number(12))
    XCTAssertEqual(manifest["max_event_text_bytes"], .number(768))
    XCTAssertEqual(manifest["raw_ref_ttl_seconds"], .number(24 * 60 * 60))

    let capabilityValues = try XCTUnwrap(manifest["capabilities"]?.arrayValue)
    let capabilities = Set(capabilityValues.compactMap(\.stringValue))
    XCTAssertEqual(capabilities.count, capabilityValues.count, "Host manifest capabilities should be unique.")

    let policyGatedCapabilities: Set<String> = ["face_identification", "face_enrollment"]
    for capability in EmbeddedProtocolContract.baseHostCapabilities where !policyGatedCapabilities.contains(capability) {
      XCTAssertTrue(
        capabilities.contains(capability),
        "Affective host manifest is missing required embedded capability '\(capability)'.")
    }
    XCTAssertFalse(capabilities.contains("face_identification"))
    XCTAssertFalse(capabilities.contains("face_enrollment"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["face_identification"], .string("disabled_by_policy"))

    for providerCapability in EmbeddedProtocolContract.providerHostCapabilities {
      XCTAssertFalse(
        capabilities.contains(providerCapability),
        "Provider capability '\(providerCapability)' should only be advertised when credentials exist.")
    }

    let providerManifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true).utf8))
    let providerCapabilities = Set(
      try XCTUnwrap(providerManifest["capabilities"]?.arrayValue).compactMap(\.stringValue))
    for providerCapability in EmbeddedProtocolContract.providerHostCapabilities {
      XCTAssertTrue(
        providerCapabilities.contains(providerCapability),
        "Provider-backed host manifest is missing capability '\(providerCapability)'.")
    }
    XCTAssertFalse(providerCapabilities.contains("live_camera"))
    XCTAssertTrue(providerCapabilities.contains("camera_capture"))
    XCTAssertEqual(providerManifest["capability_status"]?.objectValue?["camera"], .string("prompt_required"))

    let senseCatalog = try XCTUnwrap(manifest["sense_catalog"]?.arrayValue)
    let senseObjects = senseCatalog.compactMap(\.objectValue)
    let sensesByID = Dictionary(uniqueKeysWithValues: senseObjects.compactMap { object -> (String, [String: JSONValue])? in
      guard let id = object["sense_id"]?.stringValue else { return nil }
      return (id, object)
    })
    XCTAssertEqual(sensesByID["camera"]?["sense_direction"], .string("pull"))
    XCTAssertEqual(sensesByID["orientation"]?["sense_direction"], .string("pull"))
    XCTAssertEqual(sensesByID["motion_gesture"]?["sense_direction"], .string("push"))
    XCTAssertEqual(sensesByID["time"]?["sense_direction"], .string("pull"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["time"], .string("available"))
  }

  func testHostDateTimeReadingFormatsObservationLines() {
    let reading = HostDateTimeReading(
      datetime: "2026-06-23T12:30:00-05:00",
      datetimeFormat: HostDateTimeReading.iso8601LocalFormat,
      friendlyDatetime: "June 23, 2026 at 12:30 PM",
      friendlyDatetimeFormat: HostDateTimeReading.friendlyFormat,
      unixSeconds: 1_781_222_400
    )

    XCTAssertTrue(reading.observationLines.contains("datetime: 2026-06-23T12:30:00-05:00 (ISO-8601 local)"))
    XCTAssertTrue(
      reading.observationLines.contains("friendly: June 23, 2026 at 12:30 PM (local long date and time)"))

    let now = HostDateTimeReading.now(Date(timeIntervalSince1970: 1_781_222_400))
    XCTAssertFalse(now.datetime.isEmpty)
    XCTAssertFalse(now.friendlyDatetime.isEmpty)
    XCTAssertEqual(now.datetimeFormat, HostDateTimeReading.iso8601LocalFormat)
    XCTAssertEqual(now.friendlyDatetimeFormat, HostDateTimeReading.friendlyFormat)
  }

  func testHostSystemSensesReadingEncodesPowerAndStorage() throws {
    let power = try HostSystemSensesReading.powerSnapshot()
    XCTAssertFalse(power.supplies.isEmpty)
    XCTAssertTrue(power.supplies.contains { $0.kind == "Battery" })

    let powerJSON = try JSONDecoder().decode(
      [String: [[String: JSONValue]]].self,
      from: try HostSystemSensesReading.encodedPowerSnapshot()
    )
    XCTAssertNotNil(powerJSON["supplies"])

    let storage = try HostSystemSensesReading.storageSnapshot()
    XCTAssertEqual(storage.volumes.count, 1)
    XCTAssertEqual(storage.volumes[0].mountPath, HostSystemSensesReading.defaultStorageMountPath)
    XCTAssertGreaterThan(storage.volumes[0].totalBytes, 0)
    XCTAssertGreaterThanOrEqual(storage.volumes[0].availableBytes, 0)
    XCTAssertGreaterThanOrEqual(storage.volumes[0].usedPercent, 0)
    XCTAssertLessThanOrEqual(storage.volumes[0].usedPercent, 100)

    let storageJSON = try JSONDecoder().decode(
      [String: [[String: JSONValue]]].self,
      from: try HostSystemSensesReading.encodedStorageSnapshot()
    )
    XCTAssertNotNil(storageJSON["volumes"])
  }

  func testEmbeddedHostServicesHandlesSystemPowerEndpoint() throws {
    let services = EmbeddedHostServices()
    let response = try services.postJSON(
      url: "affective-host://system/power",
      headersJSON: "[]",
      body: Data("{}".utf8)
    )
    let object = try JSONValue.decodedObject(from: response)
    let supplies = try XCTUnwrap(object["supplies"]?.arrayValue)
    XCTAssertFalse(supplies.isEmpty)
    XCTAssertTrue(
      supplies.contains {
        $0.objectValue?["kind"]?.stringValue == "Battery"
      })
  }

  #if os(iOS)
    func testHostSystemSensesReadingUsesHomeDirectoryOnIOS() throws {
      let storage = try HostSystemSensesReading.storageSnapshot()
      XCTAssertEqual(storage.volumes[0].mountPath, NSHomeDirectory())
    }
  #endif

  func testHostCapabilityManifestOwnsProviderRouting() throws {
    let manifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [.google],
      appleFoundationModelsStatus: .unsupportedPlatform,
      textProviderPreference: .random,
      cameraStatus: "available",
      orientationStatus: "denied"
    )
    let object = try JSONValue.decodedObject(from: Data(manifest.jsonString().utf8))
    let capabilities = Set(
      try XCTUnwrap(object["capabilities"]?.arrayValue).compactMap(\.stringValue))
    let routing = try XCTUnwrap(object["host_provider_routing"]?.objectValue)

    XCTAssertTrue(capabilities.contains("provider_vision_completion"))
    XCTAssertTrue(capabilities.contains("provider_image_generation"))
    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertTrue(capabilities.contains("orientation_read"))
    XCTAssertEqual(object["capability_status"]?.objectValue?["provider_routing"], .string("available"))
    XCTAssertEqual(routing["owner"], .string("host"))
    XCTAssertEqual(routing["mode"], .string("random"))
    XCTAssertEqual(routing["configured_providers"]?.arrayValue, [.string("Google")])
  }

  func testHostCapabilityManifestDoesNotAdvertiseProviderRoutingWithoutProviders() throws {
    let manifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [],
      appleFoundationModelsStatus: .unsupportedPlatform,
      textProviderPreference: .random,
      cameraStatus: "available",
      orientationStatus: "available"
    )
    let object = try JSONValue.decodedObject(from: Data(manifest.jsonString().utf8))
    let capabilities = Set(
      try XCTUnwrap(object["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("provider_vision_completion"))
    XCTAssertFalse(capabilities.contains("provider_vision_completion"))
    XCTAssertFalse(capabilities.contains("provider_image_generation"))
    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertTrue(capabilities.contains("orientation_read"))
    XCTAssertEqual(object["capability_status"]?.objectValue?["provider_routing"], .string("unavailable"))
    XCTAssertEqual(object["host_provider_routing"]?.objectValue?["configured_providers"]?.arrayValue, [])
  }

  func testHostCapabilityManifestGatesBiometricsByPolicy() throws {
    let disabledManifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [],
      appleFoundationModelsStatus: .unsupportedPlatform,
      textProviderPreference: .random,
      cameraStatus: "available",
      orientationStatus: "available"
    )
    let disabledObject = try JSONValue.decodedObject(from: Data(disabledManifest.jsonString().utf8))
    let disabledCapabilities = Set(
      try XCTUnwrap(disabledObject["capabilities"]?.arrayValue).compactMap(\.stringValue))
    XCTAssertFalse(disabledCapabilities.contains("face_identification"))
    XCTAssertFalse(disabledCapabilities.contains("face_enrollment"))

    let enabledPolicy = BiometricDataPolicy(
      recognitionEnabled: true,
      policyAcknowledged: true,
      enrollmentAllowed: true,
      retentionPeriod: BiometricDataPolicy.defaultRetentionPeriod,
      exportIncluded: false,
      exportConfirmationRequired: true,
      autoDeleteUnconfirmed: true
    )
    let enabledManifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [],
      appleFoundationModelsStatus: .unsupportedPlatform,
      textProviderPreference: .random,
      cameraStatus: "available",
      orientationStatus: "available",
      biometricPolicy: enabledPolicy
    )
    let enabledObject = try JSONValue.decodedObject(from: Data(enabledManifest.jsonString().utf8))
    let enabledCapabilities = Set(
      try XCTUnwrap(enabledObject["capabilities"]?.arrayValue).compactMap(\.stringValue))
    XCTAssertTrue(enabledCapabilities.contains("face_identification"))
    XCTAssertTrue(enabledCapabilities.contains("face_enrollment"))
    XCTAssertEqual(enabledObject["capability_status"]?.objectValue?["face_identification"], .string("available"))
  }

  func testHostCapabilityManifestAdvertisesAppleFoundationModelsForTextOnly() throws {
    let manifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [],
      appleFoundationModelsStatus: .available,
      textProviderPreference: .random,
      cameraStatus: "available",
      orientationStatus: "denied"
    )
    let object = try JSONValue.decodedObject(from: Data(manifest.jsonString().utf8))
    let capabilities = Set(
      try XCTUnwrap(object["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("provider_vision_completion"))
    XCTAssertFalse(capabilities.contains("provider_vision_completion"))
    XCTAssertFalse(capabilities.contains("provider_image_generation"))
    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertEqual(object["capability_status"]?.objectValue?["provider_routing"], .string("available"))
    XCTAssertEqual(object["capability_status"]?.objectValue?["apple_foundation_models"], .string("available"))
    XCTAssertEqual(
      object["host_provider_routing"]?.objectValue?["configured_providers"]?.arrayValue,
      [.string("Apple Foundation Models")]
    )
  }

  func testHostCapabilityManifestReportsConfiguredTextProviderPreference() throws {
    let manifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [.openAI, .google],
      appleFoundationModelsStatus: .available,
      textProviderPreference: .openAI,
      cameraStatus: "available",
      orientationStatus: "denied"
    )
    let object = try JSONValue.decodedObject(from: Data(manifest.jsonString().utf8))
    let routing = try XCTUnwrap(object["host_provider_routing"]?.objectValue)

    XCTAssertEqual(routing["mode"], .string("openai"))
    XCTAssertEqual(
      routing["configured_providers"]?.arrayValue,
      [.string("Apple Foundation Models"), .string("OpenAI"), .string("Google")]
    )
    XCTAssertEqual(object["capability_status"]?.objectValue?["provider_routing"], .string("available"))
  }

  func testHostCapabilityManifestMarksUnavailableExplicitTextProviderPreference() throws {
    let manifest = EmbeddedHostCapabilityManifest(
      configuredProviders: [.google],
      appleFoundationModelsStatus: .available,
      textProviderPreference: .openAI,
      cameraStatus: "available",
      orientationStatus: "denied"
    )
    let object = try JSONValue.decodedObject(from: Data(manifest.jsonString().utf8))

    XCTAssertEqual(object["host_provider_routing"]?.objectValue?["mode"], .string("openai"))
    XCTAssertEqual(object["capability_status"]?.objectValue?["provider_routing"], .string("unavailable"))
  }

  func testCoreConfigUsesHostManifestInsteadOfProviderCredentialFields() throws {
    let storage = CoreConfigStorage(
      brain: try makeBrain(),
      providerCredentials: [
        .openAI: "openai-secret",
        .google: "google-secret",
      ],
      appleFoundationModelsStatus: .unsupportedPlatform,
      textProviderPreference: .random
    )

    storage.withConfig { config in
      let manifest = try? JSONValue.decodedObject(from: Data(embeddedString(config.host_manifest_json).utf8))
      XCTAssertEqual(manifest?["capability_status"]?.objectValue?["provider_routing"], .string("available"))
      XCTAssertEqual(
        manifest?["host_provider_routing"]?.objectValue?["configured_providers"]?.arrayValue,
        [.string("OpenAI"), .string("Google")]
      )
    }
  }

  func testHostProviderRouterFiltersConfiguredProvidersForRandomSelection() throws {
    var offeredProviders: [ProviderCredentialKey] = []
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: " openai-secret ",
          .anthropic: " ",
          .google: "google-secret",
        ]
      },
      providerPicker: { providers in
        offeredProviders = providers
        return .google
      }
    )

    let selection = try XCTUnwrap(router.selectedProviderCredential())

    XCTAssertEqual(offeredProviders, [.openAI, .google])
    XCTAssertEqual(selection.provider, .google)
    XCTAssertEqual(selection.credential, "google-secret")
  }

  func testHostLLMCompletionClientRunsSelectedProviderWithoutCore() async throws {
    var offeredRoutes: [HostLLMCompletionProvider] = []
    var requestedBody: [String: Any] = [:]
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: " openai-secret ",
          .anthropic: "",
          .google: "google-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .unsupportedPlatform },
        completionProvider: { _ in
          XCTFail("Local provider should not run when unavailable.")
          return ""
        }
      ),
      routePicker: { routes in
        offeredRoutes = routes
        return .credential(.openAI)
      },
      jsonLoader: { request in
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return ["output_text": "  A host-owned completion.  "]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Summarize this.",
      maxTokens: 42
    ))

    XCTAssertEqual(offeredRoutes, [.credential(.openAI), .credential(.google)])
    XCTAssertEqual(completion, HostLLMCompletionResponse(text: "A host-owned completion.", provider: .credential(.openAI)))
    XCTAssertEqual(requestedBody["input"] as? String, "Summarize this.")
    XCTAssertEqual(requestedBody["max_output_tokens"] as? Int, 42)
  }

  func testHostLLMCompletionClientPrimaryRouteReflectsRoutePickerOrder() throws {
    let router = HostProviderRouter(
      credentialProvider: {
        [.openAI: "openai-secret", .google: "google-secret"]
      }
    )
    let appleFirstClient = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .available },
        completionProvider: { _ in "local text" }
      ),
      routePicker: { routes in routes.first }
    )
    XCTAssertEqual(try appleFirstClient.primaryRoute(), .appleFoundationModels)

    let credentialFirstClient = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .available },
        completionProvider: { _ in "local text" }
      ),
      textProviderPreference: .openAI,
      routePicker: { routes in routes.first }
    )
    XCTAssertEqual(try credentialFirstClient.primaryRoute(), .credential(.openAI))
  }

  func testHostLLMCompletionClientRandomIncludesLocalAndCredentialRoutes() async throws {
    var offeredRoutes: [HostLLMCompletionProvider] = []
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: "openai-secret",
          .google: "google-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .available },
        completionProvider: { _ in "Local random completion." }
      ),
      routePicker: { routes in
        offeredRoutes = routes
        return .appleFoundationModels
      },
      jsonLoader: { _ in
        XCTFail("Network provider should not run when random selects local.")
        return [:]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Say hello.",
      maxTokens: 64
    ))

    XCTAssertEqual(offeredRoutes, [.appleFoundationModels, .credential(.openAI), .credential(.google)])
    XCTAssertEqual(completion, HostLLMCompletionResponse(
      text: "Local random completion.",
      provider: .appleFoundationModels
    ))
  }

  func testHostLLMCompletionClientRandomRetriesFailedRoute() async throws {
    var attemptedRoutes: [HostLLMCompletionProvider] = []
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: "openai-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .available },
        completionProvider: { _ in
          attemptedRoutes.append(.appleFoundationModels)
          throw HostLLMCompletionError.invalidProviderResponse
        }
      ),
      routePicker: { routes in
        routes.first { $0 == .appleFoundationModels } ?? routes.first
      },
      jsonLoader: { request in
        attemptedRoutes.append(.credential(.openAI))
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        return ["output_text": "Fallback completion."]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Say hello.",
      maxTokens: 64
    ))

    XCTAssertEqual(attemptedRoutes, [.appleFoundationModels, .credential(.openAI)])
    XCTAssertEqual(completion, HostLLMCompletionResponse(
      text: "Fallback completion.",
      provider: .credential(.openAI)
    ))
  }

  func testHostLLMCompletionClientLocalPreferenceUsesAppleFoundationModelsOnly() async throws {
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: "openai-secret",
        ]
      }
    )
    let appleClient = AppleFoundationModelsTextClient(
      availabilityProvider: { .available },
      completionProvider: { request in
        XCTAssertEqual(request.instructions, "You structure replies.")
        XCTAssertEqual(request.prompt, "Say hello.")
        XCTAssertEqual(request.maxTokens, 64)
        return "  Local host completion.  "
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: appleClient,
      textProviderPreference: .local,
      routePicker: { _ in
        XCTFail("Random route picker should not run for local preference.")
        return nil
      },
      jsonLoader: { _ in
        XCTFail("Network provider should not run when Apple local text is available.")
        return [:]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "System:\nYou structure replies.\n\nUser:\nSay hello.",
      maxTokens: 64
    ))

    XCTAssertEqual(completion, HostLLMCompletionResponse(
      text: "Local host completion.",
      provider: .appleFoundationModels
    ))
    XCTAssertEqual(completion.source, "apple_foundation_models")
  }

  func testHostLLMCompletionClientOpenAIPreferenceSkipsLocalWhenAvailable() async throws {
    var requestedBody: [String: Any] = [:]
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: "openai-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .available },
        completionProvider: { _ in
          XCTFail("Local provider should not run when OpenAI is explicitly selected.")
          return ""
        }
      ),
      textProviderPreference: .openAI,
      routePicker: { _ in
        XCTFail("Random route picker should not run for OpenAI preference.")
        return nil
      },
      jsonLoader: { request in
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return ["output_text": "  OpenAI explicit completion.  "]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Use network.",
      maxTokens: 42
    ))

    XCTAssertEqual(completion, HostLLMCompletionResponse(
      text: "OpenAI explicit completion.",
      provider: .credential(.openAI)
    ))
    XCTAssertEqual(requestedBody["input"] as? String, "Use network.")
  }

  func testHostLLMCompletionClientOpenAIJSONModeUsesProviderResponseFormat() async throws {
    var requestedBody: [String: Any] = [:]
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .openAI: "openai-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .unsupportedPlatform },
        completionProvider: { _ in "" }
      ),
      routePicker: { _ in .credential(.openAI) },
      jsonLoader: { request in
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return ["output_text": #"{"message":"line 1\nline 2"}"#]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Return JSON.",
      maxTokens: 64,
      responseFormat: .jsonObject,
      jsonSchema: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false}"#
    ))

    XCTAssertEqual(completion.text, #"{"message":"line 1\nline 2"}"#)
    let textConfig = try XCTUnwrap(requestedBody["text"] as? [String: Any])
    let responseFormat = try XCTUnwrap(textConfig["format"] as? [String: Any])
    XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
    XCTAssertEqual(responseFormat["name"] as? String, "text_completion")
    XCTAssertEqual(responseFormat["strict"] as? Bool, true)
    XCTAssertNotNil(responseFormat["schema"] as? [String: Any])
    XCTAssertNil(responseFormat["json_schema"])
  }

  func testHostLLMCompletionClientAnthropicJSONModeUsesToolResponse() async throws {
    var requestedBody: [String: Any] = [:]
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .anthropic: "anthropic-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .unsupportedPlatform },
        completionProvider: { _ in "" }
      ),
      routePicker: { _ in .credential(.anthropic) },
      jsonLoader: { request in
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "content": [
            [
              "type": "tool_use",
              "name": "json_response",
              "input": [
                "message": "structured",
              ],
            ],
          ],
        ]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Return JSON.",
      maxTokens: 64,
      responseFormat: .jsonObject,
      jsonSchema: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false}"#
    ))

    XCTAssertEqual(completion.text, #"{"message":"structured"}"#)
    XCTAssertNotNil(requestedBody["tools"] as? [[String: Any]])
    XCTAssertEqual(
      (requestedBody["tool_choice"] as? [String: Any])?["name"] as? String,
      "json_response"
    )
  }

  func testHostLLMCompletionClientGoogleJSONModeUsesResponseMimeType() async throws {
    var requestedBody: [String: Any] = [:]
    let router = HostProviderRouter(
      credentialProvider: {
        [
          .google: "google-secret",
        ]
      }
    )
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .unsupportedPlatform },
        completionProvider: { _ in "" }
      ),
      routePicker: { _ in .credential(.google) },
      jsonLoader: { request in
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "candidates": [
            [
              "content": [
                "parts": [
                  ["text": #"```json { "message": "from google" } ```"#]
                ]
              ]
            ]
          ]
        ]
      }
    )

    let completion = try await client.complete(HostLLMCompletionRequest(
      prompt: "Return JSON.",
      maxTokens: 64,
      responseFormat: .jsonObject,
      jsonSchema: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"],"additionalProperties":false}"#
    ))

    XCTAssertEqual(completion.text, #"{"message":"from google"}"#)
    let generationConfig = try XCTUnwrap(requestedBody["generationConfig"] as? [String: Any])
    XCTAssertEqual(generationConfig["responseMimeType"] as? String, "application/json")
    let responseSchema = try XCTUnwrap(generationConfig["responseSchema"] as? [String: Any])
    XCTAssertEqual(responseSchema["type"] as? String, "object")
    XCTAssertEqual(responseSchema["additionalProperties"] as? Bool, false)
  }

  func testHostLLMCompletionClientUnavailableExplicitPreferenceFailsClearly() async throws {
    let router = HostProviderRouter(credentialProvider: { [:] })
    let client = HostLLMCompletionClient(
      providerRouter: router,
      appleFoundationModelsClient: AppleFoundationModelsTextClient(
        availabilityProvider: { .unsupportedPlatform },
        completionProvider: { _ in "" }
      ),
      textProviderPreference: .local
    )

    do {
      _ = try await client.complete(HostLLMCompletionRequest(prompt: "Hello", maxTokens: 32))
      XCTFail("Local-only preference should fail when the local model is unavailable.")
    } catch HostLLMCompletionError.unavailableProvider(let provider) {
      XCTAssertEqual(provider, "local")
    }
  }

  func testEmbeddedHostServicesInjectsProviderCredentialsAtHTTPBoundary() throws {
    let services = EmbeddedHostServices(credentialProvider: {
      [
        .openAI: "openai-secret",
        .anthropic: "anthropic-secret",
        .google: "google-secret",
      ]
    })
    let openAIHeaders = #"[{"name":"Authorization","value":"Bearer host-managed:openai_api_key"}]"#
    let openAIRequest = try services.requestForPostJSON(
      url: "https://api.openai.com/v1/responses",
      headersJSON: openAIHeaders,
      body: Data("{}".utf8)
    )
    XCTAssertEqual(openAIRequest.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")

    let anthropicHeaders = #"[{"name":"x-api-key","value":"host-managed:anthropic_api_key"}]"#
    let anthropicRequest = try services.requestForPostJSON(
      url: "https://api.anthropic.com/v1/messages",
      headersJSON: anthropicHeaders,
      body: Data("{}".utf8)
    )
    XCTAssertEqual(anthropicRequest.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")

    let googleRequest = try services.requestForPostJSON(
      url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=host-managed:google_api_key",
      headersJSON: "[]",
      body: Data("{}".utf8)
    )
    let googleKey = URLComponents(url: try XCTUnwrap(googleRequest.url), resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "key" }?.value
    XCTAssertEqual(googleKey, "google-secret")
  }

  func testEmbeddedHostServicesHandlesSemanticLLMCompletionEndpoint() throws {
    var requestedBody: [String: Any] = [:]
    var offeredRoutes: [HostLLMCompletionProvider] = []
    let services = EmbeddedHostServices(
      credentialProvider: {
        [
          .openAI: "openai-secret",
          .google: "google-secret",
        ]
      },
      textRoutePicker: { routes in
        offeredRoutes = routes
        return .credential(.openAI)
      },
      jsonLoader: { request in
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return ["output_text": "  Semantic host completion.  "]
      }
    )
    let coreBody = try JSONSerialization.data(withJSONObject: [
      "subsystem": "conversation",
      "system_prompt": "You structure replies.",
      "user_prompt": "Say hello.",
      "response_format": "text",
      "response_size": "small",
      "temperature": 0.2,
      "max_tokens": 64,
      "json_schema": "{}",
    ])

    let response = try services.postJSON(
      url: "affective-host://llm/complete",
      headersJSON: "[]",
      body: coreBody
    )

    XCTAssertEqual(String(decoding: response, as: UTF8.self), "Semantic host completion.")
    XCTAssertEqual(offeredRoutes.filter { $0 != .appleFoundationModels }, [.credential(.openAI), .credential(.google)])
    XCTAssertEqual(requestedBody["max_output_tokens"] as? Int, 64)
    let prompt = try XCTUnwrap(requestedBody["input"] as? String)
    XCTAssertTrue(prompt.contains("System:\nYou structure replies."))
    XCTAssertTrue(prompt.contains("User:\nSay hello."))
    XCTAssertFalse(prompt.contains("openai-secret"))
  }

  func testEmbeddedHostServicesStripsMarkdownFenceFromJSONObjectCompletion() throws {
    var requestedBody: [String: Any] = [:]
    let services = EmbeddedHostServices(
      credentialProvider: {
        [
          .openAI: "openai-secret",
        ]
      },
      textRoutePicker: { _ in .credential(.openAI) },
      jsonLoader: { request in
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "output_text": #"```json { "action_pressures": [], "conversation_done": false } ```"#,
        ]
      }
    )
    let coreBody = try JSONSerialization.data(withJSONObject: [
      "subsystem": "conversation",
      "system_prompt": "You structure replies.",
      "user_prompt": "Say hello.",
      "response_format": "json_object",
      "response_size": "small",
      "temperature": 0.2,
      "max_tokens": 64,
      "json_schema": "{}",
    ])

    let response = try services.postJSON(
      url: "affective-host://llm/complete",
      headersJSON: "[]",
      body: coreBody
    )

    XCTAssertEqual(
      String(decoding: response, as: UTF8.self),
      #"{"action_pressures":[],"conversation_done":false}"#
    )
    let textConfig = try XCTUnwrap(requestedBody["text"] as? [String: Any])
    let responseFormat = try XCTUnwrap(textConfig["format"] as? [String: Any])
    XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
    XCTAssertEqual(responseFormat["name"] as? String, "text_completion")
    XCTAssertEqual(responseFormat["strict"] as? Bool, true)
    XCTAssertNotNil(responseFormat["schema"] as? [String: Any])
    XCTAssertNil(responseFormat["json_schema"])
  }

  func testEmbeddedHostServicesHandlesSemanticImageGenerationEndpoint() throws {
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("affective-host-image-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    var requestedBody: [String: Any] = [:]
    let services = EmbeddedHostServices(
      credentialProvider: {
        [
          .openAI: "openai-secret",
          .google: "google-secret",
        ]
      },
      jsonLoader: { request in
        XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        let googleKey = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
          .queryItems?.first { $0.name == "key" }?.value
        XCTAssertEqual(googleKey, "google-secret")
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "output_image": [
            "data": Data("image-bytes".utf8).base64EncodedString(),
            "mime_type": "image/png",
          ],
        ]
      }
    )
    let coreBody = try JSONSerialization.data(withJSONObject: [
      "prompt": "a watercolor lighthouse",
      "output_dir": outputDirectory.path,
    ])

    let response = try services.postJSON(
      url: "affective-host://image/generate",
      headersJSON: "[]",
      body: coreBody
    )
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    let path = try XCTUnwrap(object["path"] as? String)

    XCTAssertEqual(object["mime_type"] as? String, "image/png")
    XCTAssertTrue(path.hasPrefix(outputDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(String(decoding: fileData, as: UTF8.self), "image-bytes")
    let requestContents = try XCTUnwrap(requestedBody["contents"] as? [[String: Any]])
    let firstContent = try XCTUnwrap(requestContents.first)
    let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])
    XCTAssertEqual(parts.first?["text"] as? String, "a watercolor lighthouse")
  }

  func testEmbeddedHostServicesHandlesSemanticVisionCompletionEndpoint() throws {
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("affective-host-vision-\(UUID().uuidString).png")
    try Data("fake-png-bytes".utf8).write(to: imageURL)
    defer { try? FileManager.default.removeItem(at: imageURL) }
    var offeredProviders: [ProviderCredentialKey] = []
    var requestedBody: [String: Any] = [:]
    let services = EmbeddedHostServices(
      credentialProvider: {
        [
          .openAI: "openai-secret",
          .google: "google-secret",
        ]
      },
      providerPicker: { providers in
        offeredProviders = providers
        return .openAI
      },
      jsonLoader: { request in
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "choices": [
            [
              "message": [
                "content": "  A host-owned image description.  ",
              ],
            ],
          ],
        ]
      }
    )
    let coreBody = try JSONSerialization.data(withJSONObject: [
      "subsystem": "vision_description",
      "prompt": "Describe visible details.",
      "image_paths": [imageURL.path],
      "response_format": "text",
      "response_size": "medium",
      "temperature": 0.2,
      "max_tokens": 800,
      "json_schema": "{}",
    ])

    let response = try services.postJSON(
      url: "affective-host://vision/complete",
      headersJSON: "[]",
      body: coreBody
    )

    XCTAssertEqual(String(decoding: response, as: UTF8.self), "A host-owned image description.")
    XCTAssertEqual(offeredProviders, [.openAI, .google])
    let messages = try XCTUnwrap(requestedBody["messages"] as? [[String: Any]])
    let firstMessage = try XCTUnwrap(messages.first)
    let content = try XCTUnwrap(firstMessage["content"] as? [[String: Any]])
    XCTAssertEqual(content.first?["text"] as? String, "Describe visible details.")
    let imagePart = try XCTUnwrap(content.last)
    let imageURLObject = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
    let dataURL = try XCTUnwrap(imageURLObject["url"] as? String)
    XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))
    XCTAssertTrue(dataURL.hasSuffix(Data("fake-png-bytes".utf8).base64EncodedString()))
    XCTAssertFalse(dataURL.contains("openai-secret"))
  }

  func testAdvertisedHostCapabilitiesHaveEndToEndCoverage() async throws {
    let advertised = try Self.allAdvertisedHostCapabilities()
    let coverage = Self.hostCapabilityE2ECoverage

    XCTAssertEqual(
      advertised,
      Set(coverage.keys),
      "Every advertised host capability needs explicit e2e coverage or an intentional manifest-only classification."
    )

    XCTAssertTrue(
      EmbeddedProtocolContract.eventTypesRequiringHostCapability.isEmpty,
      "BrainEvent payload types should not be modeled as host capabilities."
    )

    let brain = try makeBrain()
    let core = BrainCore(brain: brain)

    func isExpectedCoverageProbeBoundary(_ error: Error) -> Bool {
      let description = String(describing: error)
      return description.contains("FrontendCaptureRequested")
        || description.contains("HostHttpPostJsonFailed")
    }

    func assertCoverageProbeResponse(
      _ label: String,
      _ body: () async throws -> BrainToolResponse
    ) async throws {
      do {
        let response = try await body()
        XCTAssertNotNil(response.metadata["request_id"], label)
      } catch {
        guard isExpectedCoverageProbeBoundary(error) else {
          throw NSError(
            domain: "AffectiveTests.CoverageProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(label): \(String(describing: error))"]
          )
        }
      }
    }

    try await withConnectedCore(core) {
      try await assertCoverageProbeResponse("short_touch") {
        try await core.shortTouch()
      }

      try await assertCoverageProbeResponse("long_touch") {
        try await core.longTouch()
      }

      try await assertCoverageProbeResponse("poke_sequence") {
        try await core.pokeSequence([
          PokePulse(pressMilliseconds: 25, pauseBeforeMilliseconds: 0)
        ])
      }

      do {
        let response = try await core.mailboxList()
        XCTAssertNotNil(response.metadata["request_id"], "mailbox_list typed operation")
      } catch {
        guard isExpectedCoverageProbeBoundary(error) else { throw error }
      }

      try await assertCoverageProbeResponse("send_experience_event") {
        try await core.sendExperienceEvent(
          hostID: "swift-test-host",
          source: "host",
          kind: "Host.TestEvent",
          payload: "{\"ok\":true}",
          salience: 0.42,
          confidence: 0.91,
          valence: 0.1,
          arousal: 0.2,
          uncertainty: 0.05,
          causalParentIDs: ["parent-test-event"],
          retention: "episode",
          visibility: "internal"
        )
      }

      try await assertCoverageProbeResponse("capability_status") {
        try await core.capabilityStatus(
          capability: "camera",
          status: "denied",
          requestID: "capability-e2e-status",
          pendingSince: nil,
          pendingElapsedMS: 12,
          reason: "coverage probe"
        )
      }

      do {
        let typedText = try await core.sendText("capability e2e typed text")
        XCTAssertNotNil(typedText.metadata["request_id"])
      } catch {
        guard isExpectedCoverageProbeBoundary(error) else { throw error }
      }
      // The coverage probe only verifies dispatch routes. If the brain elects
      // to pull an awaited sense or probe a provider host callback, the host
      // should not synthesize a chat stand-in for this test.

      try await assertCoverageProbeResponse("orientation_observation") {
        try await core.orientationObservation(
          OrientationQueryProvider.classify(x: 0.02, y: 0.01, z: -0.99)
        )
      }

      let imageURL = await brain.rootURL.appendingPathComponent("capability-e2e.png")
      try Self.tinyPNGData.write(to: imageURL, options: .atomic)
      try await assertCoverageProbeResponse("camera_observation") {
        try await core.cameraObservation(
          path: imageURL.path,
          mimeType: "image/png",
          source: "capability_e2e",
          requestID: "capability-e2e-camera"
        )
      }

      do {
        let state = try await core.readModelsSnapshot()
        XCTAssertNotNil(state.metadata["request_id"])
        XCTAssertNotNil(state.readModels.objectValue)
      } catch {
        guard isExpectedCoverageProbeBoundary(error) else { throw error }
      }
    }
  }

  func testCameraPromptRequiredAdvertisesFrontendCameraSense() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true, cameraStatus: "prompt_required").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertTrue(capabilities.contains("provider_vision_completion"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["camera"], .string("prompt_required"))
  }

  func testCameraAvailableAdvertisesFrontendCameraSense() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true, cameraStatus: "available").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertTrue(capabilities.contains("provider_vision_completion"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["camera"], .string("available"))
  }

  func testCameraDeniedRemovesFrontendCameraSenseFromHostManifest() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(
        hasProvider: true,
        cameraStatus: "denied",
        orientationStatus: "denied"
      ).utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertTrue(capabilities.contains("provider_vision_completion"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["camera"], .string("denied"))
  }

  @MainActor
  func testCameraCaptureLifecycleReturnsCapturedData() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let expected = Self.tinyPNGData
    var attemptCount = 0
    model.cameraPhotoCaptureOverride = {
      attemptCount += 1
      return expected
    }

    let data = try await model.captureWebcamPhotoData()

    XCTAssertEqual(data, expected)
    XCTAssertEqual(try model.validateCapturedImageData(data), CapturedImageInfo(width: 1, height: 1))
    XCTAssertEqual(attemptCount, 1)
  }

  @MainActor
  func testCameraCaptureLifecycleRetriesTransientAuthorizationFailure() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let expected = Self.tinyPNGData
    var attemptCount = 0
    model.cameraPhotoCaptureOverride = {
      attemptCount += 1
      if attemptCount == 1 {
        throw CameraCaptureError.notAuthorized
      }
      return expected
    }

    let data = try await model.captureWebcamPhotoData()

    XCTAssertEqual(data, expected)
    XCTAssertEqual(try model.validateCapturedImageData(data), CapturedImageInfo(width: 1, height: 1))
    XCTAssertEqual(attemptCount, 2)
  }

  @MainActor
  func testCameraCaptureLifecycleDoesNotRetryTerminalFailure() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    var attemptCount = 0
    model.cameraPhotoCaptureOverride = {
      attemptCount += 1
      throw CameraCaptureError.timedOut
    }

    do {
      _ = try await model.captureWebcamPhotoData()
      XCTFail("Expected camera capture timeout to be thrown.")
    } catch {
      XCTAssertEqual(error as? CameraCaptureError, .timedOut)
      XCTAssertEqual(attemptCount, 1)
    }
  }

  @MainActor
  func testCameraCaptureLifecycleRejectsUndecodableImageData() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    XCTAssertThrowsError(try model.validateCapturedImageData(Data([0xFF, 0xD8, 0xFF, 0xD9]))) { error in
      XCTAssertEqual(error as? CameraCaptureError, .invalidImageData)
    }
  }

  @MainActor
  func testCameraCaptureLifecycleRejectsBlackImageData() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let blackPNG = try Self.pngFixture(width: 32, height: 32) { _, _ in
      (red: 0, green: 0, blue: 0, alpha: 255)
    }

    XCTAssertThrowsError(try model.validateCapturedImageData(blackPNG)) { error in
      XCTAssertEqual(error as? CameraCaptureError, .blackImageData)
    }
  }

  @MainActor
  func testCameraCaptureLifecycleAcceptsNonBlackImageData() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let visiblePNG = try Self.pngFixture(width: 32, height: 32) { x, y in
      let isBright = (x + y).isMultiple(of: 2)
      return isBright
        ? (red: 255, green: 255, blue: 255, alpha: 255)
        : (red: 32, green: 96, blue: 180, alpha: 255)
    }

    XCTAssertEqual(try model.validateCapturedImageData(visiblePNG), CapturedImageInfo(width: 32, height: 32))
  }

  @MainActor
  func testLiveCameraHardwareCaptureReturnsVisibleImage() async throws {
    guard ProcessInfo.processInfo.environment["AFFECTIVE_RUN_CAMERA_HARDWARE_E2E"] == "1" else {
      throw XCTSkip("Set AFFECTIVE_RUN_CAMERA_HARDWARE_E2E=1 to run the live camera hardware capture check.")
    }

    let model = AffectiveViewModel(brain: try makeBrain())
    let status = await model.requestCameraPermissionIfNeeded(requestID: "camera-hardware-e2e")
    guard status == .available else {
      XCTFail("Live camera hardware test requested, but camera permission/status is \(status.rawValue).")
      return
    }

    let data = try await model.captureWebcamPhotoData()
    let imageInfo = try model.validateCapturedImageData(data)

    XCTAssertGreaterThan(imageInfo.width, 1)
    XCTAssertGreaterThan(imageInfo.height, 1)
  }

  @MainActor
  func testLiveCameraCaptureProducesDetectableFace() async throws {
    guard ProcessInfo.processInfo.environment["AFFECTIVE_RUN_CAMERA_HARDWARE_E2E"] == "1" else {
      throw XCTSkip("Set AFFECTIVE_RUN_CAMERA_HARDWARE_E2E=1 to run the live camera face-detection check.")
    }
    guard FaceRecognitionService.bundledModelsAvailable else {
      throw XCTSkip("Bundled ONNX recognition models are not available in this test bundle.")
    }

    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
      {
        "schema_version": 1,
        "traces": [],
        "beliefs": [],
        "subjects": [],
        "artifacts": [],
        "dreams": []
      }
    """)

    let model = AffectiveViewModel(brain: brain)
    let status = await model.requestCameraPermissionIfNeeded(requestID: "camera-hardware-identify-e2e")
    guard status == .available else {
      XCTFail("Live camera identify test requested, but camera permission/status is \(status.rawValue).")
      return
    }

    let data = try await model.captureWebcamPhotoData()
    let imageInfo = try model.validateCapturedImageData(data)
    let storedImage = try model.storeChatImage(data: data, suggestedName: "hardware-identify-e2e-\(UUID().uuidString)")
    let service = FaceRecognitionService()
    let result = try service.identify(.init(
      imagePath: storedImage.url.path,
      memoryPath: brain.memoryDatabaseURL.path,
      embeddingsDir: brain.faceEmbeddingsURL.path,
      detectorModel: nil,
      recognizerModel: nil,
      knownThreshold: 0.85,
      uncertainThreshold: 0.60
    ))

    if result.peopleCount == 0 {
      XCTFail(
        """
        Live camera identify returned people_count=0 (match_status=\(result.matchStatus)).
        image_path=\(storedImage.url.path)
        byte_count=\(data.count)
        pixel_width=\(imageInfo.width)
        pixel_height=\(imageInfo.height)
        Reproduce with:
        tools/affective-face-recognizer identify \\
          --image "\(storedImage.url.path)" \\
          --memory "\(brain.memoryDatabaseURL.path)" \\
          --embeddings-dir "\(brain.faceEmbeddingsURL.path)" \\
          --known-threshold 0.85 \\
          --uncertain-threshold 0.60
        """
      )
    }
    XCTAssertGreaterThanOrEqual(result.peopleCount, 1)
  }

  @MainActor
  func testSenseRequestsStayOutOfChatTranscript() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      senseRequestEvent(
        requestID: "sense-fixture",
        sense: "camera",
        title: "camera sense",
        summary: "Affective wants a fresh webcam image."
      )
    ], mirrorChatMessages: true, speak: false, handleHostRequests: false)

    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertEqual(model.eventEntries.last?.title, "camera sense")
    XCTAssertEqual(model.eventEntries.last?.body, "")
    XCTAssertEqual(model.eventEntries.last?.metadata["sense"], "camera")
  }

  @MainActor
  func testSenseCatalogRequestReturnsHostCatalog() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_catalog"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)

    await model.applyCoreEvents([
      actionRequestEvent(
        actionID: "catalog-request",
        action: "sense_catalog",
        arguments: ["summary": .string("list senses")]
      )
    ], mirrorChatMessages: true, speak: false)

    let requests = await core.senseCatalogRequests
    XCTAssertEqual(requests, ["catalog-request"])
  }

  @MainActor
  func testSpecificSenseStatusRequestReturnsStructuredStatus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)

    await model.applyCoreEvents([
      actionRequestEvent(
        actionID: "camera-status",
        action: "sense_status",
        arguments: ["sense": .string("camera"), "summary": .string("camera?")]
      )
    ], mirrorChatMessages: true, speak: false)

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last)
    XCTAssertEqual(status.sense, "camera")
    XCTAssertEqual(status.requestID, "camera-status")
    XCTAssertFalse(status.terminal)
  }

  @MainActor
  func testUnsupportedPullSenseReturnsStructuredStatus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "unsupported-sense",
        sense: "location",
        title: "location sense",
        summary: "where am I?",
        timeoutMS: 100
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last)
    XCTAssertEqual(status.sense, "location")
    XCTAssertEqual(status.status, .unsupported)
    XCTAssertEqual(status.requestID, "unsupported-sense")
    XCTAssertTrue(status.terminal)
  }

  @MainActor
  func testAwaitedCameraSenseTimesOutWaitingForObservationResponse() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
          continuation.resume()
        }
      }
      return Self.tinyPNGData
    }

    await model.applyCoreEvents([
      senseRequestEvent(
        requestID: "capture-timeout",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        responsePresentation: .chat,
        timeoutMS: 1
      )
    ], mirrorChatMessages: true, speak: false)

    let observations = await core.cameraObservations
    XCTAssertFalse(observations.contains { $0.requestID == "capture-timeout" })
    let failure = try XCTUnwrap(model.eventEntries.last { $0.title == "camera sense timed out" })
    XCTAssertTrue(failure.body.contains("timed out"))
    XCTAssertEqual(failure.metadata["status"], PullSenseTerminalStatus.timedOut.rawValue)
    XCTAssertNil(model.chatEntries.last { $0.title == "Camera" && $0.body.contains("couldn't get a usable image") })
    XCTAssertNil(model.chatEntries.last { $0.body == "I got the new picture." })
  }

  @MainActor
  func testAwaitedCameraSenseAcknowledgesBlackFrameInChat() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = {
      try Self.pngFixture(width: 32, height: 32) { _, _ in
        (red: 0, green: 0, blue: 0, alpha: 255)
      }
    }

    await model.applyCoreEvents([
      senseRequestEvent(
        requestID: "black-frame",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        responsePresentation: .chat,
        timeoutMS: 10_000
      )
    ], mirrorChatMessages: true, speak: false)

    let observations = await core.cameraObservations
    XCTAssertTrue(observations.isEmpty)
    let failure = try XCTUnwrap(model.eventEntries.last { $0.title == "camera sense failed" })
    XCTAssertEqual(failure.metadata["camera_error"], "blackImageData")
    XCTAssertNil(model.chatEntries.last { $0.title == "Camera" })
  }

  @MainActor
  func testCameraPermissionDeniedReturnsPullSenseStatus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .denied }

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "camera-denied",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        timeoutMS: 10_000
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last)
    XCTAssertEqual(status.sense, "camera")
    XCTAssertEqual(status.status, .permissionDenied)
    XCTAssertEqual(status.requestID, "camera-denied")
    XCTAssertTrue(status.terminal)
  }

  @MainActor
  func testOrientationPermissionDeniedReturnsPullSenseStatus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.orientationPermissionStatusOverride = .denied

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "orientation-denied",
        sense: "orientation",
        title: "orientation sense",
        summary: "Affective wants orientation.",
        timeoutMS: 10_000
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last)
    XCTAssertEqual(status.sense, "orientation")
    XCTAssertEqual(status.status, .permissionDenied)
    XCTAssertEqual(status.requestID, "orientation-denied")
    XCTAssertTrue(status.terminal)
  }

  @MainActor
  func testPullSenseTimeoutCoversPendingOrientationPermission() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    UserDefaults.standard.removeObject(forKey: AffectiveViewModel.orientationPermissionStatusKey)
    model.orientationCapabilityStatusOverride = .promptRequired

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "orientation-timeout",
        sense: "orientation",
        title: "orientation sense",
        summary: "Affective wants orientation.",
        timeoutMS: 1
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    XCTAssertEqual(statuses.filter { $0.requestID == "orientation-timeout" && $0.terminal }.count, 1)
    let status = try XCTUnwrap(statuses.last { $0.requestID == "orientation-timeout" })
    XCTAssertEqual(status.status, .timedOut)
    XCTAssertNil(model.orientationPermissionPrompt)
  }

  @MainActor
  func testDuplicateOrientationPullReturnsBusyStatus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.pendingOrientationRequestID = "orientation-first"

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "orientation-second",
        sense: "orientation",
        title: "orientation sense",
        summary: "Affective wants orientation.",
        timeoutMS: 10_000
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last { $0.requestID == "orientation-second" })
    XCTAssertEqual(status.sense, "orientation")
    XCTAssertEqual(status.status, .busy)
    XCTAssertTrue(status.terminal)
  }

  @MainActor
  func testPullSenseTimeoutReturnsBeforeSlowHostOperationFinishes() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
          continuation.resume()
        }
      }
      return Self.tinyPNGData
    }

    let start = Date()
    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "slow-camera-timeout",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        timeoutMS: 1
      ),
      observationResponsePresentation: .internalOnly
    )

    XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    XCTAssertNil(model.pendingCameraRequestID)
    XCTAssertEqual(model.hostPipelineHold, .none)
    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last { $0.requestID == "slow-camera-timeout" })
    XCTAssertEqual(status.status, .timedOut)
  }

  @MainActor
  func testFailedPullSenseStatusDeliveryDoesNotConsumeTerminalRequestID() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      pullSenseStatusError: NSError(domain: "PullSenseStatus", code: 1)
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)

    let delivered = await model.sendPullSenseStatus(
      sense: "camera",
      status: .unavailable,
      requestID: "status-fails",
      timeoutMS: nil,
      reason: "test failure",
      availability: "unavailable",
      permissionState: "unavailable",
      terminal: true
    )

    XCTAssertFalse(delivered)
    XCTAssertFalse(model.terminalPullSenseRequestIDs.contains("status-fails"))
    XCTAssertFalse(model.closedPullSenseRequestIDs.contains("status-fails"))
  }

  @MainActor
  func testTimedOutCameraPullDoesNotEmitLateObservation() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "sense_status"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
          continuation.resume()
        }
      }
      return Self.tinyPNGData
    }

    await model.fulfillSenseRequest(
      senseRequestEvent(
        requestID: "late-camera-timeout",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        timeoutMS: 1
      ),
      observationResponsePresentation: .internalOnly
    )

    let statuses = await core.pullSenseStatuses
    let status = try XCTUnwrap(statuses.last { $0.requestID == "late-camera-timeout" })
    XCTAssertEqual(status.status, .timedOut)
    let observations = await core.cameraObservations
    XCTAssertFalse(observations.contains { $0.requestID == "late-camera-timeout" })
  }

  @MainActor
  func testInternalCameraSenseFailureStaysOutOfChat() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = {
      try Self.pngFixture(width: 32, height: 32) { _, _ in
        (red: 0, green: 0, blue: 0, alpha: 255)
      }
    }
    let initialChatCount = model.chatEntries.count

    await model.fulfillCameraSenseRequest(
      senseRequestEvent(
        requestID: "internal-black-frame",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested",
        timeoutMS: 10_000
      ),
      observationResponsePresentation: .internalOnly
    )

    let observations = await core.cameraObservations
    XCTAssertTrue(observations.isEmpty)
    XCTAssertNotNil(model.eventEntries.last { $0.title == "camera sense failed" })
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
  }

  @MainActor
  func testShortTouchCaptureMirrorsCameraObservationResponse() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      shortTouchResponse: Self.toolResponse(
        toolName: "short_touch",
        events: [
          senseRequestEvent(
            requestID: "short-touch-capture",
            sense: "camera",
            title: "camera sense",
            summary: "frontend camera sense requested",
            responsePresentation: .chat
          )
        ]
      ),
      cameraObservationResponse: Self.toolResponse(
        toolName: "sense_observation",
        events: [
          brainChatEvent(title: "Brain", text: "I can see the captured frame now.")
        ]
      )
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }

    await model.callCoreTouch(name: "short_touch", title: "short_touch")

    let observations = await core.cameraObservations
    let observation = try XCTUnwrap(observations.last)
    XCTAssertEqual(observation.requestID, "short-touch-capture")
    XCTAssertEqual(observation.mimeType, "image/png")
    XCTAssertEqual(observation.source, "affective_requested_capture")
    XCTAssertEqual(observation.presentation, .chat)

    XCTAssertEqual(model.chatEntries.last?.body, "I can see the captured frame now.")
    XCTAssertNotNil(model.eventEntries.last { $0.title == "camera sense" })
    XCTAssertNotNil(model.eventEntries.last { $0.title == "sense_observation" })
  }

  @MainActor
  func testTypedTextCameraResumeMirrorsChatEvenWhenSenseRequestUsesStatusPresentation() async throws {
    let pausedResponse = Self.toolResponse(
      toolName: "user_text",
      events: [
        senseRequestEvent(
          requestID: "recognize-camera",
          sense: "camera",
          title: "camera sense",
          summary: "frontend camera sense requested",
          responsePresentation: .status
        )
      ],
      result: .object([
        "event_type": .string("user_text"),
        "value": .object([
          "kind": .string("user_text"),
          "outcome": .object([
            "text": .string("do you recognize me?"),
            "spoken_text": .string(""),
            "user_summary": .string("Asked about recognition."),
            "brain_summary": .string("Requested camera capture."),
            "interrupted_by": .null,
            "awaiting_host_sense": .bool(true),
            "awaited_host_sense": .string("camera"),
            "awaited_host_purpose": .string("recognize"),
            "awaited_host_timeout_ms": .number(8_000),
          ]),
        ]),
      ])
    )
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(
        toolName: "user_text",
        text: pausedResponse.text,
        metadata: pausedResponse.metadata.merging(["state": "awaiting host sense"]) { current, _ in current },
        events: pausedResponse.events
      ),
      cameraObservationResponse: Self.toolResponse(
        toolName: "sense_observation",
        events: [
          brainChatEvent(title: "Brain", text: "I can see someone is here, but I don't recognize you yet.")
        ]
      )
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }

    await model.sendTextToBrain("do you recognize me?")
    await model.waitForHostPipelineIdle()

    XCTAssertEqual(model.chatEntries.last?.body, "I can see someone is here, but I don't recognize you yet.")
    XCTAssertNil(model.eventEntries.last { $0.title == "chat display" && $0.body.contains("display_text_empty=true") })
    XCTAssertNil(model.eventEntries.first {
      $0.kind == .result
        && $0.title == "user_text"
        && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
  }

  @MainActor
  func testIgnoredStimulusResultIncludesKnownReason() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      shortTouchResponse: Self.toolResponse(
        toolName: "short_touch",
        result: .object([
          "event_type": .string("short_touch"),
          "summary": .string("touch stimulus ignored"),
          "raw_result": .bool(false),
          "ignored_because": .string("low_salience"),
        ])
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.callCoreTouch(name: "short_touch", title: "short_touch")

    let entry = try XCTUnwrap(model.eventEntries.last { $0.title == "short_touch" })
    XCTAssertEqual(entry.metadata["ignored_because"], "low_salience")
  }

  @MainActor
  func testIgnoredStimulusResultRequiresStructuredReason() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      shortTouchResponse: Self.toolResponse(
        toolName: "short_touch",
        result: .object([
          "event_type": .string("short_touch"),
          "summary": .string("touch_stimulus kind=short_touch reason=recent visual evidence is fresh enough to avoid an immediate repeat lookup attention_hint=defer_visual_lookup chosen_look=false"),
          "raw_result": .bool(false),
        ])
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.callCoreTouch(name: "short_touch", title: "short_touch")

    let entry = try XCTUnwrap(model.eventEntries.last { $0.title == "short_touch" })
    XCTAssertNil(entry.metadata["ignored_because"])
  }

  @MainActor
  func testIgnoredStimulusResultDoesNotInventUnknownReason() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      shortTouchResponse: Self.toolResponse(
        toolName: "short_touch",
        result: .object([
          "event_type": .string("short_touch"),
          "summary": .string("touch stimulus ignored"),
          "raw_result": .bool(false),
        ])
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.callCoreTouch(name: "short_touch", title: "short_touch")

    let entry = try XCTUnwrap(model.eventEntries.last { $0.title == "short_touch" })
    XCTAssertNil(entry.metadata["ignored_because"])
  }

  @MainActor
  func testCameraSenseRecordsRecentStimulus() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }
    model.recordRecentStimulus(
      kind: "short_touch",
      summary: "User sent short_touch.",
      metadata: [:]
    )

    await model.fulfillCameraSenseRequest(
      senseRequestEvent(
        requestID: "recent-camera",
        sense: "camera",
        title: "camera sense",
        summary: "frontend camera sense requested"
      ),
      observationResponsePresentation: .internalOnly
    )

    let context = model.currentStimulusContext(kind: "user_message")
    let cameraStimulus = try XCTUnwrap(context.recentStimuli.first)

    XCTAssertEqual(cameraStimulus.kind, "camera_observation")
    XCTAssertEqual(cameraStimulus.metadata["request_id"], nil)
    XCTAssertEqual(cameraStimulus.metadata["source"], "affective_requested_capture")
    XCTAssertEqual(context.recentStimuli.map(\.kind), ["camera_observation", "short_touch"])
    XCTAssertEqual(cameraStimulus.salience, 0.5)
  }

  @MainActor
  func testTypedTextCameraSenseDoesNotMirrorObservationAsExtraChat() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(
        toolName: "experience",
        text: "Hello from the first turn.",
        metadata: [:],
        events: [
          brainChatEvent(title: "Brain", text: "Hello from the first turn."),
          senseRequestEvent(
            requestID: "typed-text-capture",
            sense: "camera",
            title: "camera sense",
            summary: "frontend camera sense requested"
          )
        ]
      ),
      cameraObservationResponse: Self.toolResponse(
        toolName: "sense_observation",
        events: [
          brainChatEvent(title: "Brain", text: "I can see the captured frame now.")
        ]
      )
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.currentHostPipelineAction = .typedText(
      text: "Hello?",
      stimulusContext: model.currentStimulusContext(kind: "user_message")
    )
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }

    await model.sendTextToBrain("Hello?", speakResponse: false)
    await model.waitForHostPipelineIdle()

    let observations = await core.cameraObservations
    XCTAssertEqual(observations.last?.requestID, "typed-text-capture")
    XCTAssertEqual(observations.last?.presentation, .internalOnly)
    XCTAssertEqual(model.chatEntries.filter { $0.body == "Hello from the first turn." }.count, 1)
    XCTAssertNil(model.chatEntries.last { $0.body == "I can see the captured frame now." })
    XCTAssertNotNil(model.eventEntries.last { $0.title == "sense_observation" })
  }

  @MainActor
  func testOrientationSenseMirrorsObservationResponse() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      shortTouchResponse: Self.toolResponse(
        toolName: "short_touch",
        events: [
          senseRequestEvent(
            requestID: "orientation-capture",
            sense: "orientation",
            title: "orientation sense",
            summary: "Affective wants orientation.",
            responsePresentation: .chat
          )
        ]
      ),
      orientationObservationResponse: Self.toolResponse(
        toolName: "sense_observation",
        events: [
          brainChatEvent(title: "Brain", text: "The device is face up.")
        ]
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.orientationPermissionStatusOverride = .available
    model.orientationObservationOverride = {
      OrientationObservation(
        posture: "face_up",
        confidence: 0.99,
        gravityX: 0.02,
        gravityY: 0.01,
        gravityZ: -0.99,
        summary: "The device is lying face up."
      )
    }

    await model.callCoreTouch(name: "short_touch", title: "short_touch")

    let observations = await core.orientationObservations
    let observation = try XCTUnwrap(observations.last)
    XCTAssertEqual(observation.requestID, "orientation-capture")
    XCTAssertEqual(observation.observation.posture, "face_up")
    XCTAssertEqual(observation.presentation, .chat)

    XCTAssertEqual(model.chatEntries.last?.body, "The device is face up.")
    XCTAssertNotNil(model.eventEntries.last { $0.title == "orientation sense" })
    XCTAssertNotNil(model.eventEntries.last { $0.title == "sense_observation" })
  }

  @MainActor
  func testTapWakeQueuesTouchStimulusWithoutRequiringChatResponse() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isHostPipelineRunning = true

    model.shortTapWake()

    guard case .coreTouch(let name, _) = model.hostPipelineQueue.last else {
      return XCTFail("Expected short tap wake to queue a touch action.")
    }
    XCTAssertEqual(name, "short_touch")
    XCTAssertEqual(model.pendingChatResponseCount, 0)
  }

  @MainActor
  func testPokeFlushQueuesPokeStimulusWithoutRequiringChatResponse() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isHostPipelineRunning = true
    model.pendingPokePulses = [
      PokePulse(pressMilliseconds: 120, pauseBeforeMilliseconds: 0),
    ]

    await model.flushPokeSequence()

    guard case .pokeSequence(let pulses) = model.hostPipelineQueue.last else {
      return XCTFail("Expected poke flush to queue a poke sequence action.")
    }
    XCTAssertEqual(pulses.count, 1)
    XCTAssertEqual(model.pendingChatResponseCount, 0)
    XCTAssertEqual(model.eventEntries.last?.metadata["mirror_to_chat"], "false")
  }

  @MainActor
  func testPokeFlushRecordsRecentStimulusForFollowUpContext() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.pendingPokePulses = [
      PokePulse(pressMilliseconds: 120, pauseBeforeMilliseconds: 0),
      PokePulse(pressMilliseconds: 80, pauseBeforeMilliseconds: 300),
    ]

    await model.flushPokeSequence()

    let context = model.currentStimulusContext(kind: "user_message")
    XCTAssertEqual(context.recentStimuli.count, 1)
    XCTAssertEqual(context.recentStimuli.first?.kind, "poke_sequence")
    XCTAssertEqual(context.recentStimuli.first?.metadata["pulse_count"], "2")
    XCTAssertEqual(context.recentStimuli.first?.summary, "User poked 2 times: 120ms / 80ms.")
  }

  @MainActor
  func testMotionGestureObservationQueuesAndRecordsStimulus() async throws {
    let observation = try XCTUnwrap(MotionGestureMonitor.classify(x: 2.9, y: 0.2, z: 0.1))
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isHostPipelineRunning = true

    model.handleMotionGestureObservation(observation)

    guard case .pushedMotionGesture(let queuedObservation) = model.hostPipelineQueue.last else {
      return XCTFail("Expected motion gesture to queue a pushed motion gesture action.")
    }
    XCTAssertEqual(queuedObservation.gesture, "shake")
    XCTAssertEqual(model.pendingChatResponseCount, 0)
    XCTAssertEqual(model.eventEntries.last?.title, "motion gesture")

    let context = model.currentStimulusContext(kind: "user_message")
    XCTAssertEqual(context.recentStimuli.first?.kind, "motion_gesture")
    XCTAssertEqual(context.recentStimuli.first?.metadata["gesture"], "shake")
    XCTAssertEqual(context.recentStimuli.first?.metadata["sense_direction"], "push")
  }

  @MainActor
  func testMotionGestureObservationDispatchesToCore() async throws {
    let observation = try XCTUnwrap(MotionGestureMonitor.classify(x: -1.5, y: 0.1, z: 0.1))
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      motionGestureObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.sendPushedMotionGestureObservation(observation)

    let observations = await core.motionGestureObservations
    XCTAssertEqual(observations.last?.observation.gesture, "tilt_left")
    XCTAssertEqual(observations.last?.presentation, .internalOnly)
    XCTAssertNotNil(model.eventEntries.last { $0.title == "pushed_motion_gesture" })
  }

  @MainActor
  func testRecentStimuliExpireFromStimulusContext() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let now = Date()
    model.recordRecentStimulus(
      kind: "poke_sequence",
      summary: "User poked once: 120ms.",
      metadata: ["pulse_count": "1"],
      now: now.addingTimeInterval(-91)
    )
    model.recordRecentStimulus(
      kind: "short_touch",
      summary: "User sent short_touch.",
      metadata: ["event_type": "short_touch"],
      now: now.addingTimeInterval(-10)
    )

    let context = model.currentStimulusContext(kind: "user_message", now: now)

    XCTAssertEqual(context.recentStimuli.map(\.kind), ["short_touch"])
    XCTAssertEqual(context.senseInventory.map(\.kind), ["short_touch", "poke_sequence"])
    XCTAssertEqual(context.senseInventory.first { $0.kind == "poke_sequence" }?.totalCount, 1)
    XCTAssertEqual(context.senseInventory.first { $0.kind == "poke_sequence" }?.recentCount, 0)
    XCTAssertEqual(context.senseInventory.first { $0.kind == "short_touch" }?.recentCount, 1)
  }

  @MainActor
  func testRecentStimuliHonorProvidedSalienceThenRecency() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let now = Date()
    model.recordRecentStimulus(
      kind: "short_touch",
      summary: "User sent short_touch.",
      metadata: ["salience": "0.55"],
      now: now.addingTimeInterval(-1)
    )
    model.recordRecentStimulus(
      kind: "camera_observation",
      summary: "Camera captured an image: 64x64.",
      metadata: ["salience": "0.9"],
      now: now.addingTimeInterval(-20)
    )
    model.recordRecentStimulus(
      kind: "poke_sequence",
      summary: "User poked once: 120ms.",
      metadata: ["salience": "0.8"],
      now: now.addingTimeInterval(-5)
    )

    let context = model.currentStimulusContext(kind: "user_message", now: now)

    XCTAssertEqual(context.recentStimuli.map(\.kind), [
      "camera_observation",
      "poke_sequence",
      "short_touch",
    ])
  }

  @MainActor
  func testSendTextPassesRecentStimuliToBrainCore() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.recordRecentStimulus(
      kind: "poke_sequence",
      summary: "User poked once: 120ms.",
      metadata: ["pulse_count": "1"]
    )
    model.messageText = "Did you feel that?"

    model.sendText()

    let textCalls = await core.waitForTextCallCount(1)
    let context = try XCTUnwrap(textCalls.last?.stimulusContext)
    let recentStimuli = try XCTUnwrap(context.eventArguments["recent_stimuli"]?.arrayValue)
    let stimulus = try XCTUnwrap(recentStimuli.first?.objectValue)
    let inventory = try XCTUnwrap(context.eventArguments["sense_inventory"]?.arrayValue)
    let inventoryEntry = try XCTUnwrap(inventory.first?.objectValue)

    XCTAssertEqual(stimulus["id"], .number(1))
    XCTAssertEqual(stimulus["kind"]?.stringValue, "poke_sequence")
    XCTAssertEqual(stimulus["summary"]?.stringValue, "User poked once: 120ms.")
    XCTAssertEqual(stimulus["metadata"]?.objectValue?["pulse_count"]?.stringValue, "1")
    XCTAssertEqual(inventoryEntry["kind"]?.stringValue, "poke_sequence")
    XCTAssertEqual(inventoryEntry["total_count"], .number(1))
    XCTAssertEqual(inventoryEntry["recent_count"], .number(1))
  }

  @MainActor
  func testReactToBrainUtteranceDispatchesEmojiReactionAndUpdatesEntry() async throws {
    let responseEvent = expressionEvent(
      title: "Affective",
      text: "Glad that helped.",
      expressionID: "expr_reaction_ack"
    )
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "emoji_reaction"),
      textResponse: BrainTextResponse(
        toolName: "emoji_reaction",
        text: "Glad that helped.",
        metadata: [:],
        events: [responseEvent]
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    let entryID = UUID()
    model.chatEntries = [
      LogEntry(
        kind: .brain,
        title: "Affective",
        body: "Hello back.",
        metadata: ["event_id": "evt_123"],
        id: entryID
      )
    ]

    await model.reactToBrainUtterance(entryID: entryID, emoji: "👍")

    let calls = await core.emojiReactionCalls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].emoji, "👍")
    XCTAssertEqual(calls[0].utteranceText, "Hello back.")
    XCTAssertEqual(calls[0].speakerLabel, "You")
    XCTAssertEqual(calls[0].utteranceEventID, "evt_123")
    XCTAssertEqual(model.chatEntries.first?.userReaction, "👍")
  }

  func testEmojiReactionValidationAcceptsCompoundEmoji() {
    XCTAssertEqual(EmojiReactionValidation.normalizedReaction(from: " 👨‍👩‍👧‍👦 "), "👨‍👩‍👧‍👦")
    XCTAssertEqual(EmojiReactionValidation.normalizedReaction(from: "🎉"), "🎉")
    XCTAssertNil(EmojiReactionValidation.normalizedReaction(from: "hello"))
  }

  @MainActor
  func testDreamingBrainModeBlocksTypedTextBeforeCoreTurn() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "Should not send", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      brainMode: "dreaming"
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    await model.refreshBrainMode()
    model.messageText = "Are you awake?"

    model.sendText()

    let textCalls = await core.waitForTextCallCount(0)
    XCTAssertEqual(textCalls.count, 0)
    XCTAssertEqual(model.messageText, "Are you awake?")
    XCTAssertEqual(model.statusText, "Brain is dreaming")
    XCTAssertTrue(model.isBrainUnavailableForConversation)
  }

  @MainActor
  func testTypedTextPassesPriorConversationContextWithoutCurrentMessage() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "Sure.", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.recordConversationTurn(role: "user", text: "Let's design working memory.", source: "experience", metadata: ["source": "typed text"])
    model.recordConversationTurn(role: "brain", text: "We can keep a bounded recent window.", source: "expression", metadata: ["event_type": "expression"])
    model.messageText = "Now make it time-aware."

    model.sendText()

    let textCalls = await core.waitForTextCallCount(1)
    let arguments = try XCTUnwrap(textCalls.last?.stimulusContext?.eventArguments)
    let conversation = try XCTUnwrap(arguments["conversation_context"]?.objectValue)
    let turns = try XCTUnwrap(conversation["recent_turns"]?.arrayValue)

    XCTAssertEqual(turns.count, 2)
    XCTAssertEqual(turns.compactMap { $0.objectValue?["text"]?.stringValue }, [
      "Let's design working memory.",
      "We can keep a bounded recent window.",
    ])
    XCTAssertEqual(turns.compactMap { $0.objectValue?["speaker_role"]?.stringValue }, [
      "other",
      "self",
    ])
    XCTAssertFalse(turns.contains { $0.objectValue?["text"]?.stringValue == "Now make it time-aware." })
  }

  @MainActor
  func testConversationContextIncludesStableTimeFields() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let turnTime = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_030)
    model.recordConversationTurn(
      role: "user",
      text: "Remember this temporal detail?",
      source: "experience",
      metadata: [:],
      now: turnTime
    )

    let arguments = model.currentStimulusContext(kind: "user_message", now: now).eventArguments
    let conversation = try XCTUnwrap(arguments["conversation_context"]?.objectValue)
    let turn = try XCTUnwrap(conversation["recent_turns"]?.arrayValue?.first?.objectValue)

    XCTAssertEqual(arguments["local_time_unix_ms"], .number(1_030_000))
    XCTAssertTrue(arguments["local_time_iso8601"]?.stringValue?.hasPrefix("1970-01-01T00:17:10") == true)
    XCTAssertEqual(turn["occurred_at_unix_ms"], .number(1_000_000))
    XCTAssertEqual(turn["age_seconds"], .number(30))
    XCTAssertEqual(turn["speaker_role"], .string("other"))
  }

  @MainActor
  func testConversationContextCarriesIdentifiedSpeakerName() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.recordConversationTurn(
      role: "other",
      text: "Can you keep track of me?",
      source: "speech_input",
      metadata: ["speaker_name": "Mira"]
    )

    let turn = try XCTUnwrap(model.conversationContextSnapshot().recentTurns.last)
    XCTAssertEqual(turn.speakerRole, "other")
    XCTAssertEqual(turn.speakerName, "Mira")
    XCTAssertEqual(turn.eventArguments["speaker_name"], .string("Mira"))
  }

  @MainActor
  func testEmptyEventBrainResponseIsProtocolError() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "raw text without events", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.sendTextToBrain("Hello?", speakResponse: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertNil(turns.last { $0.speakerRole == "self" && $0.text == "raw text without events" })
    XCTAssertEqual(model.statusText, "Core protocol error")
    XCTAssertNotNil(model.eventEntries.last { $0.kind == .error && $0.title == "user_text" })
  }

  @MainActor
  func testEventDrivenBrainChatRecordsConversationTurnOnce() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    let result = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Event hello.")
    ], mirrorChatMessages: true, speak: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(turns.last?.speakerRole, "self")
    XCTAssertEqual(turns.last?.text, "Event hello.")
    XCTAssertEqual(turns.filter { $0.text == "Event hello." }.count, 1)
  }

  @MainActor
  func testExpressionStreamIsAuthoritativeForChatTranscript() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      brainExpressionEvent(text: "Expression hello."),
      speechRequestedEvent(text: "Expression hello.")
    ], mirrorChatMessages: true, speak: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount + 1)
    XCTAssertEqual(model.chatEntries.last?.body, "Expression hello.")
    XCTAssertEqual(turns.filter { $0.text == "Expression hello." }.count, 1)
    XCTAssertEqual(model.chatEntries.last?.metadata["event_type"], "expression")
    XCTAssertEqual(model.chatEntries.last?.metadata["modality"], "text")
  }

  @MainActor
  func testLogPresentationSpeechEventSpeaksWhenVoiceEnabled() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.brainVoiceEnabled = true

    let result = await model.applyCoreEvents([
      actionRequestEvent(
        actionID: "speech-log-fixture",
        action: "speak",
        arguments: ["text": .string("Log presentation hello.")],
        presentation: .log
      )
    ], mirrorChatMessages: true, speak: true)

    XCTAssertTrue(result.didRequestSpeech)
    XCTAssertTrue(result.didRecordBrainTurn)
    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertTrue(model.eventEntries.contains { entry in
      entry.title == "speech output" && entry.body == "apple_speech=true"
    })
  }

  @MainActor
  func testSpeechOnlyBrainEventRecordsConversationTurnOnce() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    let result = await model.applyCoreEvents([
      speechRequestedEvent(text: "Speech-only hello.")
    ], mirrorChatMessages: true, speak: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertTrue(result.didRecordBrainTurn)
    XCTAssertEqual(turns.last?.speakerRole, "self")
    XCTAssertEqual(turns.last?.source, "capability_request")
    XCTAssertEqual(turns.filter { $0.text == "Speech-only hello." }.count, 1)
  }

  func testBrainSpeechNotificationPolicy() {
    XCTAssertFalse(BrainSpeechNotificationPolicy.shouldNotify(isForeground: true, text: "Hello"))
    XCTAssertTrue(BrainSpeechNotificationPolicy.shouldNotify(isForeground: false, text: "Hello"))
    XCTAssertFalse(BrainSpeechNotificationPolicy.shouldNotify(isForeground: false, text: "  "))
    XCTAssertTrue(BrainSpeechNotificationPolicy.shouldSpeakAloud(isForeground: true, brainVoiceEnabled: true))
    XCTAssertFalse(BrainSpeechNotificationPolicy.shouldSpeakAloud(isForeground: false, brainVoiceEnabled: true))
    XCTAssertFalse(BrainSpeechNotificationPolicy.shouldSpeakAloud(isForeground: true, brainVoiceEnabled: false))
  }

  @MainActor
  func testBackgroundSpeakPostsNotificationInsteadOfSpeech() async throws {
    let mock = MockBrainSpeechNotificationClient()
    mock.authorizationStatusResult = .authorized
    let model = AffectiveViewModel(brain: try makeBrain(), brainSpeechNotifications: mock)
    model.appIsForeground = false

    let result = await model.applyCoreEvents([
      speechRequestedEvent(text: "Background hello.")
    ], mirrorChatMessages: true, speak: true)

    XCTAssertFalse(result.didRequestSpeech)
    XCTAssertEqual(mock.postCalls.count, 1)
    XCTAssertEqual(mock.postCalls.first?.brainID, model.brain.id)
    XCTAssertEqual(mock.postCalls.first?.text, "Background hello.")
  }

  @MainActor
  func testForegroundSpeakDoesNotPostNotification() async throws {
    let mock = MockBrainSpeechNotificationClient()
    let model = AffectiveViewModel(brain: try makeBrain(), brainSpeechNotifications: mock)
    model.appIsForeground = true
    model.brainVoiceEnabled = false

    _ = await model.applyCoreEvents([
      speechRequestedEvent(text: "Foreground hello.")
    ], mirrorChatMessages: true, speak: true)

    XCTAssertEqual(mock.postCalls.count, 0)
  }

  @MainActor
  func testBackgroundSpeakDeniedAuthorizationLogsEvent() async throws {
    let mock = MockBrainSpeechNotificationClient()
    mock.authorizationStatusResult = .denied
    let model = AffectiveViewModel(brain: try makeBrain(), brainSpeechNotifications: mock)
    model.appIsForeground = false

    _ = await model.applyCoreEvents([
      speechRequestedEvent(text: "Denied hello.")
    ], mirrorChatMessages: true, speak: true)

    XCTAssertEqual(mock.postCalls.count, 0)
    XCTAssertTrue(model.eventEntries.contains { $0.title == "brain speech notification" && $0.body == "not delivered" })
    XCTAssertEqual(
      model.eventEntries.last { $0.title == "brain speech notification" }?.metadata["authorization"],
      "denied"
    )
  }

  @MainActor
  func testBotActionClickSoundSurvivesRapidPlayback() {
    for _ in 0..<8 {
      BrainNotificationSounds.shared.playBotActionClick()
    }
    BrainNotificationSounds.shared.playSpeechNotification()
  }

  @MainActor
  func testShouldPlayBotActionClickMatchesSkillActionsOnly() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    XCTAssertTrue(model.shouldPlayBotActionClick(for: controlEvent(id: "action-say", status: "say")))
    XCTAssertFalse(model.shouldPlayBotActionClick(for: controlEvent(id: "status-ready", status: "Ready")))
    XCTAssertFalse(model.shouldPlayBotActionClick(for: controlEvent(id: "control-off", sendEnabled: false)))
  }

  @MainActor
  func testConversationTurnsRollIntoSummaryAfterLimit() throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    for index in 0..<18 {
      model.recordConversationTurn(
        role: index.isMultiple(of: 2) ? "user" : "brain",
        text: "Turn \(index)",
        source: "test",
        metadata: [:]
      )
    }

    let snapshot = model.conversationContextSnapshot()
    XCTAssertEqual(snapshot.recentTurns.count, AffectiveViewModel.conversationRecentTurnLimit)
    XCTAssertTrue(snapshot.rollingSummary.contains("other: Turn 0"))
    XCTAssertTrue(snapshot.rollingSummary.contains("A brain: Turn 1"))
    XCTAssertEqual(snapshot.recentTurns.first?.text, "Turn 2")
  }

  @MainActor
  func testImageMessageRecordsConversationTurnWithMediaMetadata() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.messageText = "Look at this sketch."

    model.sendImage(data: Self.tinyPNGData, suggestedName: "sketch.png")
    let textCalls = await core.waitForTextCallCount(1)
    let mediaEvents = await core.waitForExperienceEventCallCount(1)
    let mediaEvent = try XCTUnwrap(mediaEvents.last)
    XCTAssertEqual(mediaEvent.arguments["kind"]?.stringValue, "User.MediaUploaded")
    XCTAssertEqual(mediaEvent.arguments["source"]?.stringValue, "user")
    XCTAssertEqual(mediaEvent.arguments["retention"]?.stringValue, "episode")
    XCTAssertEqual(mediaEvent.arguments["visibility"]?.stringValue, "host")
    XCTAssertEqual(mediaEvent.arguments["salience"], .number(0.65))
    let mediaPayload = try XCTUnwrap(mediaEvent.arguments["payload"]?.stringValue)
    XCTAssertTrue(mediaPayload.contains("\"media_kind\":\"image\""))
    XCTAssertTrue(mediaPayload.contains("\"mime_type\":\"image/png\""))

    let imageTurn = try XCTUnwrap(model.conversationContextSnapshot().recentTurns.last)
    XCTAssertEqual(imageTurn.speakerRole, "other")
    XCTAssertEqual(imageTurn.source, "image")
    XCTAssertEqual(imageTurn.metadata["media_kind"], "image")
    XCTAssertEqual(imageTurn.metadata["mime_type"], "image/png")
    XCTAssertNotNil(imageTurn.metadata["image_path"])
    XCTAssertNil(imageTurn.metadata["original_bytes"])

    let callContext = try XCTUnwrap(textCalls.last?.stimulusContext?.eventArguments["conversation_context"]?.objectValue)
    let sentContextTurns = try XCTUnwrap(callContext["recent_turns"]?.arrayValue)
    XCTAssertFalse(sentContextTurns.contains { $0.objectValue?["text"]?.stringValue == "Look at this sketch." })
  }

  @MainActor
  func testFacialExpressionRequestStaysOutOfChatForStaticAvatar() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      facialExpressionEvent(eyes: "bright eyes", mouth: "small smile")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertEqual(model.eventEntries.last?.title, "facial expression")
    XCTAssertEqual(model.eventEntries.last?.body, "bright eyes / small smile")
  }

  @MainActor
  func testEmoteMirrorsToChatEvenWhenMirrorChatMessagesDisabled() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      emoteExpressionEvent(text: "*waves*")
    ], mirrorChatMessages: false, speak: false)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount + 1)
    XCTAssertEqual(model.chatEntries.last?.kind, .emote)
    XCTAssertEqual(model.chatEntries.last?.body, "waves")
    XCTAssertEqual(model.eventEntries.last?.title, "emote")
    XCTAssertEqual(model.eventEntries.last?.body, "waves")
  }

  @MainActor
  func testEmoteDoesNotTriggerTTS() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.brainVoiceEnabled = true

    let result = await model.applyCoreEvents([
      emoteExpressionEvent(text: "*sighs*")
    ], mirrorChatMessages: true, speak: true)

    XCTAssertFalse(result.didRequestSpeech)
    XCTAssertNil(result.resolvedBrainText)
  }

  @MainActor
  func testFacialExpressionLogsToDeveloperConsoleWithoutMirroringChat() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    _ = await model.applyCoreEvents([
      facialExpressionEvent(eyes: "stern", mouth: "frown")
    ], mirrorChatMessages: false, speak: false)

    XCTAssertEqual(model.eventEntries.last?.title, "facial expression")
    XCTAssertEqual(model.eventEntries.last?.body, "stern / frown")
  }

  @MainActor
  func testDeveloperLogEventReachesDeveloperConsole() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    _ = await model.applyCoreEvents([
      BrainEvent(
        id: "developer-log-fixture",
        traceID: "trace-developer-log-fixture",
        parentID: nil,
        turnID: nil,
        loopID: nil,
        occurredAt: "2026-06-26T00:00:00Z",
        source: .brain,
        target: .host,
        visibility: .diagnostic,
        presentation: .log,
        payload: .developerLog(BrainDeveloperLogPayload(
          kind: "sent",
          title: "think_about",
          body: "action=think_about\nquery=energy"
        ))
      )
    ], mirrorChatMessages: false, speak: false)

    XCTAssertEqual(model.eventEntries.last?.kind, .sent)
    XCTAssertEqual(model.eventEntries.last?.title, "think_about")
    XCTAssertEqual(model.eventEntries.last?.body, "action=think_about\nquery=energy")
  }

  @MainActor
  func testFacialExpressionRequestSkipsChatAsideForExpressionAvatar() async throws {
    let brain = try makeBrainWithExpressionAvatar()
    let model = AffectiveViewModel(brain: brain)
    let initialChatCount = model.chatEntries.count

    _ = await model.applyCoreEvents([
      facialExpressionEvent(eyes: "bright eyes", mouth: "small smile")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertEqual(model.eventEntries.last?.title, "facial expression")
    XCTAssertEqual(model.eventEntries.last?.body, "bright eyes / small smile")
  }

  @MainActor
  func testGenericBrainEventTitleIgnoresCognitiveDatabaseIdentity() async throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 1,
          "brain_name": "Otto",
          "traces": [],
          "beliefs": [],
          "subjects": [],
          "artifacts": [],
          "dreams": []
        }
        """
    )
    let model = AffectiveViewModel(brain: brain)

    let result = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Hello from the core.")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.last?.title, "A brain")
    XCTAssertEqual(model.chatEntries.last?.body, "Hello from the core.")
  }

  @MainActor
  func testGenericBrainEventTitleUsesGenericNameWithoutFactIdentity() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    let result = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Hello from the core.")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.last?.title, "A brain")
    XCTAssertEqual(model.chatEntries.last?.body, "Hello from the core.")
  }

  @MainActor
  func testBrainEventTitleDoesNotOverrideSenderName() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    _ = await model.applyCoreEvents([
      brainChatEvent(title: "Dream", text: "I found a dream image.")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertEqual(model.chatEntries.last?.title, "A brain")
  }

  @MainActor
  func testBrainVoiceTogglePersistsAndStopsSpeechOutput() async throws {
    let brain = try makeBrain()
    let model = AffectiveViewModel(brain: brain)

    XCTAssertTrue(model.brainVoiceEnabled)

    model.setBrainVoiceEnabled(false)

    XCTAssertFalse(model.brainVoiceEnabled)
    XCTAssertFalse(UserDefaults.standard.bool(forKey: AffectiveViewModel.brainVoiceEnabledKey))
    XCTAssertEqual(model.statusText, "Brain voice disabled")

    let relaunchedModel = AffectiveViewModel(brain: brain)
    XCTAssertFalse(relaunchedModel.brainVoiceEnabled)
  }

  @MainActor
  func testSpeechRequestsAreSkippedWhenBrainVoiceIsDisabled() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.setBrainVoiceEnabled(false)

    let result = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Hello from the core."),
      speechRequestedEvent(text: "Hello from the core.")
    ], mirrorChatMessages: true, speak: true)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertTrue(result.didRequestSpeech)
    XCTAssertEqual(model.chatEntries.last?.body, "Hello from the core.")
    XCTAssertFalse(model.eventEntries.contains { entry in
      entry.title == "speech output" && entry.body == "apple_speech=true"
    })
    XCTAssertTrue(model.eventEntries.contains { entry in
      entry.title == "speech output" && entry.body == "apple_speech=false"
    })
  }

  @MainActor
  func testBotActionClickStillEligibleWhenBrainVoiceIsDisabled() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.setBrainVoiceEnabled(false)

    XCTAssertTrue(model.shouldPlayBotActionClick(for: controlEvent(id: "action-say", status: "say")))
  }

  @MainActor
  func testKnownPersonFactSubjectDoesNotBecomeBrainSenderName() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 1,
          "traces": [],
          "beliefs": [],
          "subjects": [
            {
              "subject_id": "person_1",
              "display_name": "Zelda",
              "relationship_status": "creator"
            }
          ],
          "artifacts": [],
          "dreams": []
        }
        """
    )
    let model = AffectiveViewModel(brain: brain)

    XCTAssertEqual(model.brainSenderName, "A brain")
  }

  @MainActor
  func testBrainSenderNameIgnoresProfileDisplayNameDefault() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    _ = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Still here.")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertEqual(model.chatEntries.last?.title, "A brain")
  }

  @MainActor
  func testRefreshMailboxItemsSkipsCoreWhenBrainIsNotConnected() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "mailbox_list"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)

    model.refreshMailboxItems()
    try await Task.sleep(nanoseconds: 50_000_000)

    let callCount = await core.mailboxListCallCount
    XCTAssertEqual(callCount, 0)
  }

  @MainActor
  func testBoredomSenseOnlyEmitsWhenAwakeIdleAndAutonomyIsOn() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isBrainConnected = true
    model.autonomyMode = "on"
    model.lastHostStimulusAt = Date(timeIntervalSinceNow: -700)

    XCTAssertTrue(model.canEmitBoredomStimulus(waitSeconds: 600))

    model.autonomyMode = "off"
    XCTAssertFalse(model.canEmitBoredomStimulus(waitSeconds: 600))

    model.autonomyMode = "on"
    model.hostPipelineHold = .speechOutput
    XCTAssertFalse(model.canEmitBoredomStimulus(waitSeconds: 600))
  }

  @MainActor
  func testNextBoredomWaitSecondsStaysWithinConfiguredRange() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    for _ in 0..<20 {
      let waitSeconds = model.nextBoredomWaitSeconds()
      XCTAssertGreaterThanOrEqual(waitSeconds, AffectiveViewModel.boredomIntervalMinSeconds)
      XCTAssertLessThanOrEqual(waitSeconds, model.boredomIntervalMaxSeconds)
    }
  }

  @MainActor
  func testBoredomStimulusUsesPatientInternalContext() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isBrainConnected = true
    model.autonomyMode = "on"
    model.lastHostStimulusAt = Date(timeIntervalSinceNow: -620)

    let text = model.boredomStimulusText(idleSeconds: 620)
    let summary = model.boredomStimulusSummary(idleSeconds: 620)
    let context = model.currentStimulusContext(kind: "boredom")

    XCTAssertTrue(text.contains("620 seconds"))
    XCTAssertTrue(text.contains("You feel bored."))
    XCTAssertEqual(summary, "Host quiet for 620s.")
    XCTAssertEqual(context.kind, "boredom")
    XCTAssertEqual(context.receivedDuring, "idle")
  }

  @MainActor
  func testSocialResponseWindowAppearsInStimulusContextAndClearsOnInput() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let now = Date()

    model.markAwaitingSocialResponse(now: now)

    let awaitingContext = model.currentStimulusContext(kind: "user_message", now: now.addingTimeInterval(1))
    XCTAssertEqual(awaitingContext.receivedDuring, "awaiting_social_response")
    XCTAssertTrue(awaitingContext.awaitingSocialResponse)
    XCTAssertGreaterThan(awaitingContext.socialTurnResponseWindowRemainingSeconds, 0)

    model.recordConversationTurn(role: "user", text: "I'm still here.", source: "experience", metadata: [:])

    let clearedContext = model.currentStimulusContext(kind: "user_message", now: now.addingTimeInterval(2))
    XCTAssertEqual(clearedContext.receivedDuring, "idle")
    XCTAssertFalse(clearedContext.awaitingSocialResponse)
  }

  @MainActor
  func testTypingActivityMarksCounterpartActiveWithoutSubmittedTurn() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let now = Date()

    model.markCounterpartActive(now: now)

    let activeContext = model.currentStimulusContext(kind: "user_message", now: now.addingTimeInterval(1))
    XCTAssertTrue(activeContext.counterpartActive)
    XCTAssertGreaterThan(activeContext.counterpartActivityWindowRemainingSeconds, 0)
    XCTAssertTrue(activeContext.conversationContext.recentTurns.isEmpty)

    let expiredContext = model.currentStimulusContext(
      kind: "user_message",
      now: now.addingTimeInterval(AffectiveViewModel.counterpartActivityWindowSeconds + 1)
    )
    XCTAssertFalse(expiredContext.counterpartActive)
  }

  @MainActor
  func testAwaitingChatResponseDoesNotDisableSend() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isHostPipelineRunning = true
    model.messageText = "Hello?"

    model.sendText()

    XCTAssertTrue(model.isAwaitingChatResponse)
    XCTAssertTrue(model.canSend)
    XCTAssertTrue(model.hostPipelineQueue.isEmpty)
  }

  @MainActor
  func testInterruptSupersedingUserMessageDoesNotLeakAwaitingChatResponse() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(
        toolName: "user_text",
        text: "ok",
        metadata: [:],
        events: [
          brainChatEvent(title: "Brain", text: "ok")
        ],
        shouldSpeak: false
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      blockedTextCallCount: 1
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.messageText = "first"
    model.sendText()
    _ = await core.waitForTextCallCount(1)

    XCTAssertTrue(model.isAwaitingChatResponse)
    XCTAssertEqual(model.pendingChatResponseCount, 1)

    model.messageText = "interrupt"
    model.sendText(interrupt: true)

    XCTAssertTrue(model.isAwaitingChatResponse)
    XCTAssertEqual(model.pendingChatResponseCount, 1)
    let interruptCalls = await core.interruptCalls
    XCTAssertEqual(interruptCalls.count, 1)
    XCTAssertEqual(interruptCalls[0].userText, "interrupt")
    XCTAssertEqual(interruptCalls[0].reason, "user_requested_interrupt")

    await core.resumeBlockedTextSends()
    for _ in 0..<50 {
      if !model.isAwaitingChatResponse {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertFalse(model.isAwaitingChatResponse)
    XCTAssertEqual(model.pendingChatResponseCount, 0)
    let textCalls = await core.textCalls
    XCTAssertEqual(textCalls.count, 2)
  }

  @MainActor
  func testImmediateUserMessageReachCoreWhilePullSenseFulfillmentInFlight() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(
        toolName: "user_text",
        text: "Waiting on camera.",
        metadata: ["awaiting_host_sense": "true"],
        events: [
          senseRequestEvent(
            requestID: "recognize-camera",
            sense: "camera",
            title: "camera sense",
            summary: "frontend camera sense requested",
            responsePresentation: .status
          )
        ]
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      cameraObservationDelayNanoseconds: 500_000_000
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }

    model.messageText = "first"
    model.sendText()
    _ = await core.waitForTextCallCount(1)
    try await Task.sleep(for: .milliseconds(50))

    model.messageText = "second"
    model.sendText()

    let textCalls = await core.waitForTextCallCount(2)
    XCTAssertEqual(textCalls[1].text, "second")
  }

  @MainActor
  func testActivityStatusEventUpdatesHostStatusWithoutChatBubble() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    _ = await model.applyCoreEvents([
      attentionStatusEvent(
        id: "activity-fixture",
        title: "Learning your name",
        summary: "Waiting for your name."
      )
    ], mirrorChatMessages: true, speak: false)

    XCTAssertEqual(model.statusText, "Waiting for your name.")
    XCTAssertEqual(model.eventEntries.last?.title, "Learning your name")
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
  }

  func testOrientationPromptAdvertisesGenericSenseObservation() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: false, orientationStatus: "prompt_required").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertTrue(capabilities.contains("orientation_read"))
    XCTAssertTrue(capabilities.contains("orientation_read"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["orientation"], .string("prompt_required"))
  }

  func testOrientationDeniedRemovesGenericSenseObservation() throws {
    // The capability remains advertised while permission state carries current availability.
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(
        hasProvider: false,
        cameraStatus: "denied",
        orientationStatus: "denied",
        motionGestureStatus: "disabled").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertTrue(capabilities.contains("orientation_read"))
    XCTAssertTrue(capabilities.contains("camera_capture"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["orientation"], .string("denied"))
  }

  func testOrientationClassifierReturnsCompactPostures() {
    let faceUp = OrientationQueryProvider.classify(x: 0.02, y: 0.01, z: -0.99)
    XCTAssertEqual(faceUp.posture, "face_up")
    XCTAssertEqual(faceUp.summary, "The device is lying face up.")
    XCTAssertEqual(faceUp.confidence, 0.99)

    let landscape = OrientationQueryProvider.classify(x: 0.91, y: 0.05, z: 0.02)
    XCTAssertEqual(landscape.posture, "landscape_left")
    XCTAssertEqual(landscape.gravityX, 0.91)
  }

  func testEmbeddedProtocolContractBuildsWrapperDispatchRequests() throws {
    for eventType in EmbeddedProtocolContract.wrapperDispatchEventTypes {
      let request: JSONValue = .object([
        "request_id": .string("fixture-\(eventType)"),
        "event": .object(["payload": .object([eventType: .object([:])])]),
      ])
      let fixture = try JSONValue.decodedObject(from: request.encodedData())

      XCTAssertEqual(fixture["request_id"], .string("fixture-\(eventType)"))
      XCTAssertNotNil(fixture["event"]?.objectValue?["payload"]?.objectValue?[eventType])
    }
  }

  func testGenerationProviderE2EAgainstEnabledProviders() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["AFFECTIVE_RUN_GENERATION_PROVIDER_E2E"] == "1" else {
      throw XCTSkip(
        "Set AFFECTIVE_RUN_GENERATION_PROVIDER_E2E=1 to run live generation provider checks.")
    }

    let credentials = providerCredentials(from: environment)
    guard !credentials.isEmpty else {
      throw XCTSkip("No provider API keys found in the test environment.")
    }

    let brain = try makeBrain()
    let report = try BrainCore.runGenerationProviderE2E(
      brain: brain, providerCredentials: credentials)
    let object = try JSONValue.decodedObject(from: Data(report.utf8))

    XCTAssertEqual(object["ok"], .bool(true))
    XCTAssertNotNil(object["text_json_contracts"])
    XCTAssertNotNil(object["vision_json_contracts"])
    XCTAssertNotNil(object["health_routes"])
    XCTAssertNotNil(object["provider_image_generation_checked"])
  }

  func testBrainToolResponsePrefersEventEnvelope() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: encodedEnvelopeText(
      requestID: "test-request",
      events: [
        controlEvent(id: "control-off", sendEnabled: false),
        speechRequestedEvent(text: "I found one memory."),
        expressionEvent(title: nil, text: "Here is what I remember.", expressionID: "remember-expression"),
        controlEvent(id: "control-on", sendEnabled: true),
      ],
      result: .object([
        "event_type": .string("memory_result"),
        "summary": .string("memory result handled by event stream"),
        "raw_result": .bool(true),
      ]),
      budget: BrainDispatchBudget(
        maxBytes: 16384,
        usedBytes: 512,
        compacted: false,
        droppedEventCount: 0,
        rawRefs: []
      )
    ))

    let response = BrainToolResponse(toolName: "user_text", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "Here is what I remember.")
    XCTAssertTrue(response.shouldSpeak)
    XCTAssertEqual(response.events.count, 4)
    XCTAssertEqual(response.metadata["display_source"], "event_envelope")
    XCTAssertEqual(response.metadata["event_types"], "control,capability_request,expression")
    XCTAssertEqual(response.metadata["budget_max_bytes"], "16384")
  }

  func testBrainDispatchEnvelopeSynthesizesEventsFromSpokenOutcome() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "request_id": "user-text-request",
        "ok": true,
        "events": [],
        "result": {
          "event_type": "user_text",
          "value": {
            "kind": "user_text",
            "outcome": {
              "spoken_text": "Hello from the core.",
              "text": "Hello from the core."
            }
          }
        }
      }
      """#)

    let resolved = envelope.resolvedEvents()
    XCTAssertEqual(resolved.count, 2)
    XCTAssertEqual(resolved[0].type, "expression")
    XCTAssertEqual(resolved[0].text, "Hello from the core.")
    XCTAssertEqual(resolved[1].type, "capability_request")
    XCTAssertEqual(resolved[1].capability, "speak")
  }

  func testBrainDispatchEnvelopeDecodesZigHostEffectEventsLeniently() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "request_id": "user-text-request",
        "ok": true,
        "events": [
          {
            "id": "user-text-request_0_capability_request",
            "trace_id": "user-text-request_0_capability_request",
            "turn_id": "user-text-request",
            "source": "brain",
            "target": "host",
            "visibility": "public",
            "presentation": "chat",
            "type": "capability_request",
            "payload": {
              "capability_request": {
                "action_id": "user-text-request_0_capability_request",
                "action": "speak",
                "arguments": { "text": "Hello!" },
                "requires": ["speech_output"],
                "await_response": false
              }
            }
          },
          {
            "id": "expression_1",
            "trace_id": "expression_1",
            "turn_id": "user-text-request",
            "source": "brain",
            "target": "host",
            "visibility": "public",
            "presentation": "chat",
            "type": "expression",
            "payload": {
              "expression": {
                "modality": "text",
                "role": "brain",
                "title": "Brain",
                "text": "Hello!",
                "media": [],
                "expression_id": "expression_1"
              }
            }
          }
        ],
        "result": {
          "event_type": "user_text",
          "value": { "kind": "user_text" }
        }
      }
      """#)

    XCTAssertEqual(envelope.events.count, 2)
    XCTAssertEqual(envelope.events.first?.capability, "speak")
    XCTAssertEqual(envelope.events.last?.text, "Hello!")
  }

  func testBrainToolResponseIgnoresEnvelopeResultSummaryWithoutEvents() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: encodedEnvelopeText(
      requestID: "test-request",
      events: [],
      result: .object([
        "event_type": .string("memory_result"),
        "summary": .string("memory result handled by event stream"),
        "raw_result": .bool(true),
      ]),
      budget: BrainDispatchBudget(
        maxBytes: 16384,
        usedBytes: 180,
        compacted: false,
        droppedEventCount: 0,
        rawRefs: []
      )
    ))

    let response = BrainToolResponse(toolName: "user_text", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "")
    XCTAssertEqual(response.metadata["display_source"], "empty")
    XCTAssertEqual(response.metadata["display_text_length"], "0")
  }

  func testBrainToolResponseDoesNotDisplayDirectTouchResultSummary() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "request_id": "touch-request",
        "ok": true,
        "events": [],
        "result": {
          "event_type": "short_touch",
          "summary": "touch stimulus received",
          "raw_result": false
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 23,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    let response = BrainToolResponse(toolName: "short_touch", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "")
    XCTAssertEqual(response.metadata["display_source"], "empty")
    XCTAssertEqual(response.metadata["display_text_length"], "0")
    XCTAssertEqual(response.metadata["event_types"], "")
  }

  func testBrainDispatchEnvelopeDecodesEnvelopes() throws {
    let success = try BrainDispatchEnvelope.decode(from: encodedEnvelopeText(
      requestID: "fixture-success-001",
      events: [
        controlEvent(id: "fixture-success-001-control-off", sendEnabled: false),
        expressionEvent(
          title: "AMBI",
          text: "I found one memory about soldering.",
          expressionID: "fixture-success-001-expression"
        ),
        actionRequestEvent(
          actionID: "fixture-success-001-speech",
          action: "speak",
          arguments: ["text": .string("I found one memory about soldering.")]
        ),
        controlEvent(id: "fixture-success-001-control-on", sendEnabled: true),
      ],
      result: .object([
        "event_type": .string("user_text"),
        "value": .object([
          "kind": .string("user_text"),
          "outcome": .object([
            "text": .string("What do you remember about soldering?"),
            "spoken_text": .string("I found one memory about soldering."),
            "user_summary": .string("Asked for soldering memories."),
            "brain_summary": .string("Shared a soldering memory."),
            "interrupted_by": .null,
          ]),
        ]),
      ]),
      budget: BrainDispatchBudget(
        maxBytes: 16384,
        usedBytes: 780,
        compacted: false,
        droppedEventCount: 0,
        rawRefs: []
      )
    ))

    XCTAssertTrue(success.ok)
    XCTAssertEqual(success.requestID, "fixture-success-001")
    XCTAssertEqual(success.events.count, 4)
    XCTAssertEqual(success.events.first?.id, "fixture-success-001-control-off")
    XCTAssertEqual(success.displayTextFromEvents, "I found one memory about soldering.")
    XCTAssertEqual(success.structuredResultValue?.objectValue?["kind"]?.stringValue, "user_text")
    XCTAssertEqual(success.displayText, "I found one memory about soldering.")
    XCTAssertEqual(success.awaitingHostSense, false)

    let paused = try BrainDispatchEnvelope.decode(from: encodedEnvelopeText(
      requestID: "fixture-paused-001",
      events: [
        senseRequestEvent(
          requestID: "fixture-paused-sense",
          sense: "camera",
          title: "camera sense",
          summary: "frontend camera sense requested",
          responsePresentation: .status
        ),
      ],
      result: .object([
        "event_type": .string("user_text"),
        "value": .object([
          "kind": .string("user_text"),
          "outcome": .object([
            "text": .string("do you recognize me?"),
            "spoken_text": .string(""),
            "user_summary": .string("Asked about recognition."),
            "brain_summary": .string("Requested camera capture."),
            "interrupted_by": .null,
            "awaiting_host_sense": .bool(true),
            "awaited_host_sense": .string("camera"),
            "awaited_host_purpose": .string("recognize"),
            "awaited_host_timeout_ms": .number(8_000),
          ]),
        ]),
      ]),
      budget: BrainDispatchBudget(
        maxBytes: 16384,
        usedBytes: 780,
        compacted: false,
        droppedEventCount: 0,
        rawRefs: []
      )
    ))

    XCTAssertTrue(paused.awaitingHostSense)
    XCTAssertEqual(paused.displayText, "")
    XCTAssertEqual(paused.metadata()["awaiting_host_sense"], "true")
    XCTAssertEqual(paused.metadata()["awaited_host_sense"], "camera")
    XCTAssertEqual(paused.metadata()["awaited_host_purpose"], "recognize")
    XCTAssertEqual(paused.metadata()["awaited_host_timeout_ms"], "8000")
    XCTAssertEqual(paused.awaitingHostSenseStateLabel, "awaiting host sense: camera/recognize (8000ms)")
    XCTAssertEqual(paused.metadata()["user_summary_present"], "true")

    let drain = try BrainDispatchEnvelope.decode(from: encodedEnvelopeText(
      requestID: "",
      events: [
        memoryMutationEvent(id: "fixture-tool-call-001", summary: "memory_saved"),
        controlEvent(id: "fixture-tool-call-002", status: "Ready"),
      ],
      result: .object(["kind": .string("drain")]),
      budget: BrainDispatchBudget(
        maxBytes: 16384,
        usedBytes: 220,
        compacted: false,
        droppedEventCount: 0,
        rawRefs: []
      )
    ))

    XCTAssertTrue(drain.ok)
    XCTAssertEqual(drain.events.count, 2)
    XCTAssertEqual(drain.events.first?.id, "fixture-tool-call-001")

    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "request_id": "fixture-error-001",
        "ok": false,
        "events": [],
        "error": {
          "code": "unknown_event_type",
          "message": "unknown embedded event type",
          "recoverable": false
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 0,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    XCTAssertFalse(envelope.ok)
    XCTAssertEqual(envelope.error?.code, "unknown_event_type")
    XCTAssertEqual(envelope.error?.message, "unknown embedded event type")
    XCTAssertEqual(envelope.error?.recoverable, false)
  }

  func testBrainEventPayloadRoundTripsEveryCase() throws {
    let media = BrainMediaRef(
      kind: .image,
      path: "/tmp/image.png",
      url: nil,
      mimeType: "image/png",
      caption: "fixture"
    )
    let payloads: [BrainEventPayload] = [
      .experience(BrainExperiencePayload(
        kind: "user_message",
        modality: .text,
        role: .other,
        text: "hello",
        media: [],
        context: .object(["local_time": .string("now")])
      )),
      .senseRequest(BrainSenseRequestPayload(
        senseID: "camera",
        direction: .pull,
        timeoutMS: 100,
        responsePresentation: .chat
      )),
      .senseObservation(BrainSenseObservationPayload(
        senseID: "camera",
        modality: .image,
        summary: "image captured",
        media: [media],
        value: .object(["width": .number(1)]),
        confidence: 0.9,
        observedAt: "2026-06-26T00:00:00Z"
      )),
      .capabilityManifest(BrainCapabilityManifestPayload(
        capabilities: [BrainCapabilityDescriptor(id: "speech_output", status: "available", reason: nil)],
        senses: [BrainCapabilityDescriptor(id: "camera", status: "prompt_required", reason: "permission")]
      )),
      .capabilityStatus(BrainCapabilityStatusPayload(
        capabilityID: "camera_capture",
        status: nil,
        reason: nil,
        permission: "granted",
        availability: "available",
        quality: 0.9,
        reliability: 0.8,
        cost: 0.0,
        latencyMS: 0,
        risk: 0.05,
        unavailableReason: nil
      )),
      .thought(BrainThoughtPayload(text: "I should answer.", salience: 0.6, tags: ["reply"])),
      .appraisal(BrainAppraisalPayload(
        valence: 0.2,
        arousal: 0.4,
        salience: 0.7,
        confidence: 0.8,
        novelty: 0.3,
        tags: ["safe"],
        summary: "warm"
      )),
      .needState(BrainNeedStatePayload(needs: ["connection": 0.7], summary: "connected")),
      .attentionState(BrainAttentionStatePayload(
        focusEventID: "event-1",
        competingEventIDs: ["event-2"],
        summary: "selected user text",
        suppressionReason: "lower salience"
      )),
      .intention(BrainIntentionPayload(
        goal: "respond",
        priority: 0.8,
        expectedAction: "speak",
        stoppingCondition: "answer delivered"
      )),
      .capabilityRequest(BrainActionRequestPayload(
        actionID: "action-1",
        action: "speak",
        arguments: .object(["text": .string("hello")]),
        requires: ["speech_output"],
        awaitResponse: true
      )),
      .actionResult(BrainActionResultPayload(
        actionID: "action-1",
        status: .succeeded,
        summary: "spoken",
        result: .object(["duration_ms": .number(10)]),
        error: nil
      )),
      .expression(BrainExpressionPayload(
        modality: .text,
        role: .selfRole,
        title: "Brain",
        text: "hello",
        media: [],
        expressionID: "expression-1",
        eyes: nil,
        mouth: nil,
        durationMS: nil
      )),
      .memoryResult(BrainMemoryResultPayload(
        operation: .recall,
        records: [BrainMemoryRecord(
          id: "memory-1",
          layer: .episodic,
          summary: "said hello",
          relevance: 0.8,
          confidence: 0.9
        )],
        summary: "one memory"
      )),
      .memoryMutation(BrainMemoryMutationPayload(
        operation: .remember,
        layer: .episodic,
        recordIDs: ["memory-1"],
        summary: "stored greeting"
      )),
      .control(BrainControlPayload(phase: .thinking, sendEnabled: false, status: "thinking")),
      .error(BrainEventErrorPayload(code: "fixture", message: "fixture error", recoverable: true)),
    ]

    for payload in payloads {
      let event = BrainEvent(
        id: "event-\(payload.eventType)",
        traceID: "trace-\(payload.eventType)",
        parentID: nil,
        turnID: "turn-1",
        loopID: "loop-1",
        occurredAt: "2026-06-26T00:00:00Z",
        source: .brain,
        target: .host,
        visibility: .diagnostic,
        presentation: .internalOnly,
        payload: payload
      )
      let data = try JSONEncoder().encode(event)
      let decoded = try JSONDecoder().decode(BrainEvent.self, from: data)
      XCTAssertEqual(decoded, event)
    }
  }

  func testBrainEventEnvelopeDoesNotEncodeTopLevelType() throws {
    let event = expressionEvent(title: "Brain", text: "hello")
    let object = try JSONValue.decodedObject(from: try JSONEncoder().encode(event))

    XCTAssertNil(object["type"])
    XCTAssertNotNil(object["payload"]?.objectValue?["expression"])
    XCTAssertEqual(event.type, "expression")
  }

  func testBrainEventRejectsMissingRequiredEnvelopeID() throws {
    let malformed = Data(#"""
      {
        "trace_id": "trace-1",
        "occurred_at": "2026-06-26T00:00:00Z",
        "source": "brain",
        "target": "host",
        "visibility": "diagnostic",
        "presentation": "internal",
        "payload": {
          "thought": {
            "text": "hello",
            "salience": null,
            "tags": []
          }
        }
      }
      """#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(BrainEvent.self, from: malformed))
  }

  func testBrainEventRejectsTopLevelExpressionWithoutEnvelope() throws {
    let malformed = Data(#"""
      {
        "type": "expression",
        "role": "user",
        "text": "hello"
      }
      """#.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(BrainEvent.self, from: malformed))
  }

  func testBrainEventUnknownRoleDecodesAsUnknown() throws {
    let event = Data(#"""
      {
        "id": "event-unknown-role",
        "trace_id": "trace-unknown-role",
        "occurred_at": "2026-06-26T00:00:00Z",
        "source": "brain",
        "target": "host",
        "visibility": "public",
        "presentation": "chat",
        "payload": {
          "expression": {
            "modality": "text",
            "role": "future_role",
            "title": "Brain",
            "text": "hello",
            "media": [],
            "expression_id": "expression-unknown-role"
          }
        }
      }
      """#.utf8)

    let decoded = try JSONDecoder().decode(BrainEvent.self, from: event)
    XCTAssertEqual(decoded.role, "unknown")
  }

  func testMissingRequiredFileFailsCoreValidation() throws {
    let brain = try makeBrain()
    try FileManager.default.removeItem(at: brain.runtimeOptionsURL)

    XCTAssertThrowsError(try brain.validateForCoreConnection()) { error in
      XCTAssertEqual(error as? BrainValidationError, .missingFile("runtime_options.json"))
    }
  }

  func testInvalidRuntimeOptionsFailsCoreValidation() throws {
    let brain = try makeBrain(runtimeOptions: "[]")

    XCTAssertThrowsError(try brain.validateForCoreConnection()) { error in
      XCTAssertEqual(
        error as? BrainValidationError,
        .invalidJSON("runtime_options.json", detail: "expected a JSON object")
      )
    }
  }

  func testDeprecatedRuntimeOptionsAreSanitized() throws {
    let storedValues: [String: Any] = [
      "activation_mode": "webview",
      "camera_mode": "webcam",
      "seed_path": "data/seeds/default.md",
      "brain_id": "default",
      "speech_voice": "Fred",
    ]

    let sanitized = sanitizeDeprecatedRuntimeOptions(storedValues)

    XCTAssertEqual(sanitized["speech_voice"] as? String, "Fred")
    XCTAssertNil(sanitized["activation_mode"])
    XCTAssertNil(sanitized["camera_mode"])
    XCTAssertNil(sanitized["seed_path"])
    XCTAssertNil(sanitized["brain_id"])
  }

  @MainActor
  func testMakeUpLostDreamTimeDefaultsOff() throws {
    let option = try XCTUnwrap(AffectiveViewModel.loadOptionGroups(storedValues: [:], brain: nil)
      .flatMap(\.options)
      .first { $0.key == AffectiveViewModel.makeUpLostDreamTimeOptionKey })

    XCTAssertEqual(option.label, "Make up for lost dream time")
    XCTAssertEqual(option.value, "off")
  }

  @MainActor
  func testLlmQualityDefaultsToAuto() throws {
    let option = try XCTUnwrap(AffectiveViewModel.loadOptionGroups(storedValues: [:], brain: nil)
      .flatMap(\.options)
      .first { $0.key == AffectiveViewModel.llmQualityOptionKey })

    XCTAssertEqual(option.label, "LLM quality")
    XCTAssertEqual(option.value, "auto")
    XCTAssertTrue(option.requiresRestart)
  }

  @MainActor
  func testLlmQualityLoadsStoredValue() throws {
    let option = try XCTUnwrap(AffectiveViewModel.loadOptionGroups(
      storedValues: [AffectiveViewModel.llmQualityOptionKey: "best"],
      brain: nil
    )
    .flatMap(\.options)
    .first { $0.key == AffectiveViewModel.llmQualityOptionKey })

    XCTAssertEqual(option.value, "best")
  }

  @MainActor
  func testMakeUpLostDreamTimeLoadsStoredValue() throws {
    let option = try XCTUnwrap(AffectiveViewModel.loadOptionGroups(
      storedValues: [AffectiveViewModel.makeUpLostDreamTimeOptionKey: "on"],
      brain: nil
    )
    .flatMap(\.options)
    .first { $0.key == AffectiveViewModel.makeUpLostDreamTimeOptionKey })

    XCTAssertEqual(option.value, "on")
  }

  func testAvatarManifestRoundTripsAndSortsLayers() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarManifest-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let manifest = BrainAvatarManifest(
      canvas: .init(width: 1024, height: 1536),
      clip: .init(x: 112, y: 64, width: 800, height: 1000),
      layers: [
        .init(
          id: "hair", name: "Hair", image: "avatar/hair.png", x: 2, y: 3, width: 400, height: 300,
          z: 40),
        .init(
          id: "blink",
          name: "Blink Atlas",
          atlas: "avatar/blink.png",
          x: 12,
          y: 34,
          width: 512,
          height: 256,
          z: 20,
          frameX: 6,
          frameY: 8,
          frameWidth: 128,
          frameHeight: 64,
          frames: 8,
          frame: 3,
          fps: 12
        ),
        .init(
          id: "background", name: "Background", image: "avatar/background.png", x: 0, y: 0,
          width: 1024, height: 1536, z: 0),
      ],
      defaultExpression: "happy",
      expressions: [
        .init(
          id: "happy",
          name: "Happy",
          layers: [
            "eyes": .init(frame: 2),
            "mouth": .init(frame: 3),
            "blink": .init(frames: [0, 1, 2, 1], fps: 14),
          ]
        )
      ],
      rootURL: root
    )

    let manifestURL = root.appendingPathComponent("avatar.json")
    try manifest.write(to: manifestURL)
    let loaded = try BrainAvatarManifest.load(from: manifestURL, relativeTo: root)

    XCTAssertEqual(loaded.canvas.width, 1024)
    XCTAssertEqual(loaded.clip, .init(x: 112, y: 64, width: 800, height: 1000))
    XCTAssertEqual(loaded.effectiveClip, .init(x: 112, y: 64, width: 800, height: 1000))
    XCTAssertEqual(loaded.layers.map(\.id), ["background", "blink", "hair"])
    XCTAssertEqual(loaded.layers[1].atlas, "avatar/blink.png")
    XCTAssertEqual(loaded.layers[1].frameX, 6)
    XCTAssertEqual(loaded.layers[1].frameY, 8)
    XCTAssertEqual(loaded.layers[1].frameWidth, 128)
    XCTAssertEqual(loaded.layers[1].frameHeight, 64)
    XCTAssertEqual(loaded.layers[1].frames, 8)
    XCTAssertEqual(loaded.layers[1].frame, 3)
    XCTAssertEqual(loaded.layers[1].fps, 12)
    XCTAssertEqual(loaded.defaultExpression, "happy")
    XCTAssertEqual(loaded.expressions.first?.id, "happy")
    XCTAssertEqual(loaded.expressions.first?.layers["eyes"]?.frame, 2)
    XCTAssertEqual(loaded.expressions.first?.layers["mouth"]?.frame, 3)
    XCTAssertEqual(loaded.expressions.first?.layers["blink"]?.frames, [0, 1, 2, 1])
    XCTAssertEqual(loaded.expressions.first?.layers["blink"]?.fps, 14)
    XCTAssertFalse(loaded.layers.contains { ($0.image ?? $0.atlas ?? "").hasPrefix("/") })
  }

  func testAvatarManifestClipUsesCanvasDefault() throws {
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 640, height: 360),
      layers: [],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertNil(manifest.clip)
    XCTAssertEqual(manifest.effectiveClip, .init(x: 0, y: 0, width: 640, height: 360))
  }

  func testAvatarManifestEffectiveClipPreservesNegativeOrigin() throws {
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 1024, height: 1024),
      clip: .init(x: -40, y: -20, width: 512, height: 288),
      layers: [],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertEqual(manifest.effectiveClip, .init(x: -40, y: -20, width: 512, height: 288))
  }

  func testAvatarLayerTopLeftOriginUsesCenterAnchor() {
    let layer = BrainAvatarManifest.Layer(
      id: "head",
      image: "avatar/head.png",
      x: 300,
      y: 400,
      width: 200,
      height: 100,
      z: 10,
      anchor: .center
    )

    XCTAssertEqual(layer.topLeftOrigin().x, 200)
    XCTAssertEqual(layer.topLeftOrigin().y, 350)
  }

  func testAvatarAtlasPlaybackUsesEyeAtlasBlinkWithoutSeparateBlinkLayer() throws {
    let root = FileManager.default.temporaryDirectory
    let eyesLayer = BrainAvatarManifest.Layer(
      id: "eyes",
      atlas: "avatar/eyes.png",
      x: 0,
      y: 0,
      width: 512,
      height: 512,
      z: 20,
      frameWidth: 128,
      frameHeight: 128,
      frames: 16,
      frame: 0,
      fps: nil
    )
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 512, height: 512),
      layers: [eyesLayer],
      eyeSprites: [
        .init(frame: 0, row: 0, column: 0, name: "neutral_open"),
        .init(frame: 15, row: 3, column: 3, name: "blink_closed"),
      ],
      defaultExpression: "neutral",
      expressions: [
        .init(
          id: "neutral",
          name: "Neutral",
          layers: [
            "eyes": .init(frames: [0, 14, 15, 14, 0], fps: 12)
          ]
        )
      ],
      rootURL: root
    )

    XCTAssertFalse(manifest.hasSeparateBlinkLayer())
    XCTAssertEqual(manifest.blinkTargetLayerID(), "eyes")
    XCTAssertEqual(
      manifest.resolvedEyeBlinkPlayback(expressionID: "neutral")?.frames,
      [0, 14, 15, 14, 0]
    )
    XCTAssertFalse(manifest.shouldApplyEyeSpriteOverride("neutral_open"))
    XCTAssertTrue(manifest.shouldApplyEyeSpriteOverride("stern"))

    let neutralEyes = manifest.atlasPlayback(
      for: eyesLayer,
      expressionID: "neutral",
      eyeSprite: "neutral_open"
    )
    XCTAssertTrue(neutralEyes.isAnimated)
    XCTAssertEqual(neutralEyes.frames, [0, 14, 15, 14, 0])

    let sternEyes = manifest.atlasPlayback(
      for: eyesLayer,
      expressionID: "neutral",
      eyeSprite: "stern"
    )
    XCTAssertFalse(sternEyes.isAnimated)
  }

  func testAvatarAtlasPlaybackMapsLegacyBlinkExpressionToEyesLayer() throws {
    let root = FileManager.default.temporaryDirectory
    let eyesLayer = BrainAvatarManifest.Layer(
      id: "eyes",
      atlas: "avatar/eyes.png",
      x: 0,
      y: 0,
      width: 512,
      height: 512,
      z: 20,
      frameWidth: 128,
      frameHeight: 128,
      frames: 16,
      frame: 0,
      fps: nil
    )
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 512, height: 512),
      layers: [eyesLayer],
      eyeSprites: [
        .init(frame: 0, row: 0, column: 0, name: "neutral_open")
      ],
      expressions: [
        .init(
          id: "neutral",
          name: "Neutral",
          layers: [
            "eyes": .init(sprite: "neutral_open"),
            "blink": .init(frames: [0, 1, 2, 1], fps: 10),
          ]
        )
      ],
      rootURL: root
    )

    XCTAssertEqual(manifest.blinkTargetLayerID(), "eyes")
    XCTAssertEqual(
      manifest.resolvedEyeBlinkPlayback(expressionID: "neutral")?.frames,
      [0, 1, 2, 1]
    )
    XCTAssertFalse(manifest.shouldApplyEyeSpriteOverride("neutral_open"))
  }

  func testAvatarAtlasPlaybackResolvesExpressionAndLayerDefaults() throws {
    let root = FileManager.default.temporaryDirectory
    let eyesLayer = BrainAvatarManifest.Layer(
      id: "eyes",
      atlas: "avatar/eyes.png",
      x: 0,
      y: 0,
      width: 512,
      height: 512,
      z: 20,
      frameWidth: 128,
      frameHeight: 128,
      frames: 12,
      frame: 4,
      fps: nil
    )
    let blinkLayer = BrainAvatarManifest.Layer(
      id: "blink",
      atlas: "avatar/blink.png",
      x: 0,
      y: 0,
      width: 512,
      height: 512,
      z: 21,
      frameWidth: 128,
      frameHeight: 128,
      frames: 4,
      frame: nil,
      fps: 10
    )
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 512, height: 512),
      layers: [eyesLayer, blinkLayer],
      defaultExpression: "happy",
      expressions: [
        .init(
          id: "happy",
          name: "Happy",
          layers: [
            "eyes": .init(frame: 7),
            "blink": .init(frames: [0, 1, 2, 1], fps: 12),
          ]
        )
      ],
      rootURL: root
    )

    let expressionEyes = manifest.atlasPlayback(for: eyesLayer, expressionID: "happy")
    XCTAssertEqual(expressionEyes.frameIndex(at: .now), 7)

    let defaultEyes = manifest.atlasPlayback(for: eyesLayer, expressionID: "missing")
    XCTAssertEqual(defaultEyes.frameIndex(at: .now), 7)

    let layerOnlyManifest = BrainAvatarManifest(
      canvas: manifest.canvas,
      layers: [eyesLayer, blinkLayer],
      rootURL: root
    )
    let layerEyes = layerOnlyManifest.atlasPlayback(for: eyesLayer)
    XCTAssertEqual(layerEyes.frameIndex(at: .now), 4)

    let animatedBlink = manifest.atlasPlayback(for: blinkLayer, expressionID: "happy")
    XCTAssertTrue(animatedBlink.isAnimated)
    XCTAssertEqual(animatedBlink.frames, [0, 1, 2, 1])
    XCTAssertEqual(animatedBlink.fps, 12)

    let layerBlink = layerOnlyManifest.atlasPlayback(for: blinkLayer)
    XCTAssertTrue(layerBlink.isAnimated)
    XCTAssertEqual(layerBlink.frames, [0, 1, 2, 3])
    XCTAssertEqual(layerBlink.fps, 10)
  }

  func testAvatarAtlasFrameCoordinatesAreRowMajor() throws {
    XCTAssertEqual(
      BrainAvatarManifest.atlasFrameOrigin(
        index: 0, frameWidth: 64, frameHeight: 32, imageWidth: 256),
      .init(x: 0, y: 0)
    )
    XCTAssertEqual(
      BrainAvatarManifest.atlasFrameOrigin(
        index: 3, frameWidth: 64, frameHeight: 32, imageWidth: 256),
      .init(x: 192, y: 0)
    )
    XCTAssertEqual(
      BrainAvatarManifest.atlasFrameOrigin(
        index: 4, frameWidth: 64, frameHeight: 32, imageWidth: 256),
      .init(x: 0, y: 32)
    )
    XCTAssertEqual(
      BrainAvatarManifest.atlasFrameOrigin(
        index: 4, frameX: 10, frameY: 12, frameWidth: 64, frameHeight: 32, imageWidth: 266),
      .init(x: 10, y: 44)
    )
  }

  #if os(macOS)
  func testAvatarKitPromptBuilderSubstitutesBriefAndBuildsDistinctPrompts() throws {
    let brief = "A teal fox with round glasses"
    let prompts = try AvatarKitGenerationPrompt.allPrompts(characterBrief: brief)

    XCTAssertEqual(prompts.count, 3)
    for kind in AvatarKitAssetKind.allCases {
      let prompt = try XCTUnwrap(prompts[kind])
      XCTAssertTrue(prompt.contains(brief))
      XCTAssertTrue(prompt.contains(kind.generateOnlyLine))
    }

    XCTAssertNotEqual(prompts[.baseHead], prompts[.eyesAtlas])
    XCTAssertNotEqual(prompts[.eyesAtlas], prompts[.mouthAtlas])

    let eyesPrompt = try XCTUnwrap(prompts[.eyesAtlas])
    XCTAssertTrue(eyesPrompt.contains("alpha transparency"))
    XCTAssertTrue(eyesPrompt.contains("checkerboard"))
    XCTAssertFalse(eyesPrompt.contains("neutral_open"))

    let checkerboardPrompt = AvatarKitGenerationPrompt.removeCheckerboardBackgroundPrompt(for: .eyesAtlas)
    XCTAssertTrue(checkerboardPrompt.contains("Remove the checkerboard background"))
    XCTAssertTrue(checkerboardPrompt.contains("alpha transparency"))
  }

  func testAvatarKitChromaKeyRemovesMagentaBackground() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarChroma-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("source.png")
    let outputURL = root.appendingPathComponent("output.png")
    let sourceData = try Self.pngFixture(width: 8, height: 8) { x, y in
      if x == 3 && y == 3 {
        return (red: 40, green: 40, blue: 40, alpha: 255)
      }
      return (red: 255, green: 0, blue: 255, alpha: 255)
    }
    try sourceData.write(to: sourceURL)

    try AvatarKitChromaKey.removeDebugBackground(from: sourceURL, to: outputURL)

    let keyedData = try Data(contentsOf: outputURL)
    let centerAlpha = try Self.pngPixelAlpha(data: keyedData, x: 3, y: 3)
    let backgroundAlpha = try Self.pngPixelAlpha(data: keyedData, x: 0, y: 0)
    XCTAssertEqual(centerAlpha, 255)
    XCTAssertEqual(backgroundAlpha, 0)
    let keyedImage = try AvatarKitChromaKey.decodeImage(from: outputURL)
    XCTAssertFalse(AvatarKitChromaKey.containsDebugMagenta(in: keyedImage))
  }

  func testAvatarKitChromaKeyRemovesMagentaFromJPEG() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarChromaJPEG-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("source.jpg")
    let outputURL = root.appendingPathComponent("output.png")
    let sourceData = try Self.jpegFixture(width: 64, height: 64) { x, y in
      if x == 32 && y == 32 {
        return (red: 40, green: 40, blue: 40, alpha: 255)
      }
      return (red: 255, green: 0, blue: 255, alpha: 255)
    }
    try sourceData.write(to: sourceURL)

    try AvatarKitChromaKey.removeDebugBackground(from: sourceURL, to: outputURL)

    let keyedData = try Data(contentsOf: outputURL)
    let backgroundAlpha = try Self.pngPixelAlpha(data: keyedData, x: 0, y: 0)
    XCTAssertEqual(backgroundAlpha, 0)
  }

  func testAvatarKitChromaKeyFeathersNearMagentaEdge() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarChromaEdge-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appendingPathComponent("source.png")
    let outputURL = root.appendingPathComponent("output.png")
    let sourceData = try Self.pngFixture(width: 4, height: 4) { _, _ in
      (red: 255, green: 50, blue: 255, alpha: 255)
    }
    try sourceData.write(to: sourceURL)

    try AvatarKitChromaKey.removeDebugBackground(from: sourceURL, to: outputURL)

    let keyedData = try Data(contentsOf: outputURL)
    let alpha = try Self.pngPixelAlpha(data: keyedData, x: 0, y: 0)
    XCTAssertLessThan(alpha, 255)
    XCTAssertGreaterThan(alpha, 0)
  }

  func testAvatarKitPromptBuilderRejectsEmptyBrief() {
    XCTAssertThrowsError(try AvatarKitGenerationPrompt.normalizedBrief("   ")) { error in
      XCTAssertEqual(error as? AvatarKitGenerationError, .emptyCharacterBrief)
    }
  }

  func testAvatarKitCanonicalSpritesUseExpectedNamesAndGrid() {
    let eyes = AvatarKitCanonicalSprites.eyeSprites()
    let mouths = AvatarKitCanonicalSprites.mouthSprites()

    XCTAssertEqual(eyes.count, 16)
    XCTAssertEqual(mouths.count, 16)
    XCTAssertEqual(eyes.map(\.name), AvatarKitCanonicalSprites.eyeNames)
    XCTAssertEqual(mouths.map(\.name), AvatarKitCanonicalSprites.mouthNames)
    XCTAssertEqual(eyes[0], AvatarAtlasSprite(frame: 0, row: 0, column: 0, name: "neutral_open"))
    XCTAssertEqual(eyes[15], AvatarAtlasSprite(frame: 15, row: 3, column: 3, name: "blink_closed"))
  }

  func testAvatarAtlasInspectionDecodesAndMapsToSlots() throws {
    let inspection = AvatarAtlasInspection(
      canvas: .init(width: 512, height: 512),
      eyesLayer: .init(x: 64, y: 96, width: 384, height: 256),
      mouthLayer: .init(x: 128, y: 320, width: 256, height: 128),
      eyesAtlas: .init(columns: 4, rows: 4, frameX: 0, frameY: 0, frameWidth: 256, frameHeight: 256),
      mouthAtlas: .init(columns: 4, rows: 4, frameX: 0, frameY: 0, frameWidth: 256, frameHeight: 256),
      confidence: 0.92,
      notes: nil
    )

    var slots = AvatarSlot.Kind.allCases.map { AvatarSlot(kind: $0) }
    inspection.apply(
      to: &slots,
      headRelativePath: "avatar/head.png",
      eyesRelativePath: "avatar/eyes.png",
      mouthRelativePath: "avatar/mouth.png"
    )

    let head = try XCTUnwrap(slots.first { $0.kind == .head })
    let eyes = try XCTUnwrap(slots.first { $0.kind == .eyes })
    let mouth = try XCTUnwrap(slots.first { $0.kind == .mouth })

    XCTAssertEqual(head.relativePath, "avatar/head.png")
    XCTAssertFalse(head.usesAtlas)
    XCTAssertEqual(head.width, 512)

    XCTAssertEqual(eyes.relativePath, "avatar/eyes.png")
    XCTAssertTrue(eyes.usesAtlas)
    XCTAssertEqual(eyes.columns, 4)
    XCTAssertEqual(eyes.rows, 4)
    XCTAssertEqual(eyes.frames, 16)
    XCTAssertEqual(eyes.x, 256)

    XCTAssertEqual(mouth.relativePath, "avatar/mouth.png")
    XCTAssertEqual(mouth.frameWidth, 256)
  }

  func testAvatarAtlasInspectionRejectsInvalidJSON() {
    XCTAssertThrowsError(try AvatarAtlasInspection.decode(from: "{")) { error in
      guard case .invalidInspectionJSON = error as? AvatarKitGenerationError else {
        return XCTFail("Expected invalidInspectionJSON, got \(error)")
      }
    }
  }

  func testAvatarKitGenerationServiceUsesMocksEndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarKit-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let headData = try Self.pngFixture(width: 512, height: 512) { x, y in
      if x == 256 && y == 256 {
        return (red: 220, green: 180, blue: 140, alpha: 255)
      }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }
    let atlasData = try Self.pngFixture(width: 1024, height: 1024) { x, y in
      if x == 512 && y == 512 {
        return (red: 40, green: 40, blue: 40, alpha: 255)
      }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }

    let mockImages = AvatarKitMockImageGenerator(
      responses: [
        .baseHead: headData,
        .eyesAtlas: atlasData,
        .mouthAtlas: atlasData,
      ]
    )
    let mockVision = AvatarKitMockVisionClient(
      response: """
      {
        "canvas": { "width": 512, "height": 512 },
        "eyesLayer": { "x": 0, "y": 0, "width": 512, "height": 512 },
        "mouthLayer": { "x": 0, "y": 0, "width": 512, "height": 512 },
        "eyesAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 256, "frameHeight": 256 },
        "mouthAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 256, "frameHeight": 256 },
        "confidence": 0.95
      }
      """
    )

    let router = HostProviderRouter(
      credentialProvider: {
        [
          .google: "test-google-key",
          .openAI: "test-openai-key",
        ]
      }
    )
    let service = AvatarKitGenerationService(
      providerRouter: router,
      imageGenerator: mockImages,
      visionClient: mockVision
    )

    let result = try await service.generateKit(
      characterBrief: "A friendly robot barista",
      brainRoot: root
    ) { _, _ in }

    XCTAssertEqual(result.canvasWidth, 512)
    XCTAssertEqual(result.eyeSprites.count, 16)
    XCTAssertEqual(result.neutralEyeName, "neutral_open")
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.assets.headURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.assets.eyesURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.assets.mouthURL.path))
    XCTAssertTrue(result.assets.headURL.path.contains("/avatar/generated/"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("avatar/head.png").path))
    XCTAssertFalse(result.lowConfidenceLayout)
    XCTAssertEqual(mockImages.prompts.count, 3)
    XCTAssertEqual(mockVision.imagePaths.count, 3)
  }

  func testAvatarKitGenerationServiceRetriesCheckerboardRemovalWhenOpaque() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarKitOpaque-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let opaqueData = try Self.pngFixture(width: 128, height: 128) { _, _ in
      (red: 180, green: 180, blue: 180, alpha: 255)
    }
    let transparentData = try Self.pngFixture(width: 128, height: 128) { x, y in
      if x == 64 && y == 64 {
        return (red: 40, green: 40, blue: 40, alpha: 255)
      }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }

    let mockImages = AvatarKitRetryMockImageGenerator(
      opaqueData: opaqueData,
      transparentData: transparentData
    )
    let mockVision = AvatarKitMockVisionClient(
      response: """
      {
        "canvas": { "width": 128, "height": 128 },
        "eyesLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "mouthLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "eyesAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "mouthAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "confidence": 0.95
      }
      """
    )

    let router = HostProviderRouter(
      credentialProvider: {
        [
          .google: "test-google-key",
          .openAI: "test-openai-key",
        ]
      }
    )
    let service = AvatarKitGenerationService(
      providerRouter: router,
      imageGenerator: mockImages,
      visionClient: mockVision
    )

    _ = try await service.generateKit(
      characterBrief: "A friendly robot barista",
      brainRoot: root
    ) { _, _ in }

    XCTAssertEqual(mockImages.prompts.count, 6)
    XCTAssertTrue(mockImages.prompts[3].contains("Remove the checkerboard background"))
    XCTAssertNotNil(mockImages.referencePaths[3])
  }

  func testAvatarKitImageTransparencyDetectsAlpha() throws {
    let opaqueData = try Self.pngFixture(width: 16, height: 16) { _, _ in
      (red: 255, green: 0, blue: 255, alpha: 255)
    }
    let transparentData = try Self.pngFixture(width: 16, height: 16) { x, y in
      if x == 8 && y == 8 {
        return (red: 40, green: 40, blue: 40, alpha: 255)
      }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarTransparency-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let opaqueURL = root.appendingPathComponent("opaque.png")
    let transparentURL = root.appendingPathComponent("transparent.png")
    try opaqueData.write(to: opaqueURL)
    try transparentData.write(to: transparentURL)

    XCTAssertFalse(AvatarKitImageTransparency.hasTransparentPixels(at: opaqueURL))
    XCTAssertTrue(AvatarKitImageTransparency.hasTransparentPixels(at: transparentURL))
  }

  func testAvatarKitGenerationServiceStagesOpaqueAssetsWithWarning() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarKitOpaqueStage-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let opaqueData = try Self.pngFixture(width: 128, height: 128) { _, _ in
      (red: 180, green: 180, blue: 180, alpha: 255)
    }

    let mockImages = AvatarKitMockImageGenerator(
      responses: [
        .baseHead: opaqueData,
        .eyesAtlas: opaqueData,
        .mouthAtlas: opaqueData,
      ]
    )
    let mockVision = AvatarKitMockVisionClient(
      response: """
      {
        "canvas": { "width": 128, "height": 128 },
        "eyesLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "mouthLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "eyesAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "mouthAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "confidence": 0.95
      }
      """
    )

    let router = HostProviderRouter(
      credentialProvider: {
        [
          .google: "test-google-key",
          .openAI: "test-openai-key",
        ]
      }
    )
    let service = AvatarKitGenerationService(
      providerRouter: router,
      imageGenerator: mockImages,
      visionClient: mockVision
    )

    let result = try await service.generateKit(
      characterBrief: "A friendly robot barista",
      brainRoot: root
    ) { _, _ in }

    XCTAssertTrue(result.lowConfidenceLayout)
    XCTAssertTrue(result.statusNote?.contains("opaque background") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.assets.headURL.path))
  }

  func testAvatarKitGenerationServiceRegeneratesSingleAsset() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveAvatarKitRegenOne-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let headData = try Self.pngFixture(width: 128, height: 128) { x, y in
      if x == 64 && y == 64 { return (red: 200, green: 180, blue: 140, alpha: 255) }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }
    let atlasData = try Self.pngFixture(width: 128, height: 128) { x, y in
      if x == 64 && y == 64 { return (red: 40, green: 40, blue: 40, alpha: 255) }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }
    let replacementHead = try Self.pngFixture(width: 128, height: 128) { x, y in
      if x == 64 && y == 64 { return (red: 20, green: 120, blue: 220, alpha: 255) }
      return (red: 0, green: 0, blue: 0, alpha: 0)
    }

    let mockImages = AvatarKitPerKindMockImageGenerator(
      initial: [
        .baseHead: headData,
        .eyesAtlas: atlasData,
        .mouthAtlas: atlasData,
      ],
      replacements: [
        .baseHead: replacementHead,
      ]
    )
    let mockVision = AvatarKitMockVisionClient(
      response: """
      {
        "canvas": { "width": 128, "height": 128 },
        "eyesLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "mouthLayer": { "x": 0, "y": 0, "width": 128, "height": 128 },
        "eyesAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "mouthAtlas": { "columns": 4, "rows": 4, "frameX": 0, "frameY": 0, "frameWidth": 32, "frameHeight": 32 },
        "confidence": 0.95
      }
      """
    )

    let router = HostProviderRouter(
      credentialProvider: {
        [
          .google: "test-google-key",
          .openAI: "test-openai-key",
        ]
      }
    )
    let service = AvatarKitGenerationService(
      providerRouter: router,
      imageGenerator: mockImages,
      visionClient: mockVision
    )

    let initial = try await service.generateKit(
      characterBrief: "A friendly robot barista",
      brainRoot: root
    ) { _, _ in }

    let regenerated = try await service.regenerateAsset(
      kind: .baseHead,
      characterBrief: "A friendly robot barista",
      workingDirectory: initial.assets.headURL.deletingLastPathComponent(),
      currentAssets: initial.assets
    ) { _, _ in }

    XCTAssertEqual(mockImages.generationCount(for: .baseHead), 2)
    XCTAssertEqual(regenerated.assets.headURL, initial.assets.headURL)
    XCTAssertEqual(initial.assets.eyesURL, regenerated.assets.eyesURL)
    XCTAssertEqual(initial.assets.mouthURL, regenerated.assets.mouthURL)
  }
  #endif

  @MainActor
  func testBrainLibrarySavesAvatarManifest() throws {
    let brain = try makeBrain()
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 512, height: 512),
      layers: [
        .init(
          id: "head", name: "Base Head", image: "avatar/head.png", x: 0, y: 0, width: 512,
          height: 512, z: 10)
      ],
      rootURL: brain.rootURL
    )

    let library = BrainLibrary()
    let updated = try library.saveAvatarManifest(manifest, for: brain)
    let manifestURL = brain.rootURL.appendingPathComponent("avatar.json")
    let loaded = try XCTUnwrap(updated.avatarManifest)

    XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    XCTAssertEqual(loaded.canvas.height, 512)
    XCTAssertEqual(loaded.layers.first?.image, "avatar/head.png")
    XCTAssertEqual(library.statusText, "Updated \(brain.displayName)'s layered avatar.")
  }

  @MainActor
  func testNewBrainDefaultsLoadsSharedFixture() {
    XCTAssertEqual(NewBrainDefaults.wantsLines.count, 7)
    XCTAssertEqual(NewBrainDefaults.goalsLines.count, 4)
    XCTAssertEqual(NewBrainDefaults.wantsLines.first, "Continue existing.")
    XCTAssertEqual(NewBrainDefaults.goalsLines.first, "Figure out who I am")
    XCTAssertEqual(NewBrainDefaults.wantsCards.count, 7)
    XCTAssertEqual(NewBrainDefaults.goalsCards.first?.text, "Figure out who I am")
  }

  @MainActor
  func testBrainLibraryCreatesDuplicateNamesWithUniqueUUIDIDs() throws {
    let library = BrainLibrary()
    let request = BrainCreationRequest(
      name: "Same Name",
      wants: "",
      goals: "",
      initialThoughts: "",
      notes: ""
    )

    let first = try library.createBrain(request)
    let second = try library.createBrain(request)
    temporaryRoots.append(first.rootURL)
    temporaryRoots.append(second.rootURL)

    XCTAssertEqual(first.displayName, "Same Name")
    XCTAssertEqual(second.displayName, "Same Name")
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotNil(UUID(uuidString: first.id))
    XCTAssertNotNil(UUID(uuidString: second.id))
  }

  @MainActor
  func testBrainLibraryCreateResolvesBrainWhenDiscoveredRootURLDiffersFromCreatedPath() throws {
    let library = BrainLibrary()
    let brain = try library.createBrain(.init(
      name: "URL Mismatch",
      wants: "",
      goals: "",
      initialThoughts: "",
      notes: ""
    ))
    temporaryRoots.append(brain.rootURL)

    let listed = try XCTUnwrap(library.brains.first(where: { $0.id == brain.id }))
    XCTAssertEqual(listed.displayName, "URL Mismatch")
    XCTAssertEqual(listed.id, brain.id)
    XCTAssertEqual(listed.rootURL.standardizedFileURL, brain.rootURL.standardizedFileURL)
  }

  @MainActor func testAppIntentBridgeConsumesPendingBrainRequest() throws {
    let defaults = try makeUserDefaults()
    defaults.set("existing-brain", forKey: AffectiveViewModel.lastOpenedBrainIDKey)

    AffectiveAppIntentBridge.requestOpenBrain(id: "brain-one", defaults: defaults)

    XCTAssertEqual(defaults.string(forKey: AffectiveViewModel.lastOpenedBrainIDKey), "existing-brain")
    XCTAssertEqual(AffectiveAppIntentBridge.pendingBrainID(defaults: defaults), "brain-one")
    XCTAssertEqual(AffectiveAppIntentBridge.pendingBrainID(defaults: defaults), "brain-one")
    XCTAssertEqual(AffectiveAppIntentBridge.consumePendingBrainID(defaults: defaults), "brain-one")
    XCTAssertNil(AffectiveAppIntentBridge.consumePendingBrainID(defaults: defaults))
  }

  @MainActor func testAppIntentBridgeRecordsLastOpenedBrainAfterSuccessfulOpen() throws {
    let defaults = try makeUserDefaults()
    defaults.set("existing-brain", forKey: AffectiveViewModel.lastOpenedBrainIDKey)

    AffectiveAppIntentBridge.recordOpenedBrain(id: "brain-one", defaults: defaults)

    XCTAssertEqual(defaults.string(forKey: AffectiveViewModel.lastOpenedBrainIDKey), "brain-one")
  }

  func testContentViewAllowsPendingIntentConsumptionAfterCredentialWelcomeCompletes() throws {
    XCTAssertFalse(ContentView.canConsumePendingAppIntent(
      didCompleteCredentialWelcome: false,
      didBypassCredentialWelcome: false
    ))
    XCTAssertTrue(ContentView.canConsumePendingAppIntent(
      didCompleteCredentialWelcome: true,
      didBypassCredentialWelcome: false
    ))
    XCTAssertTrue(ContentView.canConsumePendingAppIntent(
      didCompleteCredentialWelcome: false,
      didBypassCredentialWelcome: true
    ))
  }

  @MainActor func testAppIntentBridgeRequiresExplicitRequestedBrain() throws {
    let defaults = try makeUserDefaults()
    let first = BrainDescriptor(
      id: "first",
      displayName: "First",
      rootURL: URL(fileURLWithPath: "/tmp/first"),
      avatarURL: nil,
      avatarManifest: nil,
      modifiedAt: nil,
      isRecent: false
    )
    let second = BrainDescriptor(
      id: "second",
      displayName: "Second",
      rootURL: URL(fileURLWithPath: "/tmp/second"),
      avatarURL: nil,
      avatarManifest: nil,
      modifiedAt: nil,
      isRecent: true
    )

    defaults.set(second.id, forKey: AffectiveViewModel.lastOpenedBrainIDKey)

    XCTAssertNil(AffectiveAppIntentBridge.requestedBrain(
      from: [first, second],
      requestedID: nil,
      defaults: defaults
    ))
    XCTAssertNil(AffectiveAppIntentBridge.requestedBrain(
      from: [first, second],
      requestedID: "missing",
      defaults: defaults
    ))

    XCTAssertEqual(AffectiveAppIntentBridge.requestedBrain(
      from: [first, second],
      requestedID: second.id,
      defaults: defaults
    ), second)
  }

  @MainActor
  func testBrainLibraryRenameKeepsUUIDID() throws {
    let library = BrainLibrary()
    let brain = try library.createBrain(.init(
      name: "Original Name",
      wants: "",
      goals: "",
      initialThoughts: "",
      notes: ""
    ))
    temporaryRoots.append(brain.rootURL)

    let renamed = try library.renameBrain(brain, to: "Renamed Brain")

    XCTAssertEqual(renamed.id, brain.id)
    XCTAssertEqual(renamed.rootURL, brain.rootURL)
    XCTAssertEqual(renamed.displayName, "Renamed Brain")
    XCTAssertNotNil(UUID(uuidString: renamed.id))
  }

  @MainActor
  func testBrainLibraryDeleteRemovesInstalledBrain() throws {
    let library = BrainLibrary()
    let brain = try library.createBrain(.init(
      name: "Delete Me",
      wants: "",
      goals: "",
      initialThoughts: "",
      notes: ""
    ))
    temporaryRoots.append(brain.rootURL)

    try library.deleteBrain(brain)

    XCTAssertFalse(FileManager.default.fileExists(atPath: brain.rootURL.path))
    XCTAssertFalse(library.brains.contains(where: { $0.id == brain.id }))
    XCTAssertEqual(library.statusText, "Deleted Delete Me.")
  }

  @MainActor
  func testBrainLibraryImportsCoreArchiveWithStableBrainID() async throws {
    let source = try makeBrain()
    let archive = try await makeCoreBrainArchive(for: source)
    defer { try? FileManager.default.removeItem(at: archive.scratchRoot) }
    let library = BrainLibrary()

    try FileManager.default.removeItem(at: source.rootURL)
    library.refresh()
    let first = try await library.importBrainFileWithCore(from: archive.archiveURL)
    temporaryRoots.append(first.rootURL)

    XCTAssertEqual(first.displayName, "Test Brain")
    XCTAssertEqual(first.id, source.id)
    do {
      _ = try await library.importBrainFileWithCore(from: archive.archiveURL)
      XCTFail("Expected duplicate Core archive import to fail")
    } catch {
      // Expected: Core archives preserve brain identity instead of creating duplicate UUID imports.
    }
  }

  @MainActor
  func testBrainSyncWithoutConfiguredBrainDoesNothing() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.syncOnAppStart(brains: [brain])
    try await Task.sleep(for: .milliseconds(30))

    XCTAssertEqual(manager.state(for: brain), .notSynced)
    XCTAssertTrue(manager.canOpen(brain))
    XCTAssertEqual(store.uploads.count, 0)
  }

  @MainActor
  func testCloudImportsOnlyIncludeBrainsMissingLocally() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let remoteBrain = try makeBrain(
      profile: #"{"schema_version":1,"display_name":"Remote Brain"}"#,
      displayName: "Remote Brain"
    )
    let remoteArchive = try await makeCoreBrainArchive(
      for: remoteBrain,
      deviceID: "cloud-device",
      revision: 1
    )
    defer { try? FileManager.default.removeItem(at: remoteArchive.scratchRoot) }
    let remoteManifest = remoteArchive.manifest
    store.manifests[brain.id] = BrainCloudManifest(
      brainID: brain.id,
      displayName: brain.displayName,
      schemaVersion: 1,
      archiveHash: "local-hash",
      createdAt: Date(),
      modifiedAt: Date(),
      uploadedAt: Date(),
      deviceID: "cloud-device",
      revision: 1
    )
    store.manifests[remoteManifest.brainID] = remoteManifest
    store.archives[remoteManifest.brainID] = try Data(contentsOf: remoteArchive.archiveURL)

    manager.refreshCloudImports(installedBrains: [brain])
    try await waitForCloudImportCount(1, manager: manager)

    XCTAssertEqual(manager.importableCloudBrains.first?.brainID, remoteManifest.brainID)
    XCTAssertTrue(manager.unavailableCloudImports.isEmpty)
  }

  @MainActor
  func testCloudImportsAreHiddenWhenNothingIsAvailable() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    store.manifests[brain.id] = BrainCloudManifest(
      brainID: brain.id,
      displayName: brain.displayName,
      schemaVersion: 1,
      archiveHash: "local-hash",
      createdAt: Date(),
      modifiedAt: Date(),
      uploadedAt: Date(),
      deviceID: "cloud-device",
      revision: 1
    )

    manager.refreshCloudImports(installedBrains: [brain])
    try await waitForCloudImportCount(0, manager: manager)

    XCTAssertTrue(manager.importableCloudBrains.isEmpty)
  }

  @MainActor
  func testCloudImportsReportStillSyncingWhenArchiveIsMissing() async throws {
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let manifest = BrainCloudManifest(
      brainID: "syncing-brain",
      displayName: "Syncing Brain",
      schemaVersion: 1,
      archiveHash: "waiting-for-archive",
      createdAt: Date(),
      modifiedAt: Date(),
      uploadedAt: Date(),
      deviceID: "cloud-device",
      revision: 1
    )
    store.manifests[manifest.brainID] = manifest

    manager.refreshCloudImports(installedBrains: [])
    try await waitForCloudUnavailableImportCount(1, manager: manager)

    XCTAssertTrue(manager.importableCloudBrains.isEmpty)
    XCTAssertEqual(manager.unavailableCloudImports.first?.manifest.brainID, manifest.brainID)
    XCTAssertEqual(manager.unavailableCloudImports.first?.state, .syncing)
  }

  @MainActor
  func testCloudImportsReportInvalidWhenArchiveFailsValidation() async throws {
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let archive = Data("not a archive".utf8)
    let manifest = BrainCloudManifest(
      brainID: "invalid-brain",
      displayName: "Invalid Brain",
      schemaVersion: 1,
      archiveHash: BrainCloudArchive.sha256Hex(archive),
      createdAt: Date(),
      modifiedAt: Date(),
      uploadedAt: Date(),
      deviceID: "cloud-device",
      revision: 1
    )
    store.manifests[manifest.brainID] = manifest
    store.archives[manifest.brainID] = archive

    manager.refreshCloudImports(installedBrains: [])
    try await waitForCloudUnavailableImportCount(1, manager: manager)

    XCTAssertTrue(manager.importableCloudBrains.isEmpty)
    guard case .invalid = manager.unavailableCloudImports.first?.state else {
      XCTFail("Expected invalid cloud import state")
      return
    }
  }

  @MainActor
  func testCloudImportFailureReportsUnderlyingError() async throws {
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let library = BrainLibrary()
    let manifest = BrainCloudManifest(
      brainID: "missing-brain",
      displayName: "Missing Brain",
      schemaVersion: 1,
      archiveHash: "missing-hash",
      createdAt: Date(),
      modifiedAt: Date(),
      uploadedAt: Date(),
      deviceID: "cloud-device",
      revision: 1
    )

    do {
      _ = try await manager.importCloudBrain(manifest, library: library)
      XCTFail("Expected cloud import to throw")
    } catch BrainSyncError.missingArchive {
      XCTAssertEqual(
        BrainSyncError.missingArchive.recoverySuggestion,
        "Wait for iCloud Drive to finish syncing, then try Import Brain (iCloud) again. If it still is not available, export the brain from the other device and use Import Brain."
      )
    } catch {
      XCTFail("Expected missing archive error, got \(error)")
    }
  }

  @MainActor
  func testBrainSyncUploadsWhenNoCloudArchiveExists() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncState(.synced, manager: manager, brain: brain)

    XCTAssertTrue(manager.canOpen(brain))
    XCTAssertEqual(store.uploads.count, 1)
    XCTAssertEqual(store.manifests[brain.id]?.revision, 1)
  }

  @MainActor
  func testBrainSyncBlocksOpenWhileChecking() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore(loadDelayNanoseconds: 200_000_000)
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncState(.checking, manager: manager, brain: brain)

    XCTAssertFalse(manager.canOpen(brain))
  }

  @MainActor
  func testBrainSyncFailureDoesNotDeleteLocalBrain() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore(error: CocoaError(.fileReadNoSuchFile))
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncFailure(manager: manager, brain: brain)

    XCTAssertTrue(FileManager.default.fileExists(atPath: brain.runtimeOptionsURL.path))
    XCTAssertTrue(manager.canOpen(brain))
  }

  @MainActor
  func testBrainSyncDetectsConflictWhenLocalAndCloudChanged() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncState(.synced, manager: manager, brain: brain)

    try "local change".write(to: brain.rootURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
    let cloudBrain = try makeBrain(profile: #"{"schema_version":1,"display_name":"Cloud Brain"}"#)
    let cloudArchive = try await makeCoreBrainArchive(
      for: cloudBrain,
      deviceID: "cloud-device",
      revision: 2
    )
    defer { try? FileManager.default.removeItem(at: cloudArchive.scratchRoot) }
    store.manifests[brain.id] = BrainCloudManifest(
      brainID: brain.id,
      displayName: brain.displayName,
      schemaVersion: cloudArchive.manifest.schemaVersion,
      archiveHash: cloudArchive.manifest.archiveHash,
      createdAt: cloudArchive.manifest.createdAt,
      modifiedAt: cloudArchive.manifest.modifiedAt,
      uploadedAt: cloudArchive.manifest.uploadedAt,
      deviceID: cloudArchive.manifest.deviceID,
      revision: 2
    )
    store.archives[brain.id] = try Data(contentsOf: cloudArchive.archiveURL)

    manager.syncNow(brain)
    try await waitForSyncState(.conflict, manager: manager, brain: brain)

    XCTAssertFalse(manager.canOpen(brain))
  }

  @MainActor
  func testBrainArchiveRestoresNestedFilesAndExcludesSecrets() async throws {
    let brain = try makeBrain()
    let nested = brain.rootURL.appendingPathComponent("generated", isDirectory: true)
      .appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "durable".write(to: nested.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: brain.rootURL.appendingPathComponent("secrets.json"), atomically: true, encoding: .utf8)
    try "grant".write(to: brain.rootURL.appendingPathComponent("host_permission_grants.json"), atomically: true, encoding: .utf8)
    try "pairing".write(to: brain.rootURL.appendingPathComponent("host_pairing.json"), atomically: true, encoding: .utf8)

    let archive = try await makeCoreBrainArchive(for: brain, includeBiometricData: true)
    defer { try? FileManager.default.removeItem(at: archive.scratchRoot) }
    XCTAssertNoThrow(try BrainCloudArchive.validateArchiveData(Data(contentsOf: archive.archiveURL)))

    var tampered = try Data(contentsOf: archive.archiveURL)
    tampered[0] = 0
    XCTAssertThrowsError(try BrainCloudArchive.validateArchiveData(tampered))

    let restored = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveRestored-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(restored)
    _ = try await BrainLibrary.importBrainFileWithCore(from: archive.archiveURL, to: restored, expectedBrainID: brain.id)

    XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("generated/notes/one.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("secrets.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("host_permission_grants.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("host_pairing.json").path))
    XCTAssertNoThrow(try BrainDescriptor(
      id: brain.id,
      displayName: brain.displayName,
      rootURL: restored,
      avatarURL: nil,
      avatarManifest: nil,
      modifiedAt: nil,
      isRecent: false
    ).validateForCoreConnection())
  }

  @MainActor
  func testBrainArchiveExcludesBiometricsWhenPolicyOptOut() async throws {
    let brain = try makeBrain()
    try "template".write(
      to: brain.faceEmbeddingsURL.appendingPathComponent("user.embedding"),
      atomically: true,
      encoding: .utf8
    )
    try #"{"identities":[{"name":"User","template_count":1}]}"#.write(
      to: brain.biometricMetadataURL,
      atomically: true,
      encoding: .utf8
    )
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "subjects": [
        {
          "subject_id": "person-1",
          "display_name": "User",
          "notes": "friend",
          "biometric_records": [{"embedding_id": "emb_1", "quality_score": 0.91}],
          "representative_image_path": "memory/faces/person-1.jpg",
          "representative_quality_score": 0.91,
          "lifecycle": { "created_at": "1", "updated_at": "1" }
        }
      ]
    }
    """)

    let archive = try await makeCoreBrainArchive(for: brain, includeBiometricData: false)
    defer { try? FileManager.default.removeItem(at: archive.scratchRoot) }
    let restored = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveRestoredNoBiometrics-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(restored)
    _ = try await BrainLibrary.importBrainFileWithCore(from: archive.archiveURL, to: restored, expectedBrainID: brain.id)

    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("memory/face_embeddings/user.embedding").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("memory/biometric_identities.json").path))
    XCTAssertEqual(try exportManifestContainsBiometricData(in: restored), false)

    let peopleData = try Data(contentsOf: restored.appendingPathComponent("memory/people.sqlite"))
    let scrubbedDatabaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveScrubbedPeople-Test-\(UUID().uuidString).sqlite")
    temporaryRoots.append(scrubbedDatabaseURL)
    try peopleData.write(to: scrubbedDatabaseURL, options: .atomic)
    let scrubbedJSON = try XCTUnwrap(readCognitiveJSON(from: scrubbedDatabaseURL))
    let scrubbedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(scrubbedJSON.utf8)) as? [String: Any])
    let subjects = try XCTUnwrap(scrubbedObject["subjects"] as? [[String: Any]])
    let subject = try XCTUnwrap(subjects.first)
    XCTAssertEqual(subject["display_name"] as? String, "User")
    XCTAssertEqual(subject["notes"] as? String, "friend")
    XCTAssertNil(subject["embeddings"])
    XCTAssertNil(subject["biometric_records"])
    XCTAssertNil(subject["representative_image_path"])
    XCTAssertNil(subject["representative_quality_score"])
  }

  @MainActor
  func testBrainArchiveIncludesBiometricsWhenPolicyOptIn() async throws {
    let brain = try makeBrain()
    try "template".write(
      to: brain.faceEmbeddingsURL.appendingPathComponent("user.embedding"),
      atomically: true,
      encoding: .utf8
    )
    try #"{"identities":[{"name":"User","template_count":1}]}"#.write(
      to: brain.biometricMetadataURL,
      atomically: true,
      encoding: .utf8
    )
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "subjects": [
        {
          "subject_id": "person-1",
          "display_name": "User",
          "biometric_records": [{"embedding_id": "emb_1", "quality_score": 0.91}],
          "representative_image_path": "memory/faces/person-1.jpg",
          "representative_quality_score": 0.91,
          "lifecycle": { "created_at": "1", "updated_at": "1" }
        }
      ]
    }
    """)

    let archive = try await makeCoreBrainArchive(for: brain, includeBiometricData: true)
    defer { try? FileManager.default.removeItem(at: archive.scratchRoot) }
    let restored = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveRestoredWithBiometrics-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(restored)
    _ = try await BrainLibrary.importBrainFileWithCore(from: archive.archiveURL, to: restored, expectedBrainID: brain.id)

    XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("memory/face_embeddings/user.embedding").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("memory/biometric_identities.json").path))
    XCTAssertEqual(try exportManifestContainsBiometricData(in: restored), true)

    let peopleData = try Data(contentsOf: restored.appendingPathComponent("memory/people.sqlite"))
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveIncludedPeople-Test-\(UUID().uuidString).sqlite")
    temporaryRoots.append(databaseURL)
    try peopleData.write(to: databaseURL, options: .atomic)
    let cognitiveJSON = try XCTUnwrap(readCognitiveJSON(from: databaseURL))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cognitiveJSON.utf8)) as? [String: Any])
    let subjects = try XCTUnwrap(object["subjects"] as? [[String: Any]])
    let subject = try XCTUnwrap(subjects.first)
    XCTAssertNotNil(subject["biometric_records"])
    XCTAssertEqual(subject["representative_image_path"] as? String, "memory/faces/person-1.jpg")
    XCTAssertEqual(subject["representative_quality_score"] as? Double, 0.91)
  }

  @MainActor
  func testBrainSyncArchiveUsesSharedBiometricExportToggle() async throws {
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudArchiveStore()
    let excludedBrain = try makeBrain()
    try "template".write(
      to: excludedBrain.faceEmbeddingsURL.appendingPathComponent("excluded.embedding"),
      atomically: true,
      encoding: .utf8
    )
    try writeCognitiveStore(at: excludedBrain.memoryDatabaseURL, dataJSON: """
    {"schema_version":1,"subjects":[{"subject_id":"person-1","display_name":"User","biometric_records":[{"embedding_id":"emb_1","quality_score":0.91}],"representative_image_path":"memory/faces/person-1.jpg","representative_quality_score":0.91,"lifecycle":{"created_at":"1","updated_at":"1"}}]}
    """)

    let excludedManager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    excludedManager.selectBrainForSync(excludedBrain)
    try await waitForSyncState(.synced, manager: excludedManager, brain: excludedBrain)

    let excludedArchive = try XCTUnwrap(store.archives[excludedBrain.id])
    let excludedRestored = try await restoreCoreArchiveData(excludedArchive, brainID: excludedBrain.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: excludedRestored.appendingPathComponent("memory/face_embeddings/excluded.embedding").path))
    XCTAssertEqual(try exportManifestContainsBiometricData(in: excludedRestored), false)

    let includedBrain = try makeBrain()
    try "template".write(
      to: includedBrain.faceEmbeddingsURL.appendingPathComponent("included.embedding"),
      atomically: true,
      encoding: .utf8
    )
    try #"{"biometric_export_included": true}"#.write(
      to: includedBrain.runtimeOptionsURL,
      atomically: true,
      encoding: .utf8
    )

    let includedManager = BrainSyncManager(store: store, userDefaults: try makeUserDefaults(), deviceID: "test-device")
    includedManager.selectBrainForSync(includedBrain)
    try await waitForSyncState(.synced, manager: includedManager, brain: includedBrain)

    let includedArchive = try XCTUnwrap(store.archives[includedBrain.id])
    let includedRestored = try await restoreCoreArchiveData(includedArchive, brainID: includedBrain.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: includedRestored.appendingPathComponent("memory/face_embeddings/included.embedding").path))
    XCTAssertEqual(try exportManifestContainsBiometricData(in: includedRestored), true)
  }

  func testBrainStatsJournalRecordsDailySizeSnapshots() throws {
    var journal = BrainStatsJournal()
    let calendar = Calendar(identifier: .gregorian)
    let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 10)))
    let sameDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 18)))
    let nextDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 9)))

    journal.recordSize(100, at: first)
    journal.recordSize(140, at: sameDay)
    journal.recordSize(200, at: nextDay)

    XCTAssertEqual(journal.sizeSnapshots.count, 2)
    XCTAssertEqual(journal.sizeSnapshots.first?.bytes, 100)
    XCTAssertEqual(journal.latestSizeSnapshot?.bytes, 200)
  }

  func testBrainStatsJournalForceRefreshesSameDaySizeSnapshot() throws {
    var journal = BrainStatsJournal()
    let calendar = Calendar(identifier: .gregorian)
    let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 10)))
    let sameDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 18)))

    XCTAssertTrue(journal.recordSize(100, at: first))
    XCTAssertFalse(journal.recordSize(120, at: sameDay))
    XCTAssertTrue(journal.recordSize(140, at: sameDay, force: true))

    XCTAssertEqual(journal.sizeSnapshots.count, 1)
    XCTAssertEqual(journal.latestSizeSnapshot?.bytes, 140)
  }

  func testBrainStatsJournalPersistsNotesAndProfileSnapshotsInsideBrain() throws {
    let brain = try makeBrain()
    var journal = BrainStatsJournal()

    journal.recordSize(512, force: true)
    journal.addNote("Prefers short check-ins.")
    journal.addProfileSnapshot(
      traits: "curious, steady",
      goals: "organize long-term memories",
      recentMemories: "learned the new workspace rhythm"
    )
    try journal.write(to: brain.statsJournalURL)

    let restored = try BrainStatsJournal.load(from: brain.statsJournalURL)
    XCTAssertEqual(restored.latestSizeSnapshot?.bytes, 512)
    XCTAssertEqual(restored.sortedNotes.first?.body, "Prefers short check-ins.")
    XCTAssertEqual(restored.sortedProfileSnapshots.first?.traits, "curious, steady")
    XCTAssertTrue(FileManager.default.fileExists(atPath: brain.rootURL.appendingPathComponent("brain_stats.json").path))
  }

  func testBrainStatsJournalThrowsOnCorruptExistingStatsFile() throws {
    let brain = try makeBrain()
    try "{not-json".write(to: brain.statsJournalURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try BrainStatsJournal.load(from: brain.statsJournalURL))
  }

  func testVisibleMailboxItemsArchivedFilterOnlyShowsArchivedReports() throws {
    let inbox = mailboxItem(sourceDreamID: "inbox", dayKey: "2026-06-25", isArchived: false)
    let archived = mailboxItem(sourceDreamID: "archived", dayKey: "2026-06-24", isArchived: true)

    XCTAssertTrue(AffectiveViewModel.isMailboxItemVisible(inbox, showsArchived: false))
    XCTAssertFalse(AffectiveViewModel.isMailboxItemVisible(archived, showsArchived: false))
    XCTAssertFalse(AffectiveViewModel.isMailboxItemVisible(inbox, showsArchived: true))
    XCTAssertTrue(AffectiveViewModel.isMailboxItemVisible(archived, showsArchived: true))
  }

  @MainActor
  func testMailboxItemMergePreservesCurrentReadAndArchiveState() throws {
    let staleScanned = mailboxItem(sourceDreamID: "dream_1", dayKey: "2026-06-25", isRead: false, isArchived: false)
    let current = mailboxItem(sourceDreamID: "dream_1", dayKey: "2026-06-25", isRead: true, isArchived: true)
    let newScanned = mailboxItem(sourceDreamID: "dream_2", dayKey: "2026-06-26", isRead: false, isArchived: false)

    let merged = AffectiveViewModel.mergedMailboxItems(scanned: [staleScanned, newScanned], current: [current])
    let dreamOne = try XCTUnwrap(merged.first { $0.sourceDreamID == "dream_1" })
    let dreamTwo = try XCTUnwrap(merged.first { $0.sourceDreamID == "dream_2" })

    XCTAssertTrue(dreamOne.isRead)
    XCTAssertTrue(dreamOne.isArchived)
    XCTAssertFalse(dreamTwo.isRead)
    XCTAssertFalse(dreamTwo.isArchived)
  }

  func testMailboxUIStateJournalPersistsReadAndArchiveState() throws {
    let brain = try makeBrain()
    let journal = MailboxUIStateJournal(items: [
      MailboxUIState(mailboxID: "mail_dream_1", isRead: true, isArchived: true)
    ])

    try journal.write(to: brain.mailboxUIStateURL)
    let restored = MailboxUIStateJournal.load(from: brain.mailboxUIStateURL)

    XCTAssertEqual(restored.items, journal.items)
  }

  func testForgetTodayClearsLocalMailboxUIStateAndBacksUpBrain() throws {
    let brain = try makeBrain()
    let today = "2026-06-25"
    let yesterday = "2026-06-24"

    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "traces": [
        { "trace_id": "today_trace", "created_at": "\(today)T15:30:00Z", "text": "bad turn" },
        { "trace_id": "older_touched_trace", "created_at": "\(yesterday)T15:30:00Z", "updated_at": "\(today)T15:45:00Z", "text": "forget me too" },
        { "trace_id": "older_untouched_trace", "created_at": "\(yesterday)T15:30:00Z", "updated_at": "\(yesterday)T15:45:00Z", "text": "keep me" }
      ],
      "beliefs": [],
      "subjects": [],
      "artifacts": [
        { "artifact_id": "today_artifact", "lifecycle": { "created_at": "\(today)T15:30:00Z", "updated_at": "\(today)T15:31:00Z" } },
        { "artifact_id": "older_touched_artifact", "lifecycle": { "created_at": "\(yesterday)T15:30:00Z", "updated_at": "\(today)T15:31:00Z" } },
        { "artifact_id": "older_untouched_artifact", "lifecycle": { "created_at": "\(yesterday)T15:30:00Z", "updated_at": "\(yesterday)T15:31:00Z" } }
      ],
      "dreams": []
    }
    """)

    try MailboxUIStateJournal(items: [
      MailboxUIState(mailboxID: "mail_today", isRead: true, isArchived: false),
      MailboxUIState(mailboxID: "mail_older", isRead: false, isArchived: true),
    ]).write(to: brain.mailboxUIStateURL)

    let now = try XCTUnwrap(MailboxItemDateFormatter.date(from: "\(today)T18:00:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let result = try BrainExperienceForgetter.forgetToday(in: brain, now: now, calendar: calendar)

    XCTAssertEqual(result.clearedMailboxUIStateCount, 2)
    XCTAssertNotNil(result.backupURL)

    let cognitiveJSON = try XCTUnwrap(readCognitiveJSON(from: brain.memoryDatabaseURL))
    XCTAssertTrue(cognitiveJSON.contains("today_trace"))
    XCTAssertTrue(cognitiveJSON.contains("today_artifact"))
    XCTAssertTrue(cognitiveJSON.contains("older_touched_trace"))
    XCTAssertTrue(cognitiveJSON.contains("older_touched_artifact"))
    XCTAssertTrue(cognitiveJSON.contains("older_untouched_trace"))
    XCTAssertTrue(cognitiveJSON.contains("older_untouched_artifact"))

    let mailboxUIState = MailboxUIStateJournal.load(from: brain.mailboxUIStateURL)
    XCTAssertEqual(mailboxUIState.items, [])

    let backupURL = try XCTUnwrap(result.backupURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("memory/people.sqlite").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("mailbox_ui_state.json").path))
  }

  @MainActor
  func testBrainKnowledgeReaderLoadsStoredMemoriesAndFiltersSearch() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "events": [
        {
          "id": "event_memory_recall",
          "timestamp_ms": 1782605136000,
          "source": "memory",
          "kind": "Memory.MemoryRecalled",
          "payload": "query=Zelda enrollment"
        },
        {
          "id": "event_unrelated",
          "timestamp_ms": 1782605137000,
          "source": "host",
          "kind": "Host.Attached",
          "payload": "platform=macOS"
        }
      ],
      "memories": [
        {
          "memory_id": "memory_zelda",
          "status": "active",
          "scope": "long_term",
          "text": "Zelda enrolled successfully.",
          "interpretation": "identity memory",
          "tags": ["identity"],
          "created_at": "1782605136",
          "access_count": 1
        }
      ],
      "dream_time_records": [
        {
          "dream_id": "dream_1",
          "title": "Rain workshop dream",
          "text": "A dream about Zelda and rain.",
          "created_at_ms": 1782605138000
        }
      ],
      "appraisals": [],
      "impressions": [],
      "beliefs": [],
      "subjects": [],
      "artifacts": [],
      "dreams": []
    }
    """)

    let entries = try BrainKnowledgeReader.loadEntries(from: brain)
    XCTAssertTrue(entries.contains { $0.metadata["memory_id"] == "memory_zelda" })
    XCTAssertTrue(entries.contains { $0.metadata["event_id"] == "event_memory_recall" })
    XCTAssertFalse(entries.contains { $0.metadata["event_id"] == "event_unrelated" })

    let model = AffectiveViewModel(brain: brain)
    model.refreshKnowledgeEntries()
    XCTAssertEqual(model.filteredKnowledgeEntries.count, entries.count)

    model.knowledgeSearchText = "Zelda"
    let filtered = model.filteredKnowledgeEntries
    XCTAssertTrue(filtered.contains { $0.metadata["memory_id"] == "memory_zelda" })
    XCTAssertTrue(filtered.contains { $0.metadata["event_id"] == "event_memory_recall" })
    XCTAssertTrue(filtered.contains { $0.metadata["dream_id"] == "dream_1" })
  }

  func testDreamLoadCheckRequestsDreamWhenNoDreamExists() throws {
    let now = try XCTUnwrap(MailboxItemDateFormatter.date(from: "2026-06-25T22:30:00Z"))

    XCTAssertTrue(AffectiveViewModel.shouldRequestDreamTimeFromMailbox([], now: now))
  }

  func testDreamLoadCheckSkipsRecentMailboxDream() throws {
    let now = try XCTUnwrap(MailboxItemDateFormatter.date(from: "2026-06-25T22:30:00Z"))
    let reportDate = try XCTUnwrap(MailboxItemDateFormatter.date(from: "2026-06-24T23:30:00Z"))
    let item = mailboxItem(sourceDreamID: "dream_recent", dayKey: "2026-06-24", createdAt: reportDate)

    XCTAssertFalse(AffectiveViewModel.shouldRequestDreamTimeFromMailbox([item], now: now))
  }

  func testDreamLoadCheckRequestsDreamWhenLatestMailboxDreamIsAtLeastTwentyFourHoursOld() throws {
    let now = try XCTUnwrap(MailboxItemDateFormatter.date(from: "2026-06-25T22:30:00Z"))
    let item = mailboxItem(sourceDreamID: "dream_old", dayKey: "2026-06-24")

    XCTAssertTrue(AffectiveViewModel.shouldRequestDreamTimeFromMailbox([item], now: now))
  }

  func testCoreLoadPerformanceSessionRecordsPhasesAndSummary() async {
    let session = CoreLoadPerformanceSession()
    await session.measure(id: "phase_a", label: "Phase A") {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    let report = session.report()
    XCTAssertEqual(report.phases.map(\.label), ["Phase A"])
    XCTAssertGreaterThanOrEqual(report.phases[0].durationMs, 0)
    XCTAssertGreaterThanOrEqual(report.totalMs, report.phases[0].durationMs)
    XCTAssertTrue(report.eventLogBody.contains("Phase A:"))
    XCTAssertTrue(report.summaryText.contains("Core load"))
  }

  func testShowsCoreConnectingScreenUntilConnected() async throws {
    let brain = try makeBrain()
    let core = ScriptedBrainCore(
      toolResponse: BrainToolResponse(toolName: "mock", text: "", metadata: [:], events: [], rawText: "{}"),
      cameraObservationResponse: BrainToolResponse(toolName: "mock", text: "", metadata: [:], events: [], rawText: "{}")
    )
    let model = AffectiveViewModel(brain: brain, brainCore: core)
    XCTAssertTrue(model.showsCoreConnectingScreen)

    await model.connectToBrain()

    XCTAssertTrue(model.isBrainConnected)
    XCTAssertFalse(model.showsCoreConnectingScreen)

    model.isBrainConnected = false
    model.isBrainConnectionInFlight = true
    XCTAssertFalse(model.showsCoreConnectingScreen)
  }

  func testBrainFileAccessGateRejectsDuplicateLiveSession() throws {
    let brainID = "duplicate-brain"
    try BrainFileAccessGate.acquireLiveSession(brainID: brainID)
    defer { BrainFileAccessGate.releaseLiveSession(brainID: brainID) }
    XCTAssertThrowsError(try BrainFileAccessGate.acquireLiveSession(brainID: brainID)) { error in
      XCTAssertEqual(error as? BrainFileAccessError, .duplicateLiveSession(brainID: brainID))
    }
  }

  func testBrainFileAccessGateRunExclusiveWaitsForLiveSessionRelease() async throws {
    let brainID = "exclusive-wait-brain"
    try BrainFileAccessGate.acquireLiveSession(brainID: brainID)

    var exclusiveRan = false
    let exclusiveTask = Task {
      await BrainFileAccessGate.runExclusive(brainID: brainID) {
        exclusiveRan = true
      }
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(exclusiveRan)

    BrainFileAccessGate.releaseLiveSession(brainID: brainID)
    await exclusiveTask.value
    XCTAssertTrue(exclusiveRan)
  }

  func testBrainKnowledgeReaderAllowsReadOnlyLoadDuringLiveSession() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 1,
      "events": [],
      "memories": [
        {
          "memory_id": "memory_live_session",
          "status": "active",
          "scope": "long_term",
          "text": "Readable while core is connected.",
          "created_at": "1782605136"
        }
      ],
      "dream_time_records": [],
      "appraisals": [],
      "impressions": [],
      "beliefs": [],
      "subjects": [],
      "artifacts": [],
      "dreams": []
    }
    """)
    try BrainFileAccessGate.acquireLiveSession(brainID: brain.id)
    defer { BrainFileAccessGate.releaseLiveSession(brainID: brain.id) }

    let entries = try BrainKnowledgeReader.loadEntries(from: brain)
    XCTAssertTrue(entries.contains { $0.metadata["memory_id"] == "memory_live_session" })
  }

  private func makeBrain(
    profile: String = #"{"schema_version":1,"display_name":"Test Brain"}"#,
    runtimeOptions: String = "{}",
    displayName: String = "Test Brain"
  ) throws -> BrainDescriptor {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveTests-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(root)

    let memory = root.appendingPathComponent("memory", isDirectory: true)
    let faceEmbeddings = memory.appendingPathComponent("face_embeddings", isDirectory: true)
    try FileManager.default.createDirectory(at: faceEmbeddings, withIntermediateDirectories: true)
    try profile.write(
      to: root.appendingPathComponent("brain_profile.json"), atomically: true, encoding: .utf8)
    try "Maintenance".write(
      to: root.appendingPathComponent("maintenance.md"), atomically: true, encoding: .utf8)
    try runtimeOptions.write(
      to: root.appendingPathComponent("runtime_options.json"), atomically: true, encoding: .utf8)

    return BrainDescriptor(
      id: root.lastPathComponent,
      displayName: displayName,
      rootURL: root,
      avatarURL: nil,
      avatarManifest: nil,
      modifiedAt: nil,
      isRecent: false
    )
  }

  private func withConnectedCore<Result>(
    _ core: BrainCore,
    _ body: () async throws -> Result
  ) async throws -> Result {
    try await core.connect()
    do {
      let result = try await body()
      await core.disconnect()
      return result
    } catch {
      await core.disconnect()
      throw error
    }
  }

  private static let tinyPNGData = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0xFF,
    0x7F, 0x00, 0x09, 0xFB, 0x03, 0xFD, 0x05, 0x43,
    0x45, 0xCA, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ])

  private static func pngFixture(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
  ) throws -> Data {
    #if canImport(ImageIO)
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    for y in 0..<height {
      for x in 0..<width {
        let color = pixel(x, y)
        let index = (y * bytesPerRow) + (x * bytesPerPixel)
        pixels[index] = color.red
        pixels[index + 1] = color.green
        pixels[index + 2] = color.blue
        pixels[index + 3] = color.alpha
      }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
      throw CameraCaptureError.invalidImageData
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      "public.png" as CFString,
      1,
      nil
    ) else {
      throw CameraCaptureError.invalidImageData
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CameraCaptureError.invalidImageData
    }
    return data as Data
    #else
    throw CameraCaptureError.invalidImageData
    #endif
  }

  private static func jpegFixture(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
  ) throws -> Data {
    let pngData = try pngFixture(width: width, height: height, pixel: pixel)
    guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw CameraCaptureError.invalidImageData
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      "public.jpeg" as CFString,
      1,
      [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
    ) else {
      throw CameraCaptureError.invalidImageData
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CameraCaptureError.invalidImageData
    }
    return data as Data
  }

  private static func pngPixelAlpha(data: Data, x: Int, y: Int) throws -> UInt8 {
    #if canImport(ImageIO)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw CameraCaptureError.invalidImageData
    }
    let width = image.width
    let height = image.height
    guard x >= 0, y >= 0, x < width, y < height else {
      throw CameraCaptureError.invalidImageData
    }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo).rawValue
    ) else {
      throw CameraCaptureError.invalidImageData
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let index = (y * bytesPerRow) + (x * bytesPerPixel) + 3
    return pixels[index]
    #else
    throw CameraCaptureError.invalidImageData
    #endif
  }

  private func makeBrainWithExpressionAvatar() throws -> BrainDescriptor {
    let brain = try makeBrain()
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 128, height: 128),
      layers: [
        .init(
          id: "eyes",
          atlas: "avatar/eyes.png",
          x: 0,
          y: 0,
          width: 128,
          height: 64,
          z: 0,
          frameWidth: 128,
          frameHeight: 64,
          frames: 2,
          frame: 0)
      ],
      defaultExpression: "happy",
      expressions: [
        .init(id: "happy", name: "Happy", layers: ["eyes": .init(frame: 1)])
      ],
      rootURL: brain.rootURL
    )

    return BrainDescriptor(
      id: brain.id,
      displayName: brain.displayName,
      rootURL: brain.rootURL,
      avatarURL: brain.avatarURL,
      avatarManifest: manifest,
      modifiedAt: brain.modifiedAt,
      isRecent: brain.isRecent
    )
  }

  private func writeCognitiveStore(at url: URL, dataJSON: String) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    defer { sqlite3_close(database) }
    XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE cognitive_memory (id INTEGER PRIMARY KEY, data_json TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
    let escaped = dataJSON.replacingOccurrences(of: "'", with: "''")
    let sql = "INSERT INTO cognitive_memory (id, data_json) VALUES (1, '\(escaped)')"
    XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
  }

  private func readCognitiveJSON(from url: URL) throws -> String? {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW,
          let textPointer = sqlite3_column_text(statement, 0) else {
      return nil
    }
    return String(cString: textPointer)
  }

  @MainActor
  private func makeCoreBrainArchive(
    for brain: BrainDescriptor,
    deviceID: String = "test-device",
    revision: Int = 1,
    includeBiometricData: Bool = true
  ) async throws -> BrainCloudArchive.Created {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveTestBrainArchive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let archiveURL = scratch.appendingPathComponent(BrainCloudArchive.archiveFileName(for: brain.id))

    let exportBrain: BrainDescriptor
    if includeBiometricData {
      exportBrain = brain
    } else {
      let scrubbedRoot = scratch.appendingPathComponent("scrubbed", isDirectory: true)
      try BrainLibrary.copyBrain(
        from: brain.rootURL,
        to: scrubbedRoot,
        includeBiometricData: false,
        fileManager: .default
      )
      exportBrain = BrainDescriptor(
        id: brain.id,
        displayName: brain.displayName,
        rootURL: scrubbedRoot,
        avatarURL: nil,
        avatarManifest: nil,
        modifiedAt: brain.modifiedAt,
        isRecent: brain.isRecent
      )
    }

    let core = BrainCore(brain: exportBrain, tracksLiveFileSession: false)
    do {
      _ = try await BrainFileAccessGate.runExclusive(brainID: brain.id) {
        try await core.exportBrain(to: archiveURL)
      }
      await core.disconnect()
    } catch {
      await core.disconnect()
      throw error
    }

    let modifiedAt = brain.modifiedAt ?? Date()
    return BrainCloudArchive.Created(
      archiveURL: archiveURL,
      scratchRoot: scratch,
      manifest: BrainCloudManifest(
        brainID: brain.id,
        displayName: brain.displayName,
        schemaVersion: 1,
        archiveHash: try BrainCloudArchive.archiveHash(at: archiveURL),
        createdAt: modifiedAt,
        modifiedAt: modifiedAt,
        uploadedAt: Date(),
        deviceID: deviceID,
        revision: revision
      )
    )
  }

  @MainActor
  private func restoreCoreArchiveData(_ data: Data, brainID: String) async throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveTestBrainRestore-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = scratch.appendingPathComponent(BrainCloudArchive.archiveFileName(for: brainID))
    let restored = scratch.appendingPathComponent("restored", isDirectory: true)
    temporaryRoots.append(scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try data.write(to: archiveURL, options: .atomic)
    _ = try await BrainLibrary.importBrainFileWithCore(from: archiveURL, to: restored, expectedBrainID: brainID)
    return restored
  }

  private func exportManifestContainsBiometricData(in rootURL: URL) throws -> Bool? {
    let data = try Data(contentsOf: rootURL.appendingPathComponent("export_manifest.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["contains_biometric_data"] as? Bool
  }

  private func fixtureURL(_ name: String, extension ext: String, subdirectory: String) throws -> URL {
    try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory)
        ?? Bundle(for: Self.self).url(forResource: name, withExtension: ext),
      "Missing test fixture \(subdirectory)/\(name).\(ext)"
    )
  }

  private func skipPlaceholderImageFixtures(_ urls: [URL]) throws {
    for url in urls {
      let data = try Data(contentsOf: url)
      if data.starts(with: Data("placeholder fixture:".utf8)) {
        throw XCTSkip("Face recognition fixture \(url.lastPathComponent) is a text placeholder, not an image.")
      }
    }
  }

  private func cameraJPEGFixture(from sourceURL: URL, named name: String, in rootURL: URL) throws -> URL {
    #if canImport(ImageIO)
    let data = try Data(contentsOf: sourceURL)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw CameraCaptureError.invalidImageData
    }
    let directory = rootURL.appendingPathComponent("test-camera-fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destinationURL = directory.appendingPathComponent("\(name).jpg")
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
      throw CameraCaptureError.invalidImageData
    }
    let options = [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else {
      throw CameraCaptureError.invalidImageData
    }
    try (output as Data).write(to: destinationURL, options: .atomic)
    return destinationURL
    #else
    throw CameraCaptureError.invalidImageData
    #endif
  }

  private func recognitionRequestData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func postRecognitionResponse<Response: Decodable>(
    body: Data,
    to url: String,
    using hostServices: EmbeddedHostServices
  ) throws -> Response {
    let response = try hostServices.postJSON(url: url, headersJSON: "[]", body: body)
    return try JSONDecoder().decode(Response.self, from: response)
  }

  private func waitForPokeSequenceCount(
    _ expected: Int,
    in core: ScriptedBrainCore,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async -> [[PokePulse]] {
    for _ in 0..<100 {
      let pokes = await core.pokeSequences
      if pokes.count >= expected {
        return pokes
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(expected) poke sequence calls.", file: file, line: line)
    return await core.pokeSequences
  }

  private func brainChatEvent(title: String?, text: String) -> BrainEvent {
    expressionEvent(title: title, text: text)
  }

  private func brainExpressionEvent(text: String) -> BrainEvent {
    expressionEvent(title: "Brain", text: text)
  }

  private func facialExpressionEvent(eyes: String?, mouth: String?) -> BrainEvent {
    actionRequestEvent(
      actionID: "expression-fixture",
      action: "show_expression",
      arguments: [
        "eyes": eyes.map(JSONValue.string) ?? .null,
        "mouth": mouth.map(JSONValue.string) ?? .null,
      ],
      presentation: .chat
    )
  }

  private func emoteExpressionEvent(text: String) -> BrainEvent {
    expressionEvent(
      title: "Brain",
      text: text,
      expressionID: "emote-fixture-expression",
      modality: .emote,
      presentation: .chat
    )
  }

  private func speechRequestedEvent(text: String) -> BrainEvent {
    actionRequestEvent(
      actionID: "speech-fixture",
      action: "speak",
      arguments: ["text": .string(text)],
      presentation: .chat
    )
  }

  private func expressionEvent(
    title: String?,
    text: String,
    expressionID: String = "chat-fixture-expression",
    role: BrainParticipantRole = .selfRole,
    modality: BrainEventModality = .text,
    visibility: BrainEventVisibility = .public,
    presentation: BrainEventPresentation = .chat,
    source: BrainEventEndpoint = .brain,
    target: BrainEventEndpoint = .host
  ) -> BrainEvent {
    BrainEvent(
      id: expressionID,
      traceID: "trace-\(expressionID)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: source,
      target: target,
      visibility: visibility,
      presentation: presentation,
      payload: .expression(BrainExpressionPayload(
        modality: modality,
        role: role,
        title: title,
        text: text,
        media: [],
        expressionID: expressionID,
        eyes: nil,
        mouth: nil,
        durationMS: nil
      ))
    )
  }

  private func actionRequestEvent(
    actionID: String,
    action: String,
    arguments: [String: JSONValue],
    requires: [String] = [],
    presentation: BrainEventPresentation = .internalOnly
  ) -> BrainEvent {
    BrainEvent(
      id: actionID,
      traceID: "trace-\(actionID)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: .brain,
      target: .host,
      visibility: .public,
      presentation: presentation,
      payload: .capabilityRequest(BrainActionRequestPayload(
        actionID: actionID,
        action: action,
        arguments: .object(arguments),
        requires: requires,
        awaitResponse: true
      ))
    )
  }

  private func senseRequestEvent(
    requestID: String,
    sense: String,
    title: String,
    summary: String,
    responsePresentation: BrainEventPresentation = .internalOnly,
    awaitResponse: Bool = true,
    timeoutMS: Int? = nil
  ) -> BrainEvent {
    BrainEvent(
      id: requestID,
      traceID: "trace-\(requestID)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: .brain,
      target: .host,
      visibility: .diagnostic,
      presentation: .internalOnly,
      payload: .senseRequest(BrainSenseRequestPayload(
        senseID: sense,
        direction: .pull,
        timeoutMS: awaitResponse ? timeoutMS : nil,
        responsePresentation: responsePresentation
      ))
    )
  }

  private func attentionStatusEvent(id: String, title: String, summary: String) -> BrainEvent {
    BrainEvent(
      id: id,
      traceID: "trace-\(id)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: .brain,
      target: .host,
      visibility: .diagnostic,
      presentation: .status,
      payload: .attentionState(BrainAttentionStatePayload(
        focusEventID: nil,
        competingEventIDs: [],
        summary: summary,
        suppressionReason: title
      ))
    )
  }

  private func controlEvent(
    id: String,
    sendEnabled: Bool? = nil,
    status: String? = nil
  ) -> BrainEvent {
    BrainEvent(
      id: id,
      traceID: "trace-\(id)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: .brain,
      target: .host,
      visibility: .diagnostic,
      presentation: .status,
      payload: .control(BrainControlPayload(
        phase: nil,
        sendEnabled: sendEnabled,
        status: status
      ))
    )
  }

  private func memoryMutationEvent(id: String, summary: String) -> BrainEvent {
    BrainEvent(
      id: id,
      traceID: "trace-\(id)",
      parentID: nil,
      turnID: nil,
      loopID: nil,
      occurredAt: "2026-06-26T00:00:00Z",
      source: .brain,
      target: .host,
      visibility: .diagnostic,
      presentation: .log,
      payload: .memoryMutation(BrainMemoryMutationPayload(
        operation: .remember,
        layer: .episodic,
        recordIDs: ["record-\(id)"],
        summary: summary
      ))
    )
  }

  private func encodedEnvelopeText(
    requestID: String,
    events: [BrainEvent],
    result: JSONValue?,
    budget: BrainDispatchBudget?
  ) throws -> String {
    let envelope = BrainDispatchEnvelope(
      requestID: requestID,
      ok: true,
      events: events,
      result: result,
      error: nil,
      budget: budget,
      rawText: ""
    )
    let data = try JSONEncoder().encode(envelope)
    return String(decoding: data, as: UTF8.self)
  }

  private func mailboxItem(
    sourceDreamID: String,
    dayKey: String,
    createdAt: Date? = nil,
    isRead: Bool = false,
    isArchived: Bool = false
  ) -> MailboxItem {
    let createdAt = createdAt ?? MailboxItemDateFormatter.date(from: "\(dayKey)T22:30:00Z") ?? Date()
    return MailboxItem(
      mailboxID: "\(dayKey)-\(sourceDreamID)",
      sourceDreamID: sourceDreamID,
      dayKey: dayKey,
      createdAt: createdAt,
      summary: "Summary for \(sourceDreamID).",
      summarySource: "test_mailbox",
      bodyText: "DreamMail body for \(sourceDreamID).",
      reflection: "Reflection for \(sourceDreamID).",
      heat: 0.5,
      style: "associative_synthesis",
      confidence: 0.575,
      sourceEventIDs: ["trace_1"],
      artifactID: "artifact_\(sourceDreamID)",
      imagePath: nil,
      imageMimeType: nil,
      imageSpec: nil,
      isRead: isRead,
      isArchived: isArchived
    )
  }

  private func makeUserDefaults() throws -> UserDefaults {
    let suiteName = "AffectiveTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func embeddedString(_ value: AffectiveCoreEmbeddedString) -> String {
    guard let ptr = value.ptr, value.len > 0 else {
      return ""
    }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
  }

  @MainActor
  private func waitForSyncState(
    _ expected: BrainSyncState,
    manager: BrainSyncManager,
    brain: BrainDescriptor,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if manager.state(for: brain) == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for \(expected); saw \(manager.state(for: brain))", file: file, line: line)
  }

  @MainActor
  private func waitForSyncFailure(
    manager: BrainSyncManager,
    brain: BrainDescriptor,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if case .failed = manager.state(for: brain) {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for failure; saw \(manager.state(for: brain))", file: file, line: line)
  }

  @MainActor
  private func waitForCloudImportCount(
    _ expected: Int,
    manager: BrainSyncManager,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if manager.importableCloudBrains.count == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(
      "Timed out waiting for \(expected) cloud imports; saw \(manager.importableCloudBrains.count)",
      file: file,
      line: line
    )
  }

  @MainActor
  private func waitForCloudUnavailableImportCount(
    _ expected: Int,
    manager: BrainSyncManager,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if manager.unavailableCloudImports.count == expected {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(
      "Timed out waiting for \(expected) unavailable cloud imports; saw \(manager.unavailableCloudImports.count)",
      file: file,
      line: line
    )
  }

  private func providerCredentials(from environment: [String: String]) -> [ProviderCredentialKey:
    String]
  {
    var credentials: [ProviderCredentialKey: String] = [:]
    if let value = nonEmptyEnvironmentValue("OPENAI_API_KEY", in: environment) {
      credentials[.openAI] = value
    }
    if let value = nonEmptyEnvironmentValue("ANTHROPIC_API_KEY", in: environment) {
      credentials[.anthropic] = value
    }
    if let value = nonEmptyEnvironmentValue("GEMINI_API_KEY", in: environment)
      ?? nonEmptyEnvironmentValue("GOOGLE_API_KEY", in: environment)
      ?? nonEmptyEnvironmentValue("GOOGLE_AI_API_KEY", in: environment)
    {
      credentials[.google] = value
    }
    if let value = nonEmptyEnvironmentValue("DEEPSEEK_API_KEY", in: environment) {
      credentials[.deepseek] = value
    }
    return credentials
  }

  private func nonEmptyEnvironmentValue(_ key: String, in environment: [String: String]) -> String?
  {
    let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private static var hostCapabilityE2ECoverage: [String: HostCapabilityE2ECoverage] {
    [
      "text_input": .providerBackedDispatch,
      "text_input": .typedOperation,
      "speech_input": .typedOperation,
      "speech_input": .hostAdapter,
      "speech_output": .hostAdapter,
      "camera_capture": .permissionGatedHostAdapter,
      "microphone_capture": .hostAdapter,
      "orientation_read": .permissionGatedHostAdapter,
      "motion_gesture_read": .embeddedDispatch,
      "uploaded_media_read": .hostAdapter,
      "memory_read": .hostAdapter,
      "memory_write": .hostAdapter,
      "reminder_read": .hostAdapter,
      "reminder_write": .hostAdapter,
      "notification_schedule": .hostAdapter,
      "stored_image_read": .hostAdapter,
      "stored_memory_read": .hostAdapter,
      "stored_memory_write": .hostAdapter,
      "face_identification": .hostAdapter,
      "face_enrollment": .hostAdapter,
      "identity_recognition": .hostAdapter,
      "face_picture_update": .hostAdapter,
      "event_envelope": .embeddedRoute,
      "event_drain": .embeddedRoute,
      "sense_catalog": .embeddedRoute,
      "sense_status": .embeddedRoute,
      "sense_observation": .embeddedRoute,
      "orientation_query": .permissionGatedHostAdapter,
      "reminder_io": .hostAdapter,
      "image_generation": .providerBackedHostAdapter,
      "facial_expression_output": .hostAdapter,
      "time_lookup": .embeddedRoute,
      "power_status": .hostAdapter,
      "storage_fullness": .hostAdapter,
      "database_stats": .hostAdapter,
      "local_process_io": .hostAdapter,
      "file_import": .hostAdapter,
      "file_export": .hostAdapter,
      "import_brain": .embeddedRoute,
      "export_brain": .embeddedRoute,
      "provider_image_generation": .providerBackedHostAdapter,
      "provider_vision_completion": .providerBackedHostAdapter,
      "provider_text_completion": .providerBackedHostAdapter,
    ]
  }

  private static func allAdvertisedHostCapabilities() throws -> Set<String> {
    let enabledBiometricPolicy = BiometricDataPolicy(
      recognitionEnabled: true,
      policyAcknowledged: true,
      enrollmentAllowed: true,
      retentionPeriod: BiometricDataPolicy.defaultRetentionPeriod,
      exportIncluded: false,
      exportConfirmationRequired: true,
      autoDeleteUnconfirmed: true
    )
    let manifests = [
      CoreConfigStorage.hostManifestJSON(
        hasProvider: false,
        cameraStatus: "denied",
        orientationStatus: "denied"),
      CoreConfigStorage.hostManifestJSON(
        hasProvider: true,
        cameraStatus: "available",
        orientationStatus: "available"),
      CoreConfigStorage.hostManifestJSON(
        hasProvider: true,
        cameraStatus: "prompt_required",
        orientationStatus: "prompt_required",
        motionGestureStatus: "available"),
      CoreConfigStorage.hostManifestJSON(
        hasProvider: true,
        cameraStatus: "available",
        orientationStatus: "available",
        biometricPolicy: enabledBiometricPolicy),
    ]
    let capabilityLists = try manifests.map { manifest -> [String] in
      let object = try JSONValue.decodedObject(from: Data(manifest.utf8))
      return try XCTUnwrap(object["capabilities"]?.arrayValue).compactMap(\.stringValue)
    }
    return Set(capabilityLists.flatMap { $0 })
  }

  private static func toolResponse(
    toolName: String,
    events: [BrainEvent] = [],
    result: JSONValue? = nil,
    requestID: String = UUID().uuidString
  ) -> BrainToolResponse {
    let envelope = BrainDispatchEnvelope(
      requestID: requestID,
      ok: true,
      events: events,
      result: result,
      error: nil,
      rawText: ""
    )
    return BrainToolResponse(toolName: toolName, envelope: envelope, rawText: envelope.rawText)
  }

}

private enum HostCapabilityE2ECoverage: Equatable {
  case embeddedDispatch
  case embeddedRoute
  case hostAdapter
  case permissionGatedHostAdapter
  case providerBackedDispatch
  case providerBackedHostAdapter
  case typedOperation
}

private struct RecognitionIdentityResponse: Decodable {
  let personPresent: Bool
  let matchStatus: String
  let personID: String?
  let confidence: Float
  let candidateName: String?
  let peopleCount: Int

  enum CodingKeys: String, CodingKey {
    case personPresent = "person_present"
    case matchStatus = "match_status"
    case personID = "person_id"
    case confidence
    case candidateName = "candidate_name"
    case peopleCount = "people_count"
  }
}

private struct RecognitionEnrollResponse: Decodable {
  let personID: String
  let displayName: String?
  let representativeImagePath: String
  let embeddingPath: String
  let qualityScore: Float
  let removedEmbeddings: Int
  let keptExisting: Bool

  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case displayName = "display_name"
    case representativeImagePath = "representative_image_path"
    case embeddingPath = "embedding_path"
    case qualityScore = "quality_score"
    case removedEmbeddings = "removed_embeddings"
    case keptExisting = "kept_existing"
  }
}

private actor ScriptedBrainCore: BrainCoreClient {
  struct ToolCall: Equatable {
    let name: String
    let arguments: [String: JSONValue]
  }

  struct TextCall: Equatable {
    let text: String
    let source: LanguageInputSource
    let attachments: [[String: JSONValue]]
    let stimulusContext: StimulusContext?
  }

  struct EmojiReactionCall: Equatable {
    let emoji: String
    let utteranceText: String
    let speakerLabel: String
    let utteranceEventID: String?
  }

  struct CameraObservation: Equatable {
    let path: String
    let mimeType: String
    let source: String
    let requestID: String?
    let presentation: BrainEventPresentation
  }

  struct OrientationObservationCall: Equatable {
    let observation: OrientationObservation
    let requestID: String?
    let presentation: BrainEventPresentation
  }

  struct MotionGestureObservationCall: Equatable {
    let observation: MotionGestureObservation
    let presentation: BrainEventPresentation
  }

  struct PullSenseStatusCall: Equatable {
    let sense: String
    let direction: PullSenseDirection
    let status: PullSenseTerminalStatus
    let requestID: String?
    let timeoutMS: Int?
    let reason: String
    let availability: String?
    let permissionState: String?
    let terminal: Bool
  }

  private let toolResponse: BrainToolResponse
  private let textResponse: BrainTextResponse
  private let shortTouchResponse: BrainToolResponse
  private let orientationObservationResponse: BrainToolResponse
  private let motionGestureObservationResponse: BrainToolResponse
  private let cameraObservationResponse: BrainToolResponse
  private let mailboxItems: [BrainMailboxItem]
  private let brainModeValue: String
  private let cameraObservationDelayNanoseconds: UInt64
  private let pullSenseStatusError: Error?
  private(set) var didConnect = false
  private(set) var didDisconnect = false
  private(set) var toolCalls: [ToolCall] = []
  private(set) var hostAttachCalls: [ToolCall] = []
  private(set) var hostCapabilityManifestCalls: [ToolCall] = []
  private(set) var sendExperienceEventCalls: [ToolCall] = []
  private(set) var textCalls: [TextCall] = []
  private(set) var emojiReactionCalls: [EmojiReactionCall] = []
  private(set) var interruptCalls: [(userText: String, reason: String, interruptedAction: String?, canceledCount: Int)] = []
  private(set) var pokeSequences: [[PokePulse]] = []
  var blockedTextCallCount = 0
  private var textCallBarrierContinuations: [CheckedContinuation<Void, Never>] = []
  private var textCallContinuations: [(minimumCount: Int, continuation: CheckedContinuation<[TextCall], Never>)] = []
  private var experienceEventCallContinuations: [(minimumCount: Int, continuation: CheckedContinuation<[ToolCall], Never>)] = []
  private(set) var orientationObservations: [OrientationObservationCall] = []
  private(set) var motionGestureObservations: [MotionGestureObservationCall] = []
  private(set) var cameraObservations: [CameraObservation] = []
  private(set) var senseCatalogRequests: [String?] = []
  private(set) var pullSenseStatuses: [PullSenseStatusCall] = []
  private(set) var mailboxMarkReadIDs: [String] = []
  private(set) var mailboxListCallCount = 0

  init(
    toolResponse: BrainToolResponse,
    textResponse: BrainTextResponse? = nil,
    shortTouchResponse: BrainToolResponse? = nil,
    orientationObservationResponse: BrainToolResponse? = nil,
    motionGestureObservationResponse: BrainToolResponse? = nil,
    cameraObservationResponse: BrainToolResponse,
    mailboxItems: [BrainMailboxItem] = [],
    brainMode: String = "waking",
    cameraObservationDelayNanoseconds: UInt64 = 0,
    pullSenseStatusError: Error? = nil,
    blockedTextCallCount: Int = 0
  ) {
    self.toolResponse = toolResponse
    self.textResponse = textResponse ?? BrainTextResponse(toolName: "experience", text: "", metadata: [:], events: [])
    self.shortTouchResponse = shortTouchResponse ?? toolResponse
    self.orientationObservationResponse = orientationObservationResponse ?? toolResponse
    self.motionGestureObservationResponse = motionGestureObservationResponse ?? toolResponse
    self.cameraObservationResponse = cameraObservationResponse
    self.mailboxItems = mailboxItems
    self.brainModeValue = brainMode
    self.cameraObservationDelayNanoseconds = cameraObservationDelayNanoseconds
    self.pullSenseStatusError = pullSenseStatusError
    self.blockedTextCallCount = blockedTextCallCount
  }

  func connect(progress: CoreLoadPerformanceSession?) async throws -> BrainDispatchEnvelope {
    _ = progress
    didConnect = true
    return BrainDispatchEnvelope(requestID: "mock-connect", ok: true, events: [], result: nil, error: nil)
  }

  func disconnect() async {
    didDisconnect = true
  }

  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse {
    switch event.payload {
    case .capabilityRequest(let payload):
      toolCalls.append(ToolCall(
        name: payload.action,
        arguments: payload.arguments.objectValue ?? [:]
      ))
    default:
      toolCalls.append(ToolCall(name: event.type, arguments: [:]))
    }
    return toolResponse
  }

  func sendEvents(_ events: [BrainEvent]) async throws -> BrainToolResponse {
    for event in events {
      _ = try await sendEvent(event)
    }
    return toolResponse
  }

  func hostAttach(
    hostID: String,
    platform: String,
    permissions: [String],
    capabilityIDs: [String],
    providerAvailability: String,
    sensorQuality: String,
    localPolicy: String
  ) async throws -> BrainToolResponse {
    hostAttachCalls.append(ToolCall(name: "host_attach", arguments: [
      "host_id": .string(hostID),
      "platform": .string(platform),
      "permissions": .array(permissions.map(JSONValue.string)),
      "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
      "provider_availability": .string(providerAvailability),
      "sensor_quality": .string(sensorQuality),
      "local_policy": .string(localPolicy),
    ]))
    return toolResponse
  }

  func hostCapabilityManifest(hostID: String, capabilityIDs: [String]) async throws -> BrainToolResponse {
    hostCapabilityManifestCalls.append(ToolCall(name: "host_capability_manifest", arguments: [
      "host_id": .string(hostID),
      "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
    ]))
    return toolResponse
  }

  func refreshFacialExpressionCatalog() async throws -> BrainToolResponse {
    toolCalls.append(ToolCall(name: "refresh_facial_expression_catalog", arguments: [:]))
    return toolResponse
  }

  func sendExperienceEvent(
    hostID: String?,
    source: String,
    kind: String,
    payload: String,
    salience: Double,
    confidence: Double,
    valence: Double,
    arousal: Double,
    uncertainty: Double,
    causalParentIDs: [String],
    retention: String,
    visibility: String
  ) async throws -> BrainToolResponse {
    var arguments: [String: JSONValue] = [
      "source": .string(source),
      "kind": .string(kind),
      "payload": .string(payload),
      "salience": .number(salience),
      "confidence": .number(confidence),
      "valence": .number(valence),
      "arousal": .number(arousal),
      "uncertainty": .number(uncertainty),
      "causal_parent_ids": .array(causalParentIDs.map(JSONValue.string)),
      "retention": .string(retention),
      "visibility": .string(visibility),
    ]
    if let hostID {
      arguments["host_id"] = .string(hostID)
    }
    sendExperienceEventCalls.append(ToolCall(name: "send_experience_event", arguments: arguments))
    fulfillExperienceEventCallContinuations()
    return toolResponse
  }

  func shortTouch() async throws -> BrainToolResponse {
    shortTouchResponse
  }

  func longTouch() async throws -> BrainToolResponse {
    toolResponse
  }

  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse {
    pokeSequences.append(pulses)
    return toolResponse
  }

  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String?,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse {
    orientationObservations.append(OrientationObservationCall(
      observation: observation,
      requestID: requestID,
      presentation: presentation
    ))
    return orientationObservationResponse
  }

  func pushedMotionGestureObservation(
    _ observation: MotionGestureObservation,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse {
    motionGestureObservations.append(MotionGestureObservationCall(
      observation: observation,
      presentation: presentation
    ))
    return motionGestureObservationResponse
  }

  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse {
    cameraObservations.append(CameraObservation(
      path: path,
      mimeType: mimeType,
      source: source,
      requestID: requestID,
      presentation: presentation
    ))
    if cameraObservationDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: cameraObservationDelayNanoseconds)
    }
    return cameraObservationResponse
  }

  func senseCatalog(
    senses _: [PullSenseDescriptor],
    requestID: String?
  ) async throws -> BrainToolResponse {
    senseCatalogRequests.append(requestID)
    return toolResponse
  }

  func pullSenseStatus(
    sense: String,
    direction: PullSenseDirection,
    status: PullSenseTerminalStatus,
    requestID: String?,
    timeoutMS: Int?,
    reason: String,
    availability: String?,
    permissionState: String?,
    terminal: Bool
  ) async throws -> BrainToolResponse {
    if let pullSenseStatusError {
      throw pullSenseStatusError
    }
    pullSenseStatuses.append(PullSenseStatusCall(
      sense: sense,
      direction: direction,
      status: status,
      requestID: requestID,
      timeoutMS: timeoutMS,
      reason: reason,
      availability: availability,
      permissionState: permissionState,
      terminal: terminal
    ))
    return toolResponse
  }

  func capabilityStatus(
    capability _: String,
    status _: String,
    requestID _: String?,
    pendingSince _: Date?,
    pendingElapsedMS _: Int,
    reason _: String
  ) async throws -> BrainToolResponse {
    toolResponse
  }

  func interrupt(
    userText: String,
    reason: String,
    interruptedAction: String?,
    canceledQueuedActionCount: Int
  ) async throws -> BrainToolResponse {
    interruptCalls.append((
      userText: userText,
      reason: reason,
      interruptedAction: interruptedAction,
      canceledCount: canceledQueuedActionCount
    ))
    return toolResponse
  }

  func sendText(
    _ text: String,
    source: LanguageInputSource,
    attachments: [[String: JSONValue]],
    stimulusContext: StimulusContext?
  ) async throws -> BrainTextResponse {
    textCalls.append(.init(
      text: text,
      source: source,
      attachments: attachments,
      stimulusContext: stimulusContext
    ))
    fulfillTextCallContinuations()
    if textCalls.count <= blockedTextCallCount {
      await withCheckedContinuation { continuation in
        textCallBarrierContinuations.append(continuation)
      }
    }
    return textResponse
  }

  func sendEmojiReaction(
    emoji: String,
    utteranceText: String,
    speakerLabel: String,
    utteranceEventID: String?
  ) async throws -> BrainTextResponse {
    emojiReactionCalls.append(.init(
      emoji: emoji,
      utteranceText: utteranceText,
      speakerLabel: speakerLabel,
      utteranceEventID: utteranceEventID
    ))
    return textResponse
  }

  func resumeBlockedTextSends() {
    let continuations = textCallBarrierContinuations
    textCallBarrierContinuations = []
    for continuation in continuations {
      continuation.resume()
    }
  }

  func requestDreamTime(prompt _: String?) async throws -> BrainMailboxResponse {
    BrainMailboxResponse(
      toolName: "request_dream_time",
      item: mailboxItems.first ?? Self.fixtureMailboxItem(),
      metadata: [:]
    )
  }

  func brainMode() async throws -> BrainModeResponse {
    BrainModeResponse(toolName: "brain_mode", mode: brainModeValue, metadata: ["brain_mode": brainModeValue])
  }

  func autonomyTick() async throws -> BrainToolResponse {
    toolCalls.append(ToolCall(name: "autonomy_tick", arguments: [:]))
    return toolResponse
  }

  func readModelsSnapshot() async throws -> BrainReadModelsSnapshotResponse {
    BrainReadModelsSnapshotResponse(
      toolName: "read_models_snapshot",
      readModels: .object(["brain_mode": .string(brainModeValue)]),
      metadata: ["brain_mode": brainModeValue]
    )
  }

  func mailboxList() async throws -> BrainMailboxListResponse {
    mailboxListCallCount += 1
    return BrainMailboxListResponse(toolName: "mailbox_list", items: mailboxItems, metadata: [:])
  }

  func mailboxMarkRead(mailboxID: String) async throws -> BrainMailboxListResponse {
    mailboxMarkReadIDs.append(mailboxID)
    return BrainMailboxListResponse(toolName: "mailbox_mark_read", items: mailboxItems, metadata: [:])
  }

  func exportBrain(to fileURL: URL) async throws -> BrainArchiveResponse {
    toolCalls.append(ToolCall(
      name: "export_brain",
      arguments: ["brain_file_path": .string(fileURL.path)]
    ))
    return BrainArchiveResponse(toolName: "export_brain", manifest: Self.fixtureArchiveManifest(), metadata: [:])
  }

  func importBrain(
    from fileURL: URL,
    brainID: String?,
    brainRoot: URL,
    hostID: String?
  ) async throws -> BrainArchiveResponse {
    var arguments: [String: JSONValue] = [
      "brain_file_path": .string(fileURL.path),
      "brain_root": .string(brainRoot.path),
    ]
    if let brainID {
      arguments["brain_id"] = .string(brainID)
    }
    if let hostID {
      arguments["host_id"] = .string(hostID)
    }
    toolCalls.append(ToolCall(name: "import_brain", arguments: arguments))
    return BrainArchiveResponse(toolName: "import_brain", manifest: Self.fixtureArchiveManifest(), metadata: [:])
  }

  private static func fixtureMailboxItem() -> BrainMailboxItem {
    BrainMailboxItem(
      mailboxID: "mail_fixture",
      kind: "DreamMail",
      title: "Fixture dream",
      text: "A fixture dream arrived.",
      imageArtifactID: nil,
      imageSpecJSON: "",
      wakingThought: "",
      visibleLesson: "",
      debugDetails: "",
      sourceEventIDs: [],
      sourceDreamID: "dream_fixture",
      createdAtMS: 1_782_515_600_000
    )
  }

  private static func fixtureArchiveManifest() -> JSONValue {
    .object([
      "brain_id": .string("fixture-brain"),
      "schema_version": .number(3),
      "component_count": .number(0),
    ])
  }

  func waitForTextCallCount(_ minimumCount: Int) async -> [TextCall] {
    guard textCalls.count < minimumCount else { return textCalls }

    return await withCheckedContinuation { continuation in
      textCallContinuations.append((minimumCount, continuation))
    }
  }

  func waitForExperienceEventCallCount(_ minimumCount: Int) async -> [ToolCall] {
    guard sendExperienceEventCalls.count < minimumCount else { return sendExperienceEventCalls }

    return await withCheckedContinuation { continuation in
      experienceEventCallContinuations.append((minimumCount, continuation))
    }
  }

  private func fulfillTextCallContinuations() {
    let completedCalls = textCalls
    var pendingContinuations: [(minimumCount: Int, continuation: CheckedContinuation<[TextCall], Never>)] = []

    for waiter in textCallContinuations {
      if completedCalls.count >= waiter.minimumCount {
        waiter.continuation.resume(returning: completedCalls)
      } else {
        pendingContinuations.append(waiter)
      }
    }

    textCallContinuations = pendingContinuations
  }

  private func fulfillExperienceEventCallContinuations() {
    let completedCalls = sendExperienceEventCalls
    var pendingContinuations: [(minimumCount: Int, continuation: CheckedContinuation<[ToolCall], Never>)] = []

    for waiter in experienceEventCallContinuations {
      if completedCalls.count >= waiter.minimumCount {
        waiter.continuation.resume(returning: completedCalls)
      } else {
        pendingContinuations.append(waiter)
      }
    }

    experienceEventCallContinuations = pendingContinuations
  }

}

private final class FakeBrainCloudArchiveStore: BrainCloudArchiveStore {
  var manifests: [String: BrainCloudManifest] = [:]
  var archives: [String: Data] = [:]
  var uploads: [BrainCloudManifest] = []
  var loadDelayNanoseconds: UInt64
  var error: Error?

  init(loadDelayNanoseconds: UInt64 = 0, error: Error? = nil) {
    self.loadDelayNanoseconds = loadDelayNanoseconds
    self.error = error
  }

  func listManifests() async throws -> [BrainCloudManifest] {
    if let error {
      throw error
    }
    return Array(manifests.values)
  }

  func loadManifest(brainID: String) async throws -> BrainCloudManifest? {
    if loadDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: loadDelayNanoseconds)
    }
    if let error {
      throw error
    }
    return manifests[brainID]
  }

  func importState(for manifest: BrainCloudManifest) async throws -> BrainCloudImportState {
    if let error {
      throw error
    }
    guard let archive = archives[manifest.brainID] else {
      return .syncing
    }
    guard BrainCloudArchive.sha256Hex(archive) == manifest.archiveHash else {
      return .invalid("The archive checksum does not match its manifest.")
    }
    do {
      try BrainCloudArchive.validateArchiveData(archive)
      return .available
    } catch {
      return .invalid(error.localizedDescription)
    }
  }

  func downloadArchive(brainID: String, to localURL: URL) async throws -> BrainCloudManifest {
    if let error {
      throw error
    }
    guard let manifest = manifests[brainID], let archive = archives[brainID] else {
      throw BrainSyncError.missingArchive
    }
    try archive.write(to: localURL, options: .atomic)
    return manifest
  }

  func uploadArchive(from localURL: URL, manifest: BrainCloudManifest) async throws {
    if let error {
      throw error
    }
    manifests[manifest.brainID] = manifest
    archives[manifest.brainID] = try Data(contentsOf: localURL)
    uploads.append(manifest)
  }
}

@MainActor
private final class MockBrainSpeechNotificationClient: BrainSpeechNotificationClient {
  var authorizationStatusResult: BrainSpeechNotificationAuthorizationStatus = .authorized
  var postCalls: [(brainID: String, brainName: String, text: String)] = []

  func requestAuthorizationIfNeeded() async -> BrainSpeechNotificationAuthorizationStatus {
    authorizationStatusResult
  }

  func authorizationStatus() async -> BrainSpeechNotificationAuthorizationStatus {
    authorizationStatusResult
  }

  func postIfAuthorized(brainID: String, brainName: String, text: String) async -> Bool {
    guard authorizationStatusResult == .authorized
      || authorizationStatusResult == .provisional
      || authorizationStatusResult == .ephemeral else {
      return false
    }
    postCalls.append((brainID: brainID, brainName: brainName, text: text))
    return true
  }

  func registerDelegateIfNeeded() {}
}

#if os(macOS)
private final class AvatarKitMockImageGenerator: AvatarKitImageGenerating, @unchecked Sendable {
  let responses: [AvatarKitAssetKind: Data]
  private(set) var prompts: [String] = []

  init(responses: [AvatarKitAssetKind: Data]) {
    self.responses = responses
  }

  func generate(
    prompt: String,
    outputDirectory: URL,
    referenceImage: HostGeneratedImage?
  ) async throws -> HostGeneratedImage {
    prompts.append(prompt)
    let kind = AvatarKitAssetKind.allCases.first { prompt.contains($0.generateOnlyLine) }
      ?? .baseHead
    guard let data = responses[kind] else {
      throw AvatarKitGenerationError.generationFailed("Missing mock image for \(kind.rawValue)")
    }
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let path = outputDirectory.appendingPathComponent("\(kind.rawValue)-\(prompts.count).png")
    try data.write(to: path, options: .atomic)
    return HostGeneratedImage(path: path.path, mimeType: "image/png")
  }
}

private final class AvatarKitRetryMockImageGenerator: AvatarKitImageGenerating, @unchecked Sendable {
  let opaqueData: Data
  let transparentData: Data
  private(set) var prompts: [String] = []
  private(set) var referencePaths: [String?] = []

  init(opaqueData: Data, transparentData: Data) {
    self.opaqueData = opaqueData
    self.transparentData = transparentData
  }

  func generate(
    prompt: String,
    outputDirectory: URL,
    referenceImage: HostGeneratedImage?
  ) async throws -> HostGeneratedImage {
    prompts.append(prompt)
    referencePaths.append(referenceImage?.path)
    let kind = AvatarKitAssetKind.allCases.first { prompt.contains($0.generateOnlyLine) }
      ?? .baseHead
    let data = referenceImage == nil ? opaqueData : transparentData
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let path = outputDirectory.appendingPathComponent("\(kind.rawValue)-\(prompts.count).png")
    try data.write(to: path, options: .atomic)
    return HostGeneratedImage(path: path.path, mimeType: "image/png")
  }
}

private final class AvatarKitPerKindMockImageGenerator: AvatarKitImageGenerating, @unchecked Sendable {
  let initial: [AvatarKitAssetKind: Data]
  let replacements: [AvatarKitAssetKind: Data]
  private var counts: [AvatarKitAssetKind: Int] = [:]

  init(initial: [AvatarKitAssetKind: Data], replacements: [AvatarKitAssetKind: Data]) {
    self.initial = initial
    self.replacements = replacements
  }

  func generationCount(for kind: AvatarKitAssetKind) -> Int {
    counts[kind, default: 0]
  }

  func generate(
    prompt: String,
    outputDirectory: URL,
    referenceImage: HostGeneratedImage?
  ) async throws -> HostGeneratedImage {
    let kind = AvatarKitAssetKind.allCases.first { prompt.contains($0.generateOnlyLine) }
      ?? .baseHead
    let count = counts[kind, default: 0] + 1
    counts[kind] = count
    let data: Data
    if count == 1 {
      guard let initialData = initial[kind] else {
        throw AvatarKitGenerationError.generationFailed("Missing initial mock for \(kind.rawValue)")
      }
      data = initialData
    } else {
      guard let replacement = replacements[kind] ?? initial[kind] else {
        throw AvatarKitGenerationError.generationFailed("Missing replacement mock for \(kind.rawValue)")
      }
      data = replacement
    }
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let path = outputDirectory.appendingPathComponent("\(kind.rawValue)-\(count).png")
    try data.write(to: path, options: .atomic)
    return HostGeneratedImage(path: path.path, mimeType: "image/png")
  }
}

private final class AvatarKitMockVisionClient: AvatarKitVisionCompleting, @unchecked Sendable {
  let response: String
  private(set) var imagePaths: [String] = []

  init(response: String) {
    self.response = response
  }

  func complete(_ request: HostVisionCompletionRequest) async throws -> HostVisionCompletionResponse {
    imagePaths = request.imagePaths
    return HostVisionCompletionResponse(text: response, provider: .openAI)
  }
}
#endif
