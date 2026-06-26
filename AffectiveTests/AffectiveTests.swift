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
        "schema_version": 2,
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

  @MainActor
  func testSpecialPokeCuriosityIdentifiesUnknownThenEnrollsAfterIntroduction() async throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
      {
        "schema_version": 2,
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
    XCTAssertEqual(model.commandEntries.last { $0.title == "Curiosity" }?.body, "Curious after a poke; trying to identify the person nearby.")
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
  }

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
          "output_text": #"```json { "commands": [], "conversation_done": false } ```"#,
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
      #"{"commands":[],"conversation_done":false}"#
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

    try await withConnectedCore(core) {
      let shortTouch = try await core.shortTouch()
      XCTAssertNotNil(shortTouch.metadata["request_id"])

      let longTouch = try await core.longTouch()
      XCTAssertNotNil(longTouch.metadata["request_id"])

      let poke = try await core.pokeSequence([
        PokePulse(pressMilliseconds: 25, pauseBeforeMilliseconds: 0)
      ])
      XCTAssertNotNil(poke.metadata["request_id"])

      let tool = try await core.sendEvent(actionRequestEvent(
        actionID: "list-reminders-e2e",
        action: "list_reminders",
        arguments: [:]
      ))
      XCTAssertNotNil(tool.metadata["request_id"])

      do {
        let typedText = try await core.sendText("capability e2e typed text")
        XCTAssertNotNil(typedText.metadata["request_id"])
      } catch {
        let description = String(describing: error)
        guard description.contains("FrontendCaptureRequested") else { throw error }
        // The coverage probe only verifies the dispatch route. If the brain
        // elects to pull an awaited sense during that route, the host should not
        // synthesize a chat fallback for this test.
      }

      let orientation = try await core.orientationObservation(
        OrientationQueryProvider.classify(x: 0.02, y: 0.01, z: -0.99)
      )
      XCTAssertNotNil(orientation.metadata["request_id"])

      let imageURL = await brain.rootURL.appendingPathComponent("capability-e2e.png")
      try Self.tinyPNGData.write(to: imageURL, options: .atomic)
      let camera = try await core.cameraObservation(
        path: imageURL.path,
        mimeType: "image/png",
        source: "capability_e2e",
        requestID: "capability-e2e-camera"
      )
      XCTAssertNotNil(camera.metadata["request_id"])

      let state = try await core.refreshState()
      XCTAssertNotNil(state.metadata["request_id"])
      XCTAssertFalse(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
//    guard ProcessInfo.processInfo.environment["AFFECTIVE_RUN_CAMERA_HARDWARE_E2E"] == "1" else {
//      throw XCTSkip("Set AFFECTIVE_RUN_CAMERA_HARDWARE_E2E=1 to run the live camera hardware capture check.")
//    }

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
    XCTAssertEqual(model.commandEntries.last?.title, "camera sense")
    XCTAssertEqual(model.commandEntries.last?.body, "")
    XCTAssertEqual(model.commandEntries.last?.metadata["sense"], "camera")
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
    let failure = try XCTUnwrap(model.commandEntries.last { $0.title == "camera sense timed out" })
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
    let failure = try XCTUnwrap(model.commandEntries.last { $0.title == "camera sense failed" })
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
    XCTAssertNotNil(model.commandEntries.last { $0.title == "camera sense failed" })
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
    XCTAssertNotNil(model.commandEntries.last { $0.title == "camera sense" })
    XCTAssertNotNil(model.commandEntries.last { $0.title == "sense_observation" })
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

    let entry = try XCTUnwrap(model.commandEntries.last { $0.title == "short_touch" })
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

    let entry = try XCTUnwrap(model.commandEntries.last { $0.title == "short_touch" })
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

    let entry = try XCTUnwrap(model.commandEntries.last { $0.title == "short_touch" })
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

    let observations = await core.cameraObservations
    XCTAssertEqual(observations.last?.requestID, "typed-text-capture")
    XCTAssertEqual(observations.last?.presentation, .internalOnly)
    XCTAssertEqual(model.chatEntries.filter { $0.body == "Hello from the first turn." }.count, 1)
    XCTAssertNil(model.chatEntries.last { $0.body == "I can see the captured frame now." })
    XCTAssertNotNil(model.commandEntries.last { $0.title == "sense_observation" })
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
    XCTAssertNotNil(model.commandEntries.last { $0.title == "orientation sense" })
    XCTAssertNotNil(model.commandEntries.last { $0.title == "sense_observation" })
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
    XCTAssertEqual(model.commandEntries.last?.metadata["mirror_to_chat"], "false")
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
    XCTAssertEqual(model.commandEntries.last?.title, "motion gesture")

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
    XCTAssertNotNil(model.commandEntries.last { $0.title == "pushed_motion_gesture" })
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
      source: "speech_transcript",
      metadata: ["speaker_name": "Mira"]
    )

    let turn = try XCTUnwrap(model.conversationContextSnapshot().recentTurns.last)
    XCTAssertEqual(turn.speakerRole, "other")
    XCTAssertEqual(turn.speakerName, "Mira")
    XCTAssertEqual(turn.eventArguments["speaker_name"], .string("Mira"))
  }

  @MainActor
  func testFallbackBrainResponseDoesNotRecordConversationTurn() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "experience", text: "Fallback hello.", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.sendTextToBrain("Hello?", speakResponse: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertNil(turns.last { $0.speakerRole == "self" && $0.text == "Fallback hello." })
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
  func testSpeechOnlyBrainEventRecordsConversationTurnOnce() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    let result = await model.applyCoreEvents([
      speechRequestedEvent(text: "Speech-only hello.")
    ], mirrorChatMessages: true, speak: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertTrue(result.didRecordBrainTurn)
    XCTAssertEqual(turns.last?.speakerRole, "self")
    XCTAssertEqual(turns.last?.source, "action_request")
    XCTAssertEqual(turns.filter { $0.text == "Speech-only hello." }.count, 1)
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
    XCTAssertEqual(model.commandEntries.last?.title, "facial expression")
    XCTAssertEqual(model.commandEntries.last?.body, "bright eyes / small smile")
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
    XCTAssertEqual(model.commandEntries.last?.title, "facial expression")
    XCTAssertEqual(model.commandEntries.last?.body, "bright eyes / small smile")
  }

  @MainActor
  func testGenericBrainEventTitleUsesFactDatabaseBrainName() async throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 2,
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
    XCTAssertEqual(model.chatEntries.last?.title, "Otto")
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
    ], mirrorChatMessages: true, speak: model.brainVoiceEnabled)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertFalse(result.didRequestSpeech)
    XCTAssertEqual(model.chatEntries.last?.body, "Hello from the core.")
    XCTAssertFalse(model.commandEntries.contains { entry in
      entry.title == "speech output" && entry.body == "apple_speech=true"
    })
  }

  @MainActor
  func testKnownPersonFactSubjectDoesNotBecomeBrainSenderName() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 2,
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
  func testNestedFactIdentityProvidesBrainSenderName() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 2,
          "identity": {
            "preferred_name": "Otto"
          },
          "traces": [],
          "beliefs": [],
          "subjects": [],
          "artifacts": [],
          "dreams": []
        }
        """
    )
    let model = AffectiveViewModel(brain: brain)

    XCTAssertEqual(model.brainSenderName, "Otto")
  }

  @MainActor
  func testSelfMarkedSubjectProvidesBrainSenderName() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 2,
          "traces": [],
          "beliefs": [],
          "subjects": [
            {
              "subject_id": "self",
              "display_name": "Otto"
            }
          ],
          "artifacts": [],
          "dreams": []
        }
        """
    )
    let model = AffectiveViewModel(brain: brain)

    XCTAssertEqual(model.brainSenderName, "Otto")
  }

  @MainActor
  func testBrainPrefixedSubjectProvidesBrainSenderName() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: """
        {
          "schema_version": 2,
          "traces": [],
          "beliefs": [],
          "subjects": [
            {
              "subject_id": "brain_primary",
              "name": "Otto"
            }
          ],
          "artifacts": [],
          "dreams": []
        }
        """
    )
    let model = AffectiveViewModel(brain: brain)

    XCTAssertEqual(model.brainSenderName, "Otto")
  }

  @MainActor
  func testBrainSenderNameIgnoresProfileDisplayNameFallback() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    _ = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Still here.")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertEqual(model.chatEntries.last?.title, "A brain")
  }

  @MainActor
  func testBoredomSenseOnlyEmitsWhenAwakeIdleAndAutonomyIsOn() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isBrainConnected = true
    model.autonomyMode = "on"
    model.lastHostStimulusAt = Date(timeIntervalSinceNow: -700)

    XCTAssertTrue(model.canEmitBoredomStimulus(intervalSeconds: 600))

    model.autonomyMode = "off"
    XCTAssertFalse(model.canEmitBoredomStimulus(intervalSeconds: 600))

    model.autonomyMode = "on"
    model.hostPipelineHold = .speechOutput
    XCTAssertFalse(model.canEmitBoredomStimulus(intervalSeconds: 600))
  }

  @MainActor
  func testBoredomStimulusUsesPatientInternalContext() throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    model.isBrainConnected = true
    model.autonomyMode = "on"

    let text = model.boredomStimulusText(intervalSeconds: 600)
    let context = model.currentStimulusContext(kind: "boredom")

    XCTAssertTrue(text.contains("Stay patient"))
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
    XCTAssertEqual(model.commandEntries.last?.title, "Learning your name")
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

  func testBrainToolResponseParsesSpokenCommandResults() throws {
    let response = BrainToolResponse(
      toolName: "say",
      rawText: #"""
        {
          "command": "say",
          "observation": "",
          "spoken_text": "I found one memory.",
          "ended_with_speech": true,
          "interrupted_by": null
        }
        """#)

    XCTAssertEqual(response.text, "I found one memory.")
    XCTAssertTrue(response.shouldSpeak)
    XCTAssertEqual(response.metadata["command"], "say")
    XCTAssertEqual(response.metadata["display_source"], "spoken_text")
    XCTAssertEqual(response.metadata["spoken_text_present"], "true")
  }

  func testConversationTurnPayloadRejectsPlainText() throws {
    XCTAssertNil(ConversationTurnPayload.decode(from: "I heard you say: hello"))
  }

  func testBrainToolResponseUsesObservationForDirectSilentCommandResults() throws {
    let response = BrainToolResponse(
      toolName: "recall_memory",
      rawText: #"""
        {
          "command": "recall_memory",
          "observation": "memory: Papa taught me to solder patiently.",
          "spoken_text": null,
          "ended_with_speech": false,
          "interrupted_by": null
        }
        """#)

    XCTAssertEqual(response.text, "memory: Papa taught me to solder patiently.")
    XCTAssertFalse(response.shouldSpeak)
    XCTAssertEqual(response.metadata["display_source"], "observation")
    XCTAssertEqual(response.metadata["observation_present"], "true")
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

    let response = BrainToolResponse(toolName: "recall_memory", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "Here is what I remember.")
    XCTAssertTrue(response.shouldSpeak)
    XCTAssertEqual(response.events.count, 4)
    XCTAssertEqual(response.metadata["display_source"], "event_envelope")
    XCTAssertEqual(response.metadata["event_types"], "control,action_request,expression,control")
    XCTAssertEqual(response.metadata["budget_max_bytes"], "16384")
  }

  func testBrainToolResponseIgnoresLegacyEnvelopeCommandSummary() throws {
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

    let response = BrainToolResponse(toolName: "recall_memory", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "")
    XCTAssertEqual(response.metadata["display_source"], "empty")
    XCTAssertEqual(response.metadata["display_text_length"], "0")
  }

  func testBrainToolResponseDecodesDirectTouchCommandResult() throws {
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

    XCTAssertEqual(response.text, "touch stimulus received")
    XCTAssertEqual(response.metadata["display_source"], "result_summary")
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
        "event_type": .string("experience"),
        "summary": .string("{\"user_text\":\"What do you remember about soldering?\",\"spoken_text\":\"I found one memory about soldering.\",\"user_summary\":\"Asked for soldering memories.\",\"brain_summary\":\"Shared a soldering memory.\",\"interrupted_by\":null}"),
        "raw_result": .bool(true),
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
    XCTAssertNotNil(success.conversationTurnJSON)
    XCTAssertEqual(success.budget?.maxBytes, 16384)

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
        status: "available",
        reason: nil,
        permissionState: "granted"
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
      .actionRequest(BrainActionRequestPayload(
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
      .memoryRequest(BrainMemoryRequestPayload(
        operation: .recall,
        layers: [.working, .episodic],
        query: "hello",
        text: nil,
        tags: ["conversation"]
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

  func testMissingRequiredFileFailsCoreValidation() throws {
    let brain = try makeBrain()
    try FileManager.default.removeItem(at: brain.runtimeOptionsURL)

    XCTAssertThrowsError(try brain.validateForCoreConnection()) { error in
      XCTAssertEqual(error as? BrainValidationError, .missingFile("runtime_options.json"))
    }
  }

  func testInvalidEventsJSONLFailsCoreValidation() throws {
    let brain = try makeBrain(events: #"{"ok": true}"# + "\nnot-json\n")

    XCTAssertThrowsError(try brain.validateForCoreConnection()) { error in
      guard case .invalidJSON("events.jsonl", let detail) = error as? BrainValidationError else {
        return XCTFail("Expected invalid events JSONL, got \(error)")
      }
      XCTAssertTrue(detail.contains("line 2"))
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

  func testAvatarManifestClipFallsBackToCanvas() throws {
    let manifest = BrainAvatarManifest(
      canvas: .init(width: 640, height: 360),
      layers: [],
      rootURL: FileManager.default.temporaryDirectory
    )

    XCTAssertNil(manifest.clip)
    XCTAssertEqual(manifest.effectiveClip, .init(x: 0, y: 0, width: 640, height: 360))
  }

  func testAvatarAtlasPlaybackResolvesExpressionAndLayerFallbacks() throws {
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

    let fallbackEyes = manifest.atlasPlayback(for: eyesLayer, expressionID: "missing")
    XCTAssertEqual(fallbackEyes.frameIndex(at: .now), 7)

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

  @MainActor func testAppIntentBridgeFallsBackToLastOpenedBrain() throws {
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

    let requested = AffectiveAppIntentBridge.requestedBrain(
      from: [first, second],
      requestedID: nil,
      defaults: defaults
    )

    XCTAssertEqual(requested, second)
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
  func testBrainLibraryImportsSameArchiveWithUniqueUUIDIDs() throws {
    let source = try makeBrain()
    let checkpoint = try BrainCheckpointArchive.createCheckpoint(
      for: source,
      schemaVersion: 1,
      deviceID: "test-device",
      revision: 1,
      includeBiometricData: true
    )
    defer { try? FileManager.default.removeItem(at: checkpoint.archiveURL.deletingLastPathComponent()) }
    let library = BrainLibrary()

    let first = try library.importBrainArchive(from: checkpoint.archiveURL)
    let second = try library.importBrainArchive(from: checkpoint.archiveURL)
    temporaryRoots.append(first.rootURL)
    temporaryRoots.append(second.rootURL)

    XCTAssertEqual(first.displayName, "Test Brain")
    XCTAssertEqual(second.displayName, "Test Brain")
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotEqual(first.id, source.id)
    XCTAssertNotEqual(second.id, source.id)
    XCTAssertNotNil(UUID(uuidString: first.id))
    XCTAssertNotNil(UUID(uuidString: second.id))
  }

  @MainActor
  func testBrainSyncWithoutConfiguredBrainDoesNothing() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudCheckpointStore()
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
    let store = FakeBrainCloudCheckpointStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let remoteBrain = try makeBrain(
      profile: #"{"schema_version":1,"display_name":"Remote Brain"}"#,
      displayName: "Remote Brain"
    )
    let remoteCheckpoint = try BrainCheckpointArchive.createCheckpoint(
      for: remoteBrain,
      schemaVersion: 1,
      deviceID: "cloud-device",
      revision: 1,
      includeBiometricData: true
    )
    defer { try? FileManager.default.removeItem(at: remoteCheckpoint.archiveURL.deletingLastPathComponent()) }
    let remoteManifest = remoteCheckpoint.manifest
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
    store.archives[remoteManifest.brainID] = try Data(contentsOf: remoteCheckpoint.archiveURL)

    manager.refreshCloudImports(installedBrains: [brain])
    try await waitForCloudImportCount(1, manager: manager)

    XCTAssertEqual(manager.importableCloudBrains.first?.brainID, remoteManifest.brainID)
    XCTAssertTrue(manager.unavailableCloudImports.isEmpty)
  }

  @MainActor
  func testCloudImportsAreHiddenWhenNothingIsAvailable() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudCheckpointStore()
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
    let store = FakeBrainCloudCheckpointStore()
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
    let store = FakeBrainCloudCheckpointStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    let archive = Data("not a checkpoint".utf8)
    let manifest = BrainCloudManifest(
      brainID: "invalid-brain",
      displayName: "Invalid Brain",
      schemaVersion: 1,
      archiveHash: BrainCheckpointArchive.sha256Hex(archive),
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
    let store = FakeBrainCloudCheckpointStore()
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
    } catch BrainSyncError.missingCheckpoint {
      XCTAssertEqual(
        BrainSyncError.missingCheckpoint.recoverySuggestion,
        "Wait for iCloud Drive to finish syncing, then try Import Brain (iCloud) again. If it still is not available, export the brain from the other device and use Import Brain."
      )
    } catch {
      XCTFail("Expected missing checkpoint error, got \(error)")
    }
  }

  @MainActor
  func testBrainSyncUploadsWhenNoCloudCheckpointExists() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudCheckpointStore()
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
    let store = FakeBrainCloudCheckpointStore(loadDelayNanoseconds: 200_000_000)
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncState(.checking, manager: manager, brain: brain)

    XCTAssertFalse(manager.canOpen(brain))
  }

  @MainActor
  func testBrainSyncFailureDoesNotDeleteLocalBrain() async throws {
    let brain = try makeBrain()
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudCheckpointStore(error: CocoaError(.fileReadNoSuchFile))
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
    let store = FakeBrainCloudCheckpointStore()
    let manager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")

    manager.selectBrainForSync(brain)
    try await waitForSyncState(.synced, manager: manager, brain: brain)

    try "local change".write(to: brain.rootURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
    let cloudBrain = try makeBrain(profile: #"{"schema_version":1,"display_name":"Cloud Brain"}"#)
    let cloudCheckpoint = try BrainCheckpointArchive.createCheckpoint(
      for: cloudBrain,
      schemaVersion: 1,
      deviceID: "cloud-device",
      revision: 2,
      includeBiometricData: true
    )
    defer { try? FileManager.default.removeItem(at: cloudCheckpoint.archiveURL.deletingLastPathComponent()) }
    store.manifests[brain.id] = BrainCloudManifest(
      brainID: brain.id,
      displayName: brain.displayName,
      schemaVersion: cloudCheckpoint.manifest.schemaVersion,
      archiveHash: cloudCheckpoint.manifest.archiveHash,
      createdAt: cloudCheckpoint.manifest.createdAt,
      modifiedAt: cloudCheckpoint.manifest.modifiedAt,
      uploadedAt: cloudCheckpoint.manifest.uploadedAt,
      deviceID: cloudCheckpoint.manifest.deviceID,
      revision: 2
    )
    store.archives[brain.id] = try Data(contentsOf: cloudCheckpoint.archiveURL)

    manager.syncNow(brain)
    try await waitForSyncState(.conflict, manager: manager, brain: brain)

    XCTAssertFalse(manager.canOpen(brain))
  }

  func testBrainCheckpointRestoresNestedFilesAndExcludesSecrets() throws {
    let brain = try makeBrain()
    let nested = brain.rootURL.appendingPathComponent("generated", isDirectory: true)
      .appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "durable".write(to: nested.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: brain.rootURL.appendingPathComponent("secrets.json"), atomically: true, encoding: .utf8)

    let checkpoint = try BrainCheckpointArchive.createCheckpoint(
      for: brain,
      schemaVersion: 1,
      deviceID: "test-device",
      revision: 1,
      includeBiometricData: true
    )
    defer { try? FileManager.default.removeItem(at: checkpoint.archiveURL.deletingLastPathComponent()) }

    let restored = FileManager.default.temporaryDirectory
      .appendingPathComponent("AffectiveRestored-\(UUID().uuidString)", isDirectory: true)
    temporaryRoots.append(restored)
    try BrainCheckpointArchive.restoreCheckpoint(at: checkpoint.archiveURL, to: restored)

    XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("generated/notes/one.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("secrets.json").path))
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

  func testBrainCheckpointExcludesBiometricsWhenPolicyOptOut() throws {
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
      "schema_version": 2,
      "subjects": [
        {
          "subject_id": "person-1",
          "display_name": "User",
          "notes": "friend",
          "biometric_records": [{"embedding_id": "emb_1", "quality_score": 0.91}],
          "representative_image_path": "memory/faces/person-1.jpg",
          "representative_quality_score": 0.91
        }
      ]
    }
    """)

    let checkpoint = try BrainCheckpointArchive.createCheckpoint(
      for: brain,
      schemaVersion: 1,
      deviceID: "test-device",
      revision: 1,
      includeBiometricData: false
    )
    defer { try? FileManager.default.removeItem(at: checkpoint.archiveURL.deletingLastPathComponent()) }

    let archiveObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint.archiveURL)) as? [String: Any])
    XCTAssertEqual(archiveObject["containsBiometricData"] as? Bool, false)
    let components = try XCTUnwrap(archiveObject["components"] as? [[String: Any]])
    let paths = Set(components.compactMap { $0["path"] as? String })

    XCTAssertFalse(paths.contains("memory/face_embeddings"))
    XCTAssertFalse(paths.contains("memory/face_embeddings/user.embedding"))
    XCTAssertFalse(paths.contains("memory/biometric_identities.json"))
    XCTAssertTrue(paths.contains("export_manifest.json"))

    let peopleData = try XCTUnwrap(archiveComponentData("memory/people.sqlite", in: components))
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

  func testBrainCheckpointIncludesBiometricsWhenPolicyOptIn() throws {
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
      "schema_version": 2,
      "subjects": [
        {
          "subject_id": "person-1",
          "display_name": "User",
          "biometric_records": [{"embedding_id": "emb_1", "quality_score": 0.91}],
          "representative_image_path": "memory/faces/person-1.jpg",
          "representative_quality_score": 0.91
        }
      ]
    }
    """)

    let checkpoint = try BrainCheckpointArchive.createCheckpoint(
      for: brain,
      schemaVersion: 1,
      deviceID: "test-device",
      revision: 1,
      includeBiometricData: true
    )
    defer { try? FileManager.default.removeItem(at: checkpoint.archiveURL.deletingLastPathComponent()) }

    let archiveObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint.archiveURL)) as? [String: Any])
    XCTAssertEqual(archiveObject["containsBiometricData"] as? Bool, true)
    let components = try XCTUnwrap(archiveObject["components"] as? [[String: Any]])
    let paths = Set(components.compactMap { $0["path"] as? String })

    XCTAssertTrue(paths.contains("memory/face_embeddings"))
    XCTAssertTrue(paths.contains("memory/face_embeddings/user.embedding"))
    XCTAssertTrue(paths.contains("memory/biometric_identities.json"))

    let peopleData = try XCTUnwrap(archiveComponentData("memory/people.sqlite", in: components))
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
  func testBrainSyncCheckpointUsesSharedBiometricExportToggle() async throws {
    let defaults = try makeUserDefaults()
    let store = FakeBrainCloudCheckpointStore()
    let excludedBrain = try makeBrain()
    try "template".write(
      to: excludedBrain.faceEmbeddingsURL.appendingPathComponent("excluded.embedding"),
      atomically: true,
      encoding: .utf8
    )
    try writeCognitiveStore(at: excludedBrain.memoryDatabaseURL, dataJSON: """
    {"schema_version":2,"subjects":[{"subject_id":"person-1","display_name":"User","biometric_records":[{"embedding_id":"emb_1","quality_score":0.91}],"representative_image_path":"memory/faces/person-1.jpg","representative_quality_score":0.91}]}
    """)

    let excludedManager = BrainSyncManager(store: store, userDefaults: defaults, deviceID: "test-device")
    excludedManager.selectBrainForSync(excludedBrain)
    try await waitForSyncState(.synced, manager: excludedManager, brain: excludedBrain)

    let excludedArchive = try XCTUnwrap(store.archives[excludedBrain.id])
    let excludedComponents = try archiveComponents(from: excludedArchive)
    let excludedPaths = Set(excludedComponents.compactMap { $0["path"] as? String })
    XCTAssertFalse(excludedPaths.contains("memory/face_embeddings/excluded.embedding"))
    XCTAssertEqual(try archiveContainsBiometricData(excludedArchive), false)

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
    let includedComponents = try archiveComponents(from: includedArchive)
    let includedPaths = Set(includedComponents.compactMap { $0["path"] as? String })
    XCTAssertTrue(includedPaths.contains("memory/face_embeddings/included.embedding"))
    XCTAssertEqual(try archiveContainsBiometricData(includedArchive), true)
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

  func testDreamReportCollectorParsesCognitiveStoreDreamsAndArtifacts() throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: cognitiveFixtureJSON(dreamID: "dream_1", artifactPath: "generated/images/dream.png")
    )

    let drafts = try DreamReportCollector.loadDrafts(brain: brain)

    XCTAssertEqual(drafts.count, 1)
    let draft = try XCTUnwrap(drafts.first)
    XCTAssertEqual(draft.dreamID, "dream_1")
    XCTAssertEqual(draft.imagePath, "generated/images/dream.png")
    XCTAssertEqual(draft.imageMimeType, "image/png")
    XCTAssertEqual(draft.imagePrompt, "Create a quiet symbolic dream image.")
    XCTAssertEqual(draft.style, "associative_synthesis")
    XCTAssertEqual(try XCTUnwrap(draft.confidence), DreamReportCollector.confidence(forHeat: 0.5), accuracy: 0.0001)
  }

  func testDreamEventReaderRecoversPromptByImagePath() throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())

    let events = try DreamEventReader.loadDreamImageEvents(from: brain.eventsURL)

    let event = try XCTUnwrap(events["generated/images/dream.png"])
    XCTAssertEqual(event.prompt, "Create a quiet symbolic dream image.")
  }

  func testDreamReportCollectionDedupesByDayAndDreamID() async throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: cognitiveFixtureJSON(dreamID: "dream_1", artifactPath: "generated/images/dream.png")
    )
    let existing = DreamReportJournal(reports: [
      DreamReportCollector.report(
        from: DreamReportDraft(
          dreamID: "dream_1",
          dayKey: "2026-06-25",
          createdAt: try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z")),
          reflection: "existing",
          heat: 0.5,
          style: "associative_synthesis",
          confidence: 0.575,
          sourceTraceIDs: ["trace_1"],
          generatedArtifactID: "artifact_dream_1",
          imagePath: "generated/images/dream.png",
          imageMimeType: "image/png",
          imagePrompt: "Create a quiet symbolic dream image."
        ),
        summary: .init(text: "Existing report.", source: "fallback")
      )
    ])

    let updated = try await DreamReportCollector.collect(
      brain: brain,
      existing: existing,
      summaryProvider: FailingDreamReportSummaryProvider()
    )

    XCTAssertEqual(updated.reports.count, 1)
    XCTAssertEqual(updated.reports.first?.summary, "Existing report.")
  }

  func testDreamReportCollectionDedupesDuplicateDreamsInSingleScan() async throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: duplicateDreamsFixtureJSON(dreamID: "dream_1", artifactPath: "generated/images/dream.png")
    )

    let updated = try await DreamReportCollector.collect(
      brain: brain,
      existing: DreamReportJournal(),
      summaryProvider: FailingDreamReportSummaryProvider()
    )

    XCTAssertEqual(updated.reports.count, 1)
    XCTAssertEqual(updated.reports.first?.dreamID, "dream_1")
  }

  func testVisibleDreamReportsArchivedFilterOnlyShowsArchivedReports() throws {
    let inbox = dreamReport(dreamID: "inbox", dayKey: "2026-06-25", isArchived: false)
    let archived = dreamReport(dreamID: "archived", dayKey: "2026-06-24", isArchived: true)

    XCTAssertTrue(AffectiveViewModel.isDreamReportVisible(inbox, showsArchived: false))
    XCTAssertFalse(AffectiveViewModel.isDreamReportVisible(archived, showsArchived: false))
    XCTAssertFalse(AffectiveViewModel.isDreamReportVisible(inbox, showsArchived: true))
    XCTAssertTrue(AffectiveViewModel.isDreamReportVisible(archived, showsArchived: true))
  }

  @MainActor
  func testDreamReportMergePreservesCurrentReadAndArchiveState() throws {
    let staleScanned = dreamReport(dreamID: "dream_1", dayKey: "2026-06-25", isRead: false, isArchived: false)
    let current = dreamReport(dreamID: "dream_1", dayKey: "2026-06-25", isRead: true, isArchived: true)
    let newScanned = dreamReport(dreamID: "dream_2", dayKey: "2026-06-26", isRead: false, isArchived: false)

    let merged = AffectiveViewModel.mergedDreamReports(scanned: [staleScanned, newScanned], current: [current])
    let dreamOne = try XCTUnwrap(merged.first { $0.dreamID == "dream_1" })
    let dreamTwo = try XCTUnwrap(merged.first { $0.dreamID == "dream_2" })

    XCTAssertTrue(dreamOne.isRead)
    XCTAssertTrue(dreamOne.isArchived)
    XCTAssertFalse(dreamTwo.isRead)
    XCTAssertFalse(dreamTwo.isArchived)
  }

  func testDreamReportJournalPersistsReadAndArchiveState() throws {
    let brain = try makeBrain()
    var report = DreamReportCollector.report(
      from: DreamReportDraft(
        dreamID: "dream_1",
        dayKey: "2026-06-25",
        createdAt: Date(timeIntervalSince1970: 1_782_437_400),
        reflection: "A memory linked to a summary.",
        heat: 0.5,
        style: "associative_synthesis",
        confidence: 0.575,
        sourceTraceIDs: ["trace_1"],
        generatedArtifactID: "artifact_dream_1",
        imagePath: "generated/images/dream.png",
        imageMimeType: "image/png",
        imagePrompt: "Create a quiet symbolic dream image."
      ),
      summary: .init(text: "A dream linked memory and summary.", source: "fallback")
    )
    report.isRead = true
    report.isArchived = true

    try DreamReportJournal(reports: [report]).write(to: brain.dreamReportsURL)
    let restored = DreamReportJournal.load(from: brain.dreamReportsURL)

    XCTAssertEqual(restored.reports.first?.isRead, true)
    XCTAssertEqual(restored.reports.first?.isArchived, true)
  }

  func testForgetTodayPrunesTodaysExperienceButKeepsOlderRecords() throws {
    let brain = try makeBrain()
    let today = "2026-06-25"
    let yesterday = "2026-06-24"

    try """
    {"event_id":"today","time":"\(today)T15:30:00Z","title":"conversation","body":"bad turn"}
    {"event_id":"older","time":"\(yesterday)T15:30:00Z","title":"conversation","body":"keep me"}
    """.write(to: brain.eventsURL, atomically: true, encoding: .utf8)

    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 2,
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

    try DreamReportJournal(reports: [
      dreamReport(dreamID: "today-dream", dayKey: today),
      dreamReport(dreamID: "older-dream", dayKey: yesterday),
    ]).write(to: brain.dreamReportsURL)

    let now = try XCTUnwrap(DreamReportDateFormatter.date(from: "\(today)T18:00:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let result = try BrainExperienceForgetter.forgetToday(in: brain, now: now, calendar: calendar)

    XCTAssertEqual(result.removedEventCount, 1)
    XCTAssertEqual(result.removedCognitiveItemCount, 4)
    XCTAssertEqual(result.markedCognitiveItemCount, 2)
    XCTAssertEqual(result.removedDreamReportCount, 1)
    XCTAssertNotNil(result.backupURL)

    let events = try String(contentsOf: brain.eventsURL, encoding: .utf8)
    XCTAssertFalse(events.contains("\"event_id\":\"today\""))
    XCTAssertTrue(events.contains("\"event_id\":\"older\""))

    let cognitiveJSON = try XCTUnwrap(CognitiveStoreReader.readCognitiveJSON(from: brain.memoryDatabaseURL))
    XCTAssertFalse(cognitiveJSON.contains("today_trace"))
    XCTAssertFalse(cognitiveJSON.contains("today_artifact"))
    XCTAssertFalse(cognitiveJSON.contains("older_touched_trace"))
    XCTAssertFalse(cognitiveJSON.contains("older_touched_artifact"))
    XCTAssertTrue(cognitiveJSON.contains("older_untouched_trace"))
    XCTAssertTrue(cognitiveJSON.contains("older_untouched_artifact"))
    XCTAssertTrue(cognitiveJSON.contains(#""status" : "pending_deletion""#))
    XCTAssertTrue(cognitiveJSON.contains(#""pending_deletion_source" : "forget_today""#))

    let reports = DreamReportJournal.load(from: brain.dreamReportsURL)
    XCTAssertEqual(reports.reports.map(\.dreamID), ["older-dream"])

    let backupURL = try XCTUnwrap(result.backupURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("events.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.appendingPathComponent("memory/people.sqlite").path))
  }

  func testDailyCompactionMarksUnreferencedItemsThenDeletesThemOnNextDream() throws {
    let brain = try makeBrain()
    try DreamReportJournal().write(to: brain.dreamReportsURL)
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 2,
      "traces": [
        { "trace_id": "orphan_trace", "created_at": "2026-06-24T15:30:00Z" },
        { "trace_id": "referenced_trace", "created_at": "2026-06-24T15:30:00Z" }
      ],
      "beliefs": [],
      "subjects": [],
      "artifacts": [],
      "dreams": [
        { "dream_id": "dream_1", "selected_trace_ids": ["referenced_trace"], "created_at": "2026-06-25T22:00:00Z" }
      ]
    }
    """)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let firstDream = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z"))
    let secondDream = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-26T22:30:00Z"))
    let dailyBackupContainer = FileManager.default.temporaryDirectory
      .appendingPathComponent("Affective-DailyMemoryCompactionBackups", isDirectory: true)
      .appendingPathComponent(brain.id, isDirectory: true)
    temporaryRoots.append(dailyBackupContainer)

    let first = try BrainCognitiveCompactor.compactAfterDailyDream(in: brain, now: firstDream, calendar: calendar)
    XCTAssertEqual(first.markedCount, 2)
    XCTAssertEqual(first.removedCount, 0)
    let backupChildren = try FileManager.default.contentsOfDirectory(at: dailyBackupContainer, includingPropertiesForKeys: nil)
    let firstBackup = try XCTUnwrap(backupChildren.first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstBackup.appendingPathComponent("events.jsonl").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstBackup.appendingPathComponent("dream_reports.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstBackup.appendingPathComponent("memory/people.sqlite").path))
    var cognitiveJSON = try XCTUnwrap(CognitiveStoreReader.readCognitiveJSON(from: brain.memoryDatabaseURL))
    XCTAssertTrue(cognitiveJSON.contains("orphan_trace"))
    XCTAssertTrue(cognitiveJSON.contains("dream_1"))
    XCTAssertTrue(cognitiveJSON.contains(#""pending_deletion_source" : "daily_dream""#))
    XCTAssertTrue(cognitiveJSON.contains("referenced_trace"))

    let second = try BrainCognitiveCompactor.compactAfterDailyDream(in: brain, now: secondDream, calendar: calendar)
    XCTAssertEqual(second.removedCount, 2)
    cognitiveJSON = try XCTUnwrap(CognitiveStoreReader.readCognitiveJSON(from: brain.memoryDatabaseURL))
    XCTAssertFalse(cognitiveJSON.contains("orphan_trace"))
    XCTAssertFalse(cognitiveJSON.contains("dream_1"))
    XCTAssertTrue(cognitiveJSON.contains("referenced_trace"))
  }

  func testDailyCompactionRestoresPendingItemWhenReferencedAgain() throws {
    let brain = try makeBrain()
    try writeCognitiveStore(at: brain.memoryDatabaseURL, dataJSON: """
    {
      "schema_version": 2,
      "traces": [
        {
          "trace_id": "recovered_trace",
          "created_at": "2026-06-24T15:30:00Z",
          "lifecycle": {
            "status": "pending_deletion",
            "pending_deletion_at": "2026-06-25T22:30:00Z",
            "pending_deletion_reason": "unreferenced",
            "pending_deletion_source": "daily_dream"
          }
        }
      ],
      "beliefs": [],
      "subjects": [],
      "artifacts": [],
      "dreams": [
        { "dream_id": "dream_2", "selected_trace_ids": ["recovered_trace"], "created_at": "2026-06-26T22:00:00Z" }
      ]
    }
    """)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let nextDream = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-26T22:30:00Z"))

    let result = try BrainCognitiveCompactor.compactAfterDailyDream(in: brain, now: nextDream, calendar: calendar)

    XCTAssertEqual(result.restoredCount, 1)
    XCTAssertEqual(result.removedCount, 0)
    let cognitiveJSON = try XCTUnwrap(CognitiveStoreReader.readCognitiveJSON(from: brain.memoryDatabaseURL))
    XCTAssertTrue(cognitiveJSON.contains("recovered_trace"))
    let data = try XCTUnwrap(cognitiveJSON.data(using: .utf8))
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let traces = try XCTUnwrap(root["traces"] as? [[String: Any]])
    let recoveredTrace = try XCTUnwrap(traces.first { $0["trace_id"] as? String == "recovered_trace" })
    let lifecycle = try XCTUnwrap(recoveredTrace["lifecycle"] as? [String: Any])
    XCTAssertNil(lifecycle["pending_deletion_at"])
    XCTAssertEqual(lifecycle["status"] as? String, "active")
  }

  func testDreamReportProviderSummarizerOffersOnlyConfiguredProvidersToRandomPicker() async throws {
    var offeredRoutes: [HostLLMCompletionProvider] = []
    let summarizer = DreamReportProviderSummarizer(
      credentialProvider: {
        [
          .openAI: " openai-key ",
          .anthropic: "   ",
          .google: "google-key",
        ]
      },
      textRoutePicker: { routes in
        offeredRoutes = routes
        return nil
      }
    )

    do {
      _ = try await summarizer.summarize(dreamReportDraft())
      XCTFail("Summarizer should fail when the picker declines all configured providers.")
    } catch DreamReportSummaryError.missingProviderCredential {
      XCTAssertEqual(offeredRoutes.filter { $0 != .appleFoundationModels }, [.credential(.openAI), .credential(.google)])
    }
  }

  func testDreamReportProviderSummarizerUsesRandomlySelectedProvider() async throws {
    var requestedURL: URL?
    var requestedBody: [String: Any] = [:]
    let summarizer = DreamReportProviderSummarizer(
      credentialProvider: {
        [
          .openAI: "openai-key",
          .anthropic: "anthropic-key",
          .google: "google-key",
        ]
      },
      textRoutePicker: { routes in
        XCTAssertTrue(routes.contains(.credential(.openAI)))
        XCTAssertTrue(routes.contains(.credential(.anthropic)))
        XCTAssertTrue(routes.contains(.credential(.google)))
        return .credential(.google)
      },
      jsonLoader: { request in
        requestedURL = request.url
        if let body = request.httpBody {
          requestedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        return [
          "candidates": [
            [
              "content": [
                "parts": [
                  ["text": "  A generated dream summary.  "]
                ]
              ]
            ]
          ]
        ]
      }
    )

    let summary = try await summarizer.summarize(dreamReportDraft())

    XCTAssertEqual(summary, DreamReportSummaryResult(text: "A generated dream summary.", source: "google"))
    XCTAssertEqual(requestedURL?.host, "generativelanguage.googleapis.com")
    XCTAssertEqual(URLComponents(url: try XCTUnwrap(requestedURL), resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "key" }?.value, "google-key")
    XCTAssertNotNil(requestedBody["contents"])
  }

  func testDreamReportSummaryFallsBackWhenProviderFails() async throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: cognitiveFixtureJSON(dreamID: "dream_1", artifactPath: "generated/images/dream.png")
    )

    let updated = try await DreamReportCollector.collect(
      brain: brain,
      existing: DreamReportJournal(),
      summaryProvider: FailingDreamReportSummaryProvider()
    )

    let report = try XCTUnwrap(updated.reports.first)
    XCTAssertEqual(report.summarySource, "fallback")
    XCTAssertTrue(report.summary.contains("0.50"))
    XCTAssertTrue(report.summary.contains("source trace"))
  }

  func testDreamLoadCheckRequestsDreamWhenNoDreamExists() throws {
    let brain = try makeBrain()
    let now = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z"))

    XCTAssertTrue(DreamReportCollector.shouldEnterDreamOnLoad(
      brain: brain,
      journal: DreamReportJournal(),
      now: now
    ))
  }

  func testDreamLoadCheckSkipsRecentDreamReport() throws {
    let brain = try makeBrain()
    let now = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z"))
    let reportDate = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-24T23:30:00Z"))
    let report = DreamReportCollector.report(
      from: DreamReportDraft(
        dreamID: "dream_recent",
        dayKey: "2026-06-24",
        createdAt: reportDate,
        reflection: "A recent report exists.",
        heat: 0.4,
        style: "associative_synthesis",
        confidence: 0.63,
        sourceTraceIDs: [],
        generatedArtifactID: nil,
        imagePath: nil,
        imageMimeType: nil,
        imagePrompt: nil
      ),
      summary: .init(text: "Recent dream.", source: "fallback")
    )

    XCTAssertFalse(DreamReportCollector.shouldEnterDreamOnLoad(
      brain: brain,
      journal: DreamReportJournal(reports: [report]),
      now: now
    ))
  }

  func testDreamLoadCheckSkipsRecentCognitiveDreamBeforeReportCollection() throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: cognitiveFixtureJSON(
        dreamID: "dream_recent",
        artifactPath: "generated/images/dream.png",
        createdAt: "2026-06-24T23:30:00Z"
      )
    )
    let now = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z"))

    XCTAssertFalse(DreamReportCollector.shouldEnterDreamOnLoad(
      brain: brain,
      journal: DreamReportJournal(),
      now: now
    ))
  }

  func testDreamLoadCheckRequestsDreamWhenLatestDreamIsAtLeastTwentyFourHoursOld() throws {
    let brain = try makeBrain(events: dreamImageEventJSONL())
    try writeCognitiveStore(
      at: brain.memoryDatabaseURL,
      dataJSON: cognitiveFixtureJSON(
        dreamID: "dream_old",
        artifactPath: "generated/images/dream.png",
        createdAt: "2026-06-24T22:30:00Z"
      )
    )
    let now = try XCTUnwrap(DreamReportDateFormatter.date(from: "2026-06-25T22:30:00Z"))

    XCTAssertTrue(DreamReportCollector.shouldEnterDreamOnLoad(
      brain: brain,
      journal: DreamReportJournal(),
      now: now
    ))
  }

  private func makeBrain(
    profile: String = #"{"schema_version":1,"display_name":"Test Brain"}"#,
    events: String = "",
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
    try events.write(
      to: root.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
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
    XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE cognitive_memory (id INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL, data_json TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
    let escaped = dataJSON.replacingOccurrences(of: "'", with: "''")
    let sql = "INSERT INTO cognitive_memory (id, schema_version, data_json) VALUES (1, 2, '\(escaped)')"
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

  private func archiveComponents(from data: Data) throws -> [[String: Any]] {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(object["components"] as? [[String: Any]])
  }

  private func archiveContainsBiometricData(_ data: Data) throws -> Bool? {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object["containsBiometricData"] as? Bool
  }

  private func archiveComponentData(_ path: String, in components: [[String: Any]]) throws -> Data? {
    guard let component = components.first(where: { $0["path"] as? String == path }),
          let dataBase64 = component["dataBase64"] as? String else {
      return nil
    }
    return Data(base64Encoded: dataBase64)
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
      payload: .actionRequest(BrainActionRequestPayload(
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

  private func cognitiveFixtureJSON(
    dreamID: String,
    artifactPath: String,
    createdAt: String = "2026-06-25T22:30:00Z"
  ) -> String {
    """
    {
      "schema_version": 2,
      "traces": [],
      "beliefs": [],
      "subjects": [],
      "artifacts": [
        {
          "artifact_id": "artifact_\(dreamID)",
          "kind": "image",
          "path": "\(artifactPath)",
          "mime_type": "image/png",
          "provenance": "dream",
          "retention": "episode",
          "linked_trace_ids": ["trace_1"],
          "lifecycle": {
            "status": "active",
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
          }
        }
      ],
      "dreams": [
        {
          "dream_id": "\(dreamID)",
          "selected_trace_ids": ["trace_1"],
          "belief_change_ids": [],
          "generated_artifact_id": "artifact_\(dreamID)",
          "reflection": "A memory linked itself to the end-of-day summary.",
          "heat": 0.5,
          "promoted_count": 0,
          "decayed_count": 0,
          "removed_count": 0,
          "revised_belief_count": 0,
          "created_at": "\(createdAt)"
        }
      ]
    }
    """
  }

  private func duplicateDreamsFixtureJSON(
    dreamID: String,
    artifactPath: String,
    createdAt: String = "2026-06-25T22:30:00Z"
  ) -> String {
    """
    {
      "schema_version": 2,
      "traces": [],
      "beliefs": [],
      "subjects": [],
      "artifacts": [
        {
          "artifact_id": "artifact_\(dreamID)",
          "kind": "image",
          "path": "\(artifactPath)",
          "mime_type": "image/png",
          "provenance": "dream",
          "retention": "episode",
          "linked_trace_ids": ["trace_1"],
          "lifecycle": {
            "status": "active",
            "created_at": "\(createdAt)",
            "updated_at": "\(createdAt)"
          }
        }
      ],
      "dreams": [
        {
          "dream_id": "\(dreamID)",
          "selected_trace_ids": ["trace_1"],
          "belief_change_ids": [],
          "generated_artifact_id": "artifact_\(dreamID)",
          "reflection": "First copy of a dream row.",
          "heat": 0.5,
          "promoted_count": 0,
          "decayed_count": 0,
          "removed_count": 0,
          "revised_belief_count": 0,
          "created_at": "\(createdAt)"
        },
        {
          "dream_id": "\(dreamID)",
          "selected_trace_ids": ["trace_2"],
          "belief_change_ids": [],
          "generated_artifact_id": "artifact_\(dreamID)",
          "reflection": "Duplicate copy of the same dream row.",
          "heat": 0.6,
          "promoted_count": 0,
          "decayed_count": 0,
          "removed_count": 0,
          "revised_belief_count": 0,
          "created_at": "\(createdAt)"
        }
      ]
    }
    """
  }

  private func dreamReport(
    dreamID: String,
    dayKey: String,
    isRead: Bool = false,
    isArchived: Bool = false
  ) -> DreamReport {
    let createdAt = DreamReportDateFormatter.date(from: "\(dayKey)T22:30:00Z") ?? Date()
    return DreamReport(
      reportID: DreamReportCollector.reportKey(dayKey: dayKey, dreamID: dreamID),
      dreamID: dreamID,
      dayKey: dayKey,
      createdAt: createdAt,
      summary: "Summary for \(dreamID).",
      summarySource: "fallback",
      fullReportText: "Full report for \(dreamID).",
      reflection: "Reflection for \(dreamID).",
      heat: 0.5,
      style: "associative_synthesis",
      confidence: 0.575,
      sourceTraceIDs: ["trace_1"],
      generatedArtifactID: "artifact_\(dreamID)",
      imagePath: nil,
      imageMimeType: nil,
      imagePrompt: nil,
      isRead: isRead,
      isArchived: isArchived
    )
  }

  private func dreamReportDraft(
    dreamID: String = "dream_1",
    dayKey: String = "2026-06-25"
  ) -> DreamReportDraft {
    DreamReportDraft(
      dreamID: dreamID,
      dayKey: dayKey,
      createdAt: DreamReportDateFormatter.date(from: "\(dayKey)T22:30:00Z") ?? Date(),
      reflection: "A dream linked a memory to a quiet symbol.",
      heat: 0.5,
      style: "associative_synthesis",
      confidence: 0.575,
      sourceTraceIDs: ["trace_1"],
      generatedArtifactID: "artifact_\(dreamID)",
      imagePath: "generated/images/dream.png",
      imageMimeType: "image/png",
      imagePrompt: "Create a quiet symbolic dream image."
    )
  }

  private func dreamImageEventJSONL() -> String {
    """
    {"event_id":"event_1","time":"2026-06-25T22:30:01Z","kind":"autonomy","source":"brain","title":"dream_image","body":"generated/images/dream.png","subject":"dream_image","raw":"Create a quiet symbolic dream image.","interpretation":"generated/images/dream.png","tags":["dream","image"]}

    """
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
      "face_identification": .hostAdapter,
      "face_enrollment": .hostAdapter,
      "introspection": .embeddedRoute,
      "time_lookup": .hostAdapter,
      "power_status": .hostAdapter,
      "storage_fullness": .hostAdapter,
      "database_stats": .hostAdapter,
      "local_process_io": .hostAdapter,
      "file_import": .hostAdapter,
      "file_export": .hostAdapter,
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
  private let cameraObservationDelayNanoseconds: UInt64
  private let pullSenseStatusError: Error?
  private(set) var didConnect = false
  private(set) var didDisconnect = false
  private(set) var toolCalls: [ToolCall] = []
  private(set) var textCalls: [TextCall] = []
  private(set) var pokeSequences: [[PokePulse]] = []
  private var textCallContinuations: [(minimumCount: Int, continuation: CheckedContinuation<[TextCall], Never>)] = []
  private(set) var orientationObservations: [OrientationObservationCall] = []
  private(set) var motionGestureObservations: [MotionGestureObservationCall] = []
  private(set) var cameraObservations: [CameraObservation] = []
  private(set) var senseCatalogRequests: [String?] = []
  private(set) var pullSenseStatuses: [PullSenseStatusCall] = []

  init(
    toolResponse: BrainToolResponse,
    textResponse: BrainTextResponse? = nil,
    shortTouchResponse: BrainToolResponse? = nil,
    orientationObservationResponse: BrainToolResponse? = nil,
    motionGestureObservationResponse: BrainToolResponse? = nil,
    cameraObservationResponse: BrainToolResponse,
    cameraObservationDelayNanoseconds: UInt64 = 0,
    pullSenseStatusError: Error? = nil
  ) {
    self.toolResponse = toolResponse
    self.textResponse = textResponse ?? BrainTextResponse(toolName: "experience", text: "", metadata: [:], events: [])
    self.shortTouchResponse = shortTouchResponse ?? toolResponse
    self.orientationObservationResponse = orientationObservationResponse ?? toolResponse
    self.motionGestureObservationResponse = motionGestureObservationResponse ?? toolResponse
    self.cameraObservationResponse = cameraObservationResponse
    self.cameraObservationDelayNanoseconds = cameraObservationDelayNanoseconds
    self.pullSenseStatusError = pullSenseStatusError
  }

  func connect() async throws {
    didConnect = true
  }

  func disconnect() async {
    didDisconnect = true
  }

  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse {
    switch event.payload {
    case .memoryRequest(let payload):
      var arguments: [String: JSONValue] = [
        "operation": .string(payload.operation.rawValue),
        "layers": .array(payload.layers.map { .string($0.rawValue) }),
        "tags": .array(payload.tags.map { .string($0) }),
      ]
      if let query = payload.query { arguments["query"] = .string(query) }
      if let text = payload.text { arguments["text"] = .string(text) }
      toolCalls.append(ToolCall(name: "memory_request", arguments: arguments))
    case .actionRequest(let payload):
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

  func hostCapabilityStatus(
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
    userText _: String,
    reason _: String,
    interruptedAction _: String?,
    canceledQueuedActionCount _: Int
  ) async throws -> BrainToolResponse {
    toolResponse
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
    return textResponse
  }

  func waitForTextCallCount(_ minimumCount: Int) async -> [TextCall] {
    guard textCalls.count < minimumCount else { return textCalls }

    return await withCheckedContinuation { continuation in
      textCallContinuations.append((minimumCount, continuation))
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

  func refreshState() async throws -> BrainStateSnapshot {
    BrainStateSnapshot(toolName: "state", text: "ready", metadata: [:])
  }
}

private struct FailingDreamReportSummaryProvider: DreamReportSummaryProviding {
  func summarize(_ draft: DreamReportDraft) async throws -> DreamReportSummaryResult {
    throw DreamReportSummaryError.missingProviderCredential
  }
}

private final class FakeBrainCloudCheckpointStore: BrainCloudCheckpointStore {
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
    guard BrainCheckpointArchive.sha256Hex(archive) == manifest.archiveHash else {
      return .invalid("The archive checksum does not match its manifest.")
    }
    do {
      try BrainCheckpointArchive.validateCheckpointPayload(archive, expectedBrainID: manifest.brainID)
      return .available
    } catch {
      return .invalid(error.localizedDescription)
    }
  }

  func downloadCheckpoint(brainID: String, to localURL: URL) async throws -> BrainCloudManifest {
    if let error {
      throw error
    }
    guard let manifest = manifests[brainID], let archive = archives[brainID] else {
      throw BrainSyncError.missingCheckpoint
    }
    try archive.write(to: localURL, options: .atomic)
    return manifest
  }

  func uploadCheckpoint(from localURL: URL, manifest: BrainCloudManifest) async throws {
    if let error {
      throw error
    }
    manifests[manifest.brainID] = manifest
    archives[manifest.brainID] = try Data(contentsOf: localURL)
    uploads.append(manifest)
  }
}
