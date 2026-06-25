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

    try await core.connect()
    await core.disconnect()
  }

  func testEmbeddedProtocolContractMatchesWrapperHostManifest() throws {
    let manifestData = Data(CoreConfigStorage.hostManifestJSON(hasProvider: false).utf8)
    let manifest = try JSONValue.decodedObject(from: manifestData)

    XCTAssertEqual(manifest["api_version"], .number(Double(EmbeddedProtocolContract.apiVersion)))
    XCTAssertEqual(manifest["max_envelope_bytes"], .number(16 * 1024))
    XCTAssertEqual(manifest["max_event_count"], .number(12))
    XCTAssertEqual(manifest["max_event_text_bytes"], .number(768))
    XCTAssertEqual(manifest["raw_ref_ttl_seconds"], .number(24 * 60 * 60))

    let capabilityValues = try XCTUnwrap(manifest["capabilities"]?.arrayValue)
    let capabilities = Set(capabilityValues.compactMap(\.stringValue))
    XCTAssertEqual(capabilities.count, capabilityValues.count, "Host manifest capabilities should be unique.")

    for capability in EmbeddedProtocolContract.baseHostCapabilities {
      XCTAssertTrue(
        capabilities.contains(capability),
        "Affective host manifest is missing required embedded capability '\(capability)'.")
    }

    for eventType in EmbeddedProtocolContract.eventTypesRequiringHostCapability {
      XCTAssertTrue(
        capabilities.contains(eventType),
        "Affective dispatches '\(eventType)' but does not advertise it in the host manifest.")
    }

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
    XCTAssertTrue(providerCapabilities.contains("live_camera"))
    XCTAssertEqual(providerManifest["capability_status"]?.objectValue?["camera"], .string("prompt_required"))
  }

  func testAdvertisedHostCapabilitiesHaveEndToEndCoverage() async throws {
    let advertised = try Self.allAdvertisedHostCapabilities()
    let coverage = Self.hostCapabilityE2ECoverage

    XCTAssertEqual(
      advertised,
      Set(coverage.keys),
      "Every advertised host capability needs explicit e2e coverage or an intentional manifest-only classification."
    )

    let dispatchable = coverage.filter {
      $0.value == .embeddedDispatch || $0.value == .providerBackedDispatch
    }.map(\.key)
    XCTAssertEqual(
      Set(dispatchable),
      Set(EmbeddedProtocolContract.eventTypesRequiringHostCapability),
      "Dispatchable host capability coverage should stay aligned with the embedded protocol contract."
    )

    let brain = try makeBrain()
    let core = BrainCore(brain: brain)
    try await core.connect()

    let shortTouch = try await core.shortTouch()
    XCTAssertEqual(shortTouch.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let longTouch = try await core.longTouch()
    XCTAssertEqual(longTouch.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let poke = try await core.pokeSequence([
      PokePulse(pressMilliseconds: 25, pauseBeforeMilliseconds: 0)
    ])
    XCTAssertEqual(poke.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let tool = try await core.callTool("list_reminders")
    XCTAssertEqual(tool.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let typedText = try await core.sendText("capability e2e typed text")
    XCTAssertEqual(typedText.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let orientation = try await core.orientationObservation(
      OrientationQueryProvider.classify(x: 0.02, y: 0.01, z: -0.99)
    )
    XCTAssertEqual(orientation.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let imageURL = brain.rootURL.appendingPathComponent("capability-e2e.png")
    try Self.tinyPNGData.write(to: imageURL, options: .atomic)
    let camera = try await core.cameraObservation(
      path: imageURL.path,
      mimeType: "image/png",
      source: "capability_e2e",
      requestID: "capability-e2e-camera"
    )
    XCTAssertEqual(camera.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")

    let state = try await core.refreshState()
    XCTAssertEqual(state.metadata["api_version"], "\(EmbeddedProtocolContract.apiVersion)")
    XCTAssertFalse(state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    await core.disconnect()
  }

  func testCameraPromptRequiredAdvertisesFrontendCameraSense() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true, cameraStatus: "prompt_required").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertTrue(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("visual_description"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["camera"], .string("prompt_required"))
  }

  func testCameraAvailableAdvertisesLiveCamera() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true, cameraStatus: "available").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertTrue(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("visual_description"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["camera"], .string("available"))
  }

  func testCameraDeniedRemovesLiveCameraFromHostManifest() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: true, cameraStatus: "denied").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("live_camera"))
    XCTAssertTrue(capabilities.contains("visual_description"))
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
  func testSenseRequestsStayOutOfChatTranscript() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      BrainHostEvent(
        type: "sense_requested",
        requestID: "sense-fixture",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "camera sense",
        body: "Affective wants a fresh webcam image.",
        sense: "camera",
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil)
    ], mirrorChatMessages: true, speak: false, handleHostRequests: false)

    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertEqual(model.commandEntries.last?.title, "camera sense")
    XCTAssertEqual(model.commandEntries.last?.body, "Affective wants a fresh webcam image.")
  }

  @MainActor
  func testFrontendCaptureDiagnosticBecomesCameraSenseRequest() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count
    let diagnostic = "Something went wrong while I tried that: FrontendCaptureRequested."

    let result = await model.applyCoreEvents([
      BrainHostEvent(
        type: "chat_message",
        requestID: "capture-fixture",
        role: "brain",
        text: diagnostic,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "Brain",
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil),
      BrainHostEvent(
        type: "command_log",
        requestID: "capture-fixture",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: "error",
        title: "Hard error needs recovery",
        body: diagnostic,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil),
      BrainHostEvent(
        type: "speech_requested",
        requestID: "capture-fixture",
        role: nil,
        text: diagnostic,
        state: nil,
        enabled: nil,
        kind: nil,
        title: nil,
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil)
    ], mirrorChatMessages: true, speak: true, handleHostRequests: false)

    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertFalse(result.didRequestSpeech)
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertEqual(model.commandEntries.last?.title, "camera sense")
    XCTAssertEqual(model.commandEntries.last?.body, "frontend camera sense requested")
    XCTAssertEqual(model.commandEntries.last?.metadata["event_type"], "sense_requested")
    XCTAssertEqual(model.commandEntries.last?.metadata["sense"], "camera")
    XCTAssertEqual(model.commandEntries.last?.metadata["await_response"], "true")
    XCTAssertEqual(model.commandEntries.last?.metadata["timeout_ms"], "10000")
    XCTAssertNil(model.commandEntries.last { $0.body == diagnostic })
  }

  @MainActor
  func testFrontendCaptureMentionInNormalReplyDoesNotRequestCapture() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let text = "FrontendCaptureRequested means the frontend should provide an image."

    let result = await model.applyCoreEvents([
      BrainHostEvent(
        type: "chat_message",
        requestID: "capture-mention",
        role: "brain",
        text: text,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "Brain",
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil)
    ], mirrorChatMessages: true, speak: false)

    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.last?.body, text)
    XCTAssertNil(model.commandEntries.last { $0.title == "camera sense" })
  }

  @MainActor
  func testRecognizeToolFrontendCaptureDiagnosticRunsCameraObservationFlow() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(
        toolName: "recognize",
        events: Self.frontendCaptureDiagnosticEvents(requestID: "capture-e2e")
      ),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }
    let initialChatCount = model.chatEntries.count

    await model.callCoreTool(name: "recognize", title: "Recognize", arguments: [:], mirrorToChat: true)

    let toolCalls = await core.toolCalls
    XCTAssertEqual(toolCalls.map(\.name), ["recognize"])

    let observations = await core.cameraObservations
    let observation = try XCTUnwrap(observations.last)
    XCTAssertEqual(observation.mimeType, "image/png")
    XCTAssertEqual(observation.source, "affective_requested_capture")
    XCTAssertEqual(observation.requestID, "capture-e2e")
    XCTAssertEqual(observation.presentation, .chat)
    XCTAssertTrue(FileManager.default.fileExists(atPath: observation.path))

    let captureEntry = try XCTUnwrap(model.commandEntries.last { $0.title == "camera sense" })
    XCTAssertEqual(captureEntry.metadata["media_kind"], "image")
    XCTAssertEqual(captureEntry.metadata["source"], "affective_requested_capture")

    XCTAssertNotNil(model.commandEntries.last { $0.title == "sense_observation" })
    XCTAssertNil(model.chatEntries.last { $0.body.contains("FrontendCaptureRequested") })
    XCTAssertNil(model.commandEntries.last { $0.body.contains("Something went wrong while I tried that") })
    XCTAssertEqual(model.commandEntries.last { $0.title == "Recognize" }?.body, "Recognize requested a camera sense.")
    let awaitedSenseEntry = try XCTUnwrap(model.commandEntries.last { $0.title == "awaited sense" })
    XCTAssertEqual(awaitedSenseEntry.body, "camera observation completed without a chat event.")
    XCTAssertEqual(awaitedSenseEntry.metadata["event_type"], "awaited_sense_response")
    XCTAssertEqual(awaitedSenseEntry.metadata["sense"], "camera")
    XCTAssertEqual(model.chatEntries.count, initialChatCount)
    XCTAssertFalse(model.speechSpeaker.isSpeaking)
  }

  @MainActor
  func testAwaitedCameraSenseTimesOutWaitingForObservationResponse() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation"),
      cameraObservationDelayNanoseconds: 50_000_000
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.cameraPermissionRequestTask = Task { .available }
    model.cameraPhotoCaptureOverride = { Self.tinyPNGData }

    await model.applyCoreEvents([
      BrainHostEvent(
        type: "sense_requested",
        requestID: "capture-timeout",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "camera sense",
        body: "frontend camera sense requested",
        sense: "camera",
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil,
        responsePresentation: BrainEventPresentation.chat.rawValue,
        awaitResponse: true,
        timeoutMS: 1)
    ], mirrorChatMessages: true, speak: false)

    let observations = await core.cameraObservations
    let observation = try XCTUnwrap(observations.last)
    XCTAssertEqual(observation.presentation, .chat)
    let failure = try XCTUnwrap(model.commandEntries.last { $0.title == "camera sense failed" })
    XCTAssertTrue(failure.body.contains("timed out"))
    XCTAssertEqual(model.chatEntries.last?.title, "Camera")
    XCTAssertTrue(model.chatEntries.last?.body.contains("couldn't get a usable image") == true)
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
      BrainHostEvent(
        type: "sense_requested",
        requestID: "black-frame",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "camera sense",
        body: "frontend camera sense requested",
        sense: "camera",
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil,
        responsePresentation: BrainEventPresentation.chat.rawValue,
        awaitResponse: true,
        timeoutMS: 10_000)
    ], mirrorChatMessages: true, speak: false)

    let observations = await core.cameraObservations
    XCTAssertTrue(observations.isEmpty)
    let failure = try XCTUnwrap(model.commandEntries.last { $0.title == "camera sense failed" })
    XCTAssertEqual(failure.metadata["camera_error"], "blackImageData")
    XCTAssertEqual(model.chatEntries.last?.title, "Camera")
    XCTAssertEqual(model.chatEntries.last?.body, "I tried to use the camera, but the frame came back nearly black.")
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
      BrainHostEvent(
        type: "sense_requested",
        requestID: "internal-black-frame",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "camera sense",
        body: "frontend camera sense requested",
        sense: "camera",
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil,
        awaitResponse: true,
        timeoutMS: 10_000),
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
          BrainHostEvent(
            type: "sense_requested",
            requestID: "short-touch-capture",
            role: nil,
            text: nil,
            state: nil,
            enabled: nil,
            kind: nil,
            title: "camera sense",
            body: "frontend camera sense requested",
            sense: "camera",
            eyes: nil,
            mouth: nil,
            durationMS: nil,
            mediaKind: nil,
            path: nil,
            url: nil,
            mimeType: nil,
            caption: nil,
            rawRef: nil,
            originalBytes: nil,
            responsePresentation: BrainEventPresentation.chat.rawValue)
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
      BrainHostEvent(
        type: "sense_requested",
        requestID: "recent-camera",
        role: nil,
        text: nil,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "camera sense",
        body: "frontend camera sense requested",
        sense: "camera",
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil),
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
        toolName: "typed_text",
        text: "Hello from the first turn.",
        metadata: [:],
        events: [
          brainChatEvent(title: "Brain", text: "Hello from the first turn."),
          BrainHostEvent(
            type: "sense_requested",
            requestID: "typed-text-capture",
            role: nil,
            text: nil,
            state: nil,
            enabled: nil,
            kind: nil,
            title: "camera sense",
            body: "frontend camera sense requested",
            sense: "camera",
            eyes: nil,
            mouth: nil,
            durationMS: nil,
            mediaKind: nil,
            path: nil,
            url: nil,
            mimeType: nil,
            caption: nil,
            rawRef: nil,
            originalBytes: nil)
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
          BrainHostEvent(
            type: "sense_requested",
            requestID: "orientation-capture",
            role: nil,
            text: nil,
            state: nil,
            enabled: nil,
            kind: nil,
            title: "orientation sense",
            body: "Affective wants orientation.",
            sense: "orientation",
            eyes: nil,
            mouth: nil,
            durationMS: nil,
            mediaKind: nil,
            path: nil,
            url: nil,
            mimeType: nil,
            caption: nil,
            rawRef: nil,
            originalBytes: nil,
            responsePresentation: BrainEventPresentation.chat.rawValue)
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
      textResponse: BrainTextResponse(toolName: "typed_text", text: "", metadata: [:], events: []),
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
    try await Task.sleep(nanoseconds: 200_000_000)

    let textCalls = await core.textCalls
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
      textResponse: BrainTextResponse(toolName: "typed_text", text: "Sure.", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.recordConversationTurn(role: "user", text: "Let's design working memory.", source: "typed_text", metadata: ["source": "typed text"])
    model.recordConversationTurn(role: "brain", text: "We can keep a bounded recent window.", source: "chat_message", metadata: ["event_type": "chat_message"])
    model.messageText = "Now make it time-aware."

    model.sendText()
    try await Task.sleep(nanoseconds: 200_000_000)

    let textCalls = await core.textCalls
    let arguments = try XCTUnwrap(textCalls.last?.stimulusContext?.eventArguments)
    let conversation = try XCTUnwrap(arguments["conversation_context"]?.objectValue)
    let turns = try XCTUnwrap(conversation["recent_turns"]?.arrayValue)

    XCTAssertEqual(turns.count, 2)
    XCTAssertEqual(turns.compactMap { $0.objectValue?["text"]?.stringValue }, [
      "Let's design working memory.",
      "We can keep a bounded recent window.",
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
      source: "typed_text",
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
  }

  @MainActor
  func testFallbackBrainResponseRecordsConversationTurn() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "typed_text", text: "Fallback hello.", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true

    await model.sendTextToBrain("Hello?", speakResponse: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertEqual(turns.last?.role, "brain")
    XCTAssertEqual(turns.last?.text, "Fallback hello.")
    XCTAssertEqual(turns.filter { $0.text == "Fallback hello." }.count, 1)
  }

  @MainActor
  func testEventDrivenBrainChatRecordsConversationTurnOnce() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())

    let result = await model.applyCoreEvents([
      brainChatEvent(title: "Brain", text: "Event hello.")
    ], mirrorChatMessages: true, speak: false)

    let turns = model.conversationContextSnapshot().recentTurns
    XCTAssertTrue(result.didAppendBrainChat)
    XCTAssertEqual(turns.last?.role, "brain")
    XCTAssertEqual(turns.last?.text, "Event hello.")
    XCTAssertEqual(turns.filter { $0.text == "Event hello." }.count, 1)
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
    XCTAssertTrue(snapshot.rollingSummary.contains("user: Turn 0"))
    XCTAssertTrue(snapshot.rollingSummary.contains("brain: Turn 1"))
    XCTAssertEqual(snapshot.recentTurns.first?.text, "Turn 2")
  }

  @MainActor
  func testImageMessageRecordsConversationTurnWithMediaMetadata() async throws {
    let core = ScriptedBrainCore(
      toolResponse: Self.toolResponse(toolName: "unused"),
      textResponse: BrainTextResponse(toolName: "typed_text", text: "", metadata: [:], events: []),
      cameraObservationResponse: Self.toolResponse(toolName: "sense_observation")
    )
    let model = AffectiveViewModel(brain: try makeBrain(), brainCore: core)
    model.isBrainConnected = true
    model.messageText = "Look at this sketch."

    model.sendImage(data: Self.tinyPNGData, suggestedName: "sketch.png")
    try await Task.sleep(nanoseconds: 200_000_000)

    let imageTurn = try XCTUnwrap(model.conversationContextSnapshot().recentTurns.last)
    XCTAssertEqual(imageTurn.role, "user")
    XCTAssertEqual(imageTurn.source, "image")
    XCTAssertEqual(imageTurn.metadata["media_kind"], "image")
    XCTAssertEqual(imageTurn.metadata["mime_type"], "image/png")
    XCTAssertNotNil(imageTurn.metadata["image_path"])
    XCTAssertNil(imageTurn.metadata["original_bytes"])

    let textCalls = await core.textCalls
    let callContext = try XCTUnwrap(textCalls.last?.stimulusContext?.eventArguments["conversation_context"]?.objectValue)
    let sentContextTurns = try XCTUnwrap(callContext["recent_turns"]?.arrayValue)
    XCTAssertFalse(sentContextTurns.contains { $0.objectValue?["text"]?.stringValue == "Look at this sketch." })
  }

  @MainActor
  func testFacialExpressionRequestAddsChatAsideForStaticAvatar() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    let result = await model.applyCoreEvents([
      facialExpressionEvent(eyes: "bright eyes", mouth: "small smile")
    ], mirrorChatMessages: true, speak: false)

    XCTAssertFalse(result.didAppendBrainChat)
    XCTAssertEqual(model.chatEntries.count, initialChatCount + 1)
    XCTAssertEqual(model.chatEntries.last?.title, "Aside")
    XCTAssertEqual(model.chatEntries.last?.body, "(bright eyes / small smile)")
    XCTAssertEqual(model.chatEntries.last?.metadata["presentation"], "chat_aside")
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
  func testActivityStatusEventUpdatesHostStatusWithoutChatBubble() async throws {
    let model = AffectiveViewModel(brain: try makeBrain())
    let initialChatCount = model.chatEntries.count

    _ = await model.applyCoreEvents([
      BrainHostEvent(
        type: "activity_status_changed",
        requestID: "activity-fixture",
        role: nil,
        text: "Waiting for your name.",
        state: "waiting_for_user_identity",
        enabled: nil,
        kind: nil,
        title: "Learning your name",
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil)
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

    XCTAssertTrue(capabilities.contains("orientation_query"))
    XCTAssertTrue(capabilities.contains("sense_observation"))
    XCTAssertEqual(manifest["capability_status"]?.objectValue?["orientation"], .string("prompt_required"))
  }

  func testOrientationDeniedRemovesGenericSenseObservation() throws {
    let manifest = try JSONValue.decodedObject(
      from: Data(CoreConfigStorage.hostManifestJSON(hasProvider: false, orientationStatus: "denied").utf8))
    let capabilities = Set(
      try XCTUnwrap(manifest["capabilities"]?.arrayValue).compactMap(\.stringValue))

    XCTAssertFalse(capabilities.contains("orientation_query"))
    XCTAssertFalse(capabilities.contains("sense_observation"))
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

  func testEmbeddedProtocolContractBuildsV2WrapperDispatchRequests() throws {
    for eventType in EmbeddedProtocolContract.wrapperDispatchEventTypes {
      let request: JSONValue = .object([
        "api_version": .number(Double(EmbeddedProtocolContract.apiVersion)),
        "request_id": .string("fixture-\(eventType)"),
        "event": .object(["type": .string(eventType)]),
      ])
      let fixture = try JSONValue.decodedObject(from: request.encodedData())

      XCTAssertEqual(fixture["api_version"], .number(2))
      XCTAssertEqual(fixture["request_id"], .string("fixture-\(eventType)"))
      XCTAssertEqual(fixture["event"]?.objectValue?["type"], .string(eventType))
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
    XCTAssertNotNil(object["image_generation_checked"])
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
    XCTAssertEqual(response.metadata["migration_fallback"], "legacy_command_result")
    XCTAssertNotNil(response.metadata["fallback_warning"])
  }

  func testBrainToolResponseFallsBackToObservationForSilentCommandResults() throws {
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
    XCTAssertEqual(response.metadata["migration_fallback"], "legacy_command_result")
    XCTAssertNotNil(response.metadata["fallback_warning"])
  }

  func testBrainToolResponsePrefersEventEnvelope() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
        "request_id": "test-request",
        "ok": true,
        "events": [
          { "type": "send_enabled_changed", "enabled": false },
          { "type": "speech_requested", "text": "I found one memory." },
          { "type": "chat_message", "role": "brain", "text": "Here is what I remember." },
          { "type": "send_enabled_changed", "enabled": true }
        ],
        "result": {
          "event_type": "tool_call",
          "summary": "{\"command\":\"recall_memory\",\"observation\":\"legacy observation\",\"spoken_text\":null,\"ended_with_speech\":false,\"interrupted_by\":null}",
          "raw_result": true
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 512,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    let response = BrainToolResponse(toolName: "recall_memory", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "Here is what I remember.")
    XCTAssertTrue(response.shouldSpeak)
    XCTAssertEqual(response.events.count, 4)
    XCTAssertEqual(response.metadata["display_source"], "event_envelope")
    XCTAssertNil(response.metadata["migration_fallback"])
    XCTAssertEqual(response.metadata["event_types"], "send_enabled_changed,speech_requested,chat_message,send_enabled_changed")
    XCTAssertEqual(response.metadata["budget_max_bytes"], "16384")
  }

  func testBrainToolResponseMarksEnvelopeFallbackAsMigrationOnly() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
        "request_id": "test-request",
        "ok": true,
        "events": [],
        "result": {
          "event_type": "tool_call",
          "summary": "{\"command\":\"recall_memory\",\"observation\":\"legacy observation\",\"spoken_text\":null,\"ended_with_speech\":false,\"interrupted_by\":null}",
          "raw_result": true
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 180,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    let response = BrainToolResponse(toolName: "recall_memory", envelope: envelope, rawText: envelope.rawText)

    XCTAssertEqual(response.text, "legacy observation")
    XCTAssertEqual(response.metadata["display_source"], "observation")
    XCTAssertEqual(response.metadata["migration_fallback"], "legacy_command_result")
    XCTAssertNotNil(response.metadata["fallback_warning"])
  }

  func testBrainToolResponseDecodesDirectTouchCommandResult() throws {
    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
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
    XCTAssertEqual(response.metadata["display_source"], "raw_text")
    XCTAssertEqual(response.metadata["event_types"], "")
    XCTAssertEqual(response.metadata["migration_fallback"], "raw_text")
  }

  func testBrainDispatchEnvelopeDecodesV2Envelopes() throws {
    let success = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
        "request_id": "fixture-success-001",
        "ok": true,
        "events": [
          {
            "type": "send_enabled_changed",
            "request_id": "fixture-success-001",
            "enabled": false
          },
          {
            "type": "chat_message",
            "request_id": "fixture-success-001",
            "role": "brain",
            "title": "AMBI",
            "text": "I found one memory about soldering."
          },
          {
            "type": "speech_requested",
            "request_id": "fixture-success-001",
            "text": "I found one memory about soldering."
          },
          {
            "type": "send_enabled_changed",
            "request_id": "fixture-success-001",
            "enabled": true
          }
        ],
        "result": {
          "event_type": "typed_text",
          "summary": "{\"user_text\":\"What do you remember about soldering?\",\"spoken_text\":\"I found one memory about soldering.\",\"user_summary\":\"Asked for soldering memories.\",\"brain_summary\":\"Shared a soldering memory.\",\"interrupted_by\":null}",
          "raw_result": true
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 780,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    XCTAssertTrue(success.ok)
    XCTAssertEqual(success.apiVersion, 2)
    XCTAssertEqual(success.requestID, "fixture-success-001")
    XCTAssertEqual(success.events.count, 4)
    XCTAssertEqual(success.events.first?.requestID, "fixture-success-001")
    XCTAssertEqual(success.displayTextFromEvents, "I found one memory about soldering.")
    XCTAssertNotNil(success.conversationTurnJSON)
    XCTAssertEqual(success.budget?.maxBytes, 16384)

    let drain = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
        "request_id": "",
        "ok": true,
        "events": [
          {
            "type": "command_log",
            "request_id": "fixture-tool-call-001",
            "kind": "result",
            "title": "remember_memory",
            "body": "memory_saved"
          },
          {
            "type": "state_changed",
            "request_id": "fixture-tool-call-001",
            "state": "ready",
            "text": "Ready"
          }
        ],
        "result": {
          "kind": "drain"
        },
        "budget": {
          "max_bytes": 16384,
          "used_bytes": 220,
          "compacted": false,
          "dropped_event_count": 0,
          "raw_refs": []
        }
      }
      """#)

    XCTAssertTrue(drain.ok)
    XCTAssertEqual(drain.events.count, 2)
    XCTAssertEqual(drain.events.first?.requestID, "fixture-tool-call-001")

    let envelope = try BrainDispatchEnvelope.decode(from: #"""
      {
        "api_version": 2,
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
    XCTAssertEqual(envelope.apiVersion, 2)
    XCTAssertEqual(envelope.error?.code, "unknown_event_type")
    XCTAssertEqual(envelope.error?.message, "unknown embedded event type")
    XCTAssertEqual(envelope.error?.recoverable, false)
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

  func testAppIntentBridgeConsumesPendingBrainRequest() throws {
    let defaults = try makeUserDefaults()
    defaults.set("existing-brain", forKey: AffectiveViewModel.lastOpenedBrainIDKey)

    AffectiveAppIntentBridge.requestOpenBrain(id: "brain-one", defaults: defaults)

    XCTAssertEqual(defaults.string(forKey: AffectiveViewModel.lastOpenedBrainIDKey), "existing-brain")
    XCTAssertEqual(AffectiveAppIntentBridge.pendingBrainID(defaults: defaults), "brain-one")
    XCTAssertEqual(AffectiveAppIntentBridge.pendingBrainID(defaults: defaults), "brain-one")
    XCTAssertEqual(AffectiveAppIntentBridge.consumePendingBrainID(defaults: defaults), "brain-one")
    XCTAssertNil(AffectiveAppIntentBridge.consumePendingBrainID(defaults: defaults))
  }

  func testAppIntentBridgeRecordsLastOpenedBrainAfterSuccessfulOpen() throws {
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

  func testAppIntentBridgeFallsBackToLastOpenedBrain() throws {
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
      revision: 1
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
      revision: 1
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
      revision: 2
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
      revision: 1
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

  private func brainChatEvent(title: String?, text: String) -> BrainHostEvent {
    BrainHostEvent(
      type: "chat_message",
      requestID: "chat-fixture",
      role: "brain",
      text: text,
      state: nil,
      enabled: nil,
      kind: nil,
      title: title,
      body: nil,
      sense: nil,
      eyes: nil,
      mouth: nil,
      durationMS: nil,
      mediaKind: nil,
      path: nil,
      url: nil,
      mimeType: nil,
      caption: nil,
      rawRef: nil,
      originalBytes: nil)
  }

  private func facialExpressionEvent(eyes: String?, mouth: String?) -> BrainHostEvent {
    BrainHostEvent(
      type: "facial_expression_requested",
      requestID: "expression-fixture",
      role: nil,
      text: nil,
      state: nil,
      enabled: nil,
      kind: nil,
      title: nil,
      body: nil,
      sense: nil,
      eyes: eyes,
      mouth: mouth,
      durationMS: nil,
      mediaKind: nil,
      path: nil,
      url: nil,
      mimeType: nil,
      caption: nil,
      rawRef: nil,
      originalBytes: nil)
  }

  private func speechRequestedEvent(text: String) -> BrainHostEvent {
    BrainHostEvent(
      type: "speech_requested",
      requestID: "speech-fixture",
      role: nil,
      text: text,
      state: nil,
      enabled: nil,
      kind: nil,
      title: nil,
      body: nil,
      sense: nil,
      eyes: nil,
      mouth: nil,
      durationMS: nil,
      mediaKind: nil,
      path: nil,
      url: nil,
      mimeType: nil,
      caption: nil,
      rawRef: nil,
      originalBytes: nil)
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
      "typed_text": .providerBackedDispatch,
      "poke_sequence": .embeddedDispatch,
      "short_touch": .embeddedDispatch,
      "long_touch": .embeddedDispatch,
      "tool_call": .embeddedDispatch,
      "speech_output": .hostAdapter,
      "uploaded_media_read": .hostAdapter,
      "stored_memory_read": .hostAdapter,
      "stored_memory_write": .hostAdapter,
      "stored_image_read": .hostAdapter,
      "identity_recognition": .hostAdapter,
      "introspection": .embeddedRoute,
      "time_lookup": .hostAdapter,
      "power_status": .hostAdapter,
      "storage_fullness": .hostAdapter,
      "database_stats": .hostAdapter,
      "reminder_io": .hostAdapter,
      "image_generation": .providerBackedHostAdapter,
      "face_picture_update": .hostAdapter,
      "local_process_io": .hostAdapter,
      "facial_expression_output": .hostAdapter,
      "visual_description": .providerBackedHostAdapter,
      "visual_comparison": .providerBackedHostAdapter,
      "live_camera": .permissionGatedHostAdapter,
      "orientation_query": .permissionGatedHostAdapter,
      "sense_observation": .embeddedDispatch,
    ]
  }

  private static func allAdvertisedHostCapabilities() throws -> Set<String> {
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
        orientationStatus: "prompt_required"),
    ]
    let capabilityLists = try manifests.map { manifest -> [String] in
      let object = try JSONValue.decodedObject(from: Data(manifest.utf8))
      return try XCTUnwrap(object["capabilities"]?.arrayValue).compactMap(\.stringValue)
    }
    return Set(capabilityLists.flatMap { $0 })
  }

  private static func frontendCaptureDiagnosticEvents(requestID: String) -> [BrainHostEvent] {
    let diagnostic = "Something went wrong while I tried that: FrontendCaptureRequested."
    return [
      BrainHostEvent(
        type: "chat_message",
        requestID: requestID,
        role: "brain",
        text: diagnostic,
        state: nil,
        enabled: nil,
        kind: nil,
        title: "Brain",
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil),
      BrainHostEvent(
        type: "speech_requested",
        requestID: requestID,
        role: nil,
        text: diagnostic,
        state: nil,
        enabled: nil,
        kind: nil,
        title: nil,
        body: nil,
        sense: nil,
        eyes: nil,
        mouth: nil,
        durationMS: nil,
        mediaKind: nil,
        path: nil,
        url: nil,
        mimeType: nil,
        caption: nil,
        rawRef: nil,
        originalBytes: nil)
    ]
  }

  private static func toolResponse(
    toolName: String,
    events: [BrainHostEvent] = [],
    requestID: String = UUID().uuidString
  ) -> BrainToolResponse {
    let envelope = BrainDispatchEnvelope(
      apiVersion: EmbeddedProtocolContract.apiVersion,
      requestID: requestID,
      ok: true,
      events: events,
      result: nil,
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

  private let toolResponse: BrainToolResponse
  private let textResponse: BrainTextResponse
  private let shortTouchResponse: BrainToolResponse
  private let orientationObservationResponse: BrainToolResponse
  private let cameraObservationResponse: BrainToolResponse
  private let cameraObservationDelayNanoseconds: UInt64
  private(set) var didConnect = false
  private(set) var didDisconnect = false
  private(set) var toolCalls: [ToolCall] = []
  private(set) var textCalls: [TextCall] = []
  private(set) var orientationObservations: [OrientationObservationCall] = []
  private(set) var cameraObservations: [CameraObservation] = []

  init(
    toolResponse: BrainToolResponse,
    textResponse: BrainTextResponse? = nil,
    shortTouchResponse: BrainToolResponse? = nil,
    orientationObservationResponse: BrainToolResponse? = nil,
    cameraObservationResponse: BrainToolResponse,
    cameraObservationDelayNanoseconds: UInt64 = 0
  ) {
    self.toolResponse = toolResponse
    self.textResponse = textResponse ?? BrainTextResponse(toolName: "typed_text", text: "", metadata: [:], events: [])
    self.shortTouchResponse = shortTouchResponse ?? toolResponse
    self.orientationObservationResponse = orientationObservationResponse ?? toolResponse
    self.cameraObservationResponse = cameraObservationResponse
    self.cameraObservationDelayNanoseconds = cameraObservationDelayNanoseconds
  }

  func connect() async throws {
    didConnect = true
  }

  func disconnect() async {
    didDisconnect = true
  }

  func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> BrainToolResponse {
    toolCalls.append(ToolCall(name: name, arguments: arguments))
    return toolResponse
  }

  func shortTouch() async throws -> BrainToolResponse {
    shortTouchResponse
  }

  func longTouch() async throws -> BrainToolResponse {
    toolResponse
  }

  func pokeSequence(_: [PokePulse]) async throws -> BrainToolResponse {
    toolResponse
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
    return textResponse
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
