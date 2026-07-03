//
//  BrainCore.swift
//  Affective
//

import Foundation
import os

/// Event types the core accepts into its stimulus inbox while another dispatch is active.
nonisolated enum BrainCoreIngestEligibleOperation: Sendable {
  static func contains(_ operation: String) -> Bool {
    switch operation {
    case "stimulus_ingest":
      return true
    default:
      return false
    }
  }
}

/// Event types the host may send without waiting behind the serial command lane.
nonisolated enum BrainCoreQueueableOperation: Sendable {
  static func contains(_ operation: String) -> Bool {
    BrainCoreIngestEligibleOperation.contains(operation)
      || operation == "host_update"
  }
}

protocol BrainCoreClient {
  func connect(progress: CoreLoadPerformanceSession?) async throws -> BrainDispatchEnvelope
  func disconnect() async
  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse
  func sendEvents(_ events: [BrainEvent]) async throws -> BrainToolResponse
  func hostAttach(
    hostID: String,
    platform: String,
    permissions: [String],
    capabilityIDs: [String],
    providerAvailability: String,
    sensorQuality: String,
    localPolicy: String
  ) async throws -> BrainToolResponse
  func hostCapabilityManifest(hostID: String, capabilityIDs: [String]) async throws -> BrainToolResponse
  func refreshFacialExpressionCatalog() async throws -> BrainToolResponse
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
  ) async throws -> BrainToolResponse
  func shortTouch(stimulusContext: StimulusContext?) async throws -> BrainToolResponse
  func longTouch(stimulusContext: StimulusContext?) async throws -> BrainToolResponse
  func pokeSequence(_ pulses: [PokePulse], stimulusContext: StimulusContext?) async throws -> BrainToolResponse
  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String?,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse
  func pushedMotionGestureObservation(
    _ observation: MotionGestureObservation,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse
  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation,
    precomputedIdentity: FaceRecognitionIdentityResult?,
    stimulusContext: StimulusContext?
  ) async throws -> BrainToolResponse
  func senseCatalog(
    senses: [PullSenseDescriptor],
    requestID: String?
  ) async throws -> BrainToolResponse
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
  ) async throws -> BrainToolResponse
  func capabilityStatus(
    capability: String,
    status: String,
    requestID: String?,
    pendingSince: Date?,
    pendingElapsedMS: Int,
    reason: String
  ) async throws -> BrainToolResponse
  func interrupt(
    userText: String,
    reason: String,
    interruptedAction: String?,
    canceledQueuedActionCount: Int
  ) async throws -> BrainToolResponse
  func ingestStimulus(_ operation: String, arguments: [String: JSONValue]) async throws -> BrainDispatchEnvelope
  func sendText(
    _ text: String,
    source: LanguageInputSource,
    attachments: [[String: JSONValue]],
    stimulusContext: StimulusContext?
  ) async throws -> BrainTextResponse
  func sendEmojiReaction(
    emoji: String,
    utteranceText: String,
    speakerLabel: String,
    utteranceEventID: String?
  ) async throws -> BrainTextResponse
  func brainMode() async throws -> BrainModeResponse
  func autonomyTick(stimulusContext: StimulusContext?) async throws -> BrainToolResponse
  func readModelsSnapshot() async throws -> BrainReadModelsSnapshotResponse
  func requestDreamTime(prompt: String?) async throws -> BrainMailboxResponse
  func mailboxList() async throws -> BrainMailboxListResponse
  func mailboxMarkRead(mailboxID: String) async throws -> BrainMailboxListResponse
  func exportBrain(to fileURL: URL) async throws -> BrainArchiveResponse
  func importBrain(from fileURL: URL, brainID: String?, brainRoot: URL, hostID: String?) async throws -> BrainArchiveResponse
  func setEventSinkHandler(_ handler: BrainCoreEventSink.Handler?) async
}

extension BrainCoreClient {
  func shortTouch() async throws -> BrainToolResponse {
    try await shortTouch(stimulusContext: nil)
  }

  func longTouch() async throws -> BrainToolResponse {
    try await longTouch(stimulusContext: nil)
  }

  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse {
    try await pokeSequence(pulses, stimulusContext: nil)
  }

  func autonomyTick() async throws -> BrainToolResponse {
    try await autonomyTick(stimulusContext: nil)
  }

  func syncConversationDispatchGeneration(_ generation: Int) async {}

  func setEventSinkHandler(_ handler: BrainCoreEventSink.Handler?) async {}

  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse {
    try await cameraObservation(
      path: path,
      mimeType: mimeType,
      source: source,
      requestID: requestID,
      presentation: presentation,
      precomputedIdentity: nil,
      stimulusContext: nil
    )
  }
}

actor BrainCore {
  nonisolated static let brainCoreLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "brain-core")
  nonisolated static let credentialStore = KeychainCredentialStore()

  let brain: BrainDescriptor
  private let tracksLiveFileSession: Bool

  nonisolated static func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private final class CoreSession: @unchecked Sendable {
      private var transport: BrainTransport?
      private var hostHTTPService: BrainHostHTTPService?

      init() {}

      deinit {
        if let transport {
          Task { await transport.disconnect() }
        }
      }

      var isConnected: Bool {
        transport != nil
      }

      func install(transport: BrainTransport, hostHTTPService: BrainHostHTTPService) {
        self.transport = transport
        self.hostHTTPService = hostHTTPService
      }

      func syncConversationDispatchGeneration(_ generation: Int) {
        hostHTTPService?.syncConversationDispatchGeneration(generation)
      }

      func beginUserTextDispatchFromCurrentConversationGeneration() {
        hostHTTPService?.beginUserTextDispatchFromCurrentConversationGeneration()
      }

      func disconnect() {
        if let transport {
          Task { await transport.disconnect() }
          self.transport = nil
          hostHTTPService = nil
        }
      }

      func disconnectAsync() async {
        if let transport {
          await transport.disconnect()
          self.transport = nil
          hostHTTPService = nil
        }
      }

      func drainEvents() async throws -> BrainDispatchEnvelope {
        guard let transport else {
          throw BrainCoreError.unavailable("Brain Session Protocol is not connected.")
        }
        return try await transport.drainEvents()
      }

      func dispatch(requestData: Data) async throws -> BrainDispatchEnvelope {
        guard let transport else {
          throw BrainCoreError.unavailable("Brain Session Protocol is not connected.")
        }
        return try await transport.dispatch(requestData)
      }
    }

    private let coreSession = CoreSession()
    private let messageBus = BrainCoreMessageBus()
    private let eventSink = BrainCoreEventSink()
    private var isConnecting = false
    private var holdsLiveFileSession = false

  init(brain: BrainDescriptor, tracksLiveFileSession: Bool = true) {
    self.brain = brain
    self.tracksLiveFileSession = tracksLiveFileSession
  }

  @discardableResult
  func connect(progress: CoreLoadPerformanceSession? = nil) async throws -> BrainDispatchEnvelope {
      try brain.validateForCoreConnection()
      if coreSession.isConnected {
        return BrainDispatchEnvelope(requestID: "", ok: true, events: [], result: nil, error: nil)
      }
      if isConnecting {
        return BrainDispatchEnvelope(requestID: "", ok: true, events: [], result: nil, error: nil)
      }
      isConnecting = true
      defer { isConnecting = false }

      if tracksLiveFileSession {
        if let progress {
          try progress.measureSync(id: "brain_session", label: "Reserving brain files") {
            try BrainFileAccessGate.acquireLiveSession(brainID: brain.id)
          }
        } else {
          try BrainFileAccessGate.acquireLiveSession(brainID: brain.id)
        }
        holdsLiveFileSession = true
      }

      let textProviderPreference = CoreConfigStorage.textProviderPreference(brain: brain)
      let storage = CoreConfigStorage(
        brain: brain,
        textProviderPreference: textProviderPreference
      )
      let hostHTTPService = BrainHostHTTPService(
        textProviderPreference: textProviderPreference,
        eventSink: eventSink
      )
      let transport = LoopbackTCPTransport(hostHTTPService: hostHTTPService)
      do {
        if let progress {
          _ = try await progress.measure(id: "bsp_session_create", label: "Starting brain session") {
            try await transport.connect(config: BrainSessionConfig(storage: storage))
          }
        } else {
          _ = try await transport.connect(config: BrainSessionConfig(storage: storage))
        }
        coreSession.install(transport: transport, hostHTTPService: hostHTTPService)
        let envelope: BrainDispatchEnvelope
        if let progress {
          envelope = try await progress.measure(id: "core_connect", label: "Connecting to core") {
            try await dispatchOperation("connect", arguments: [:])
          }
        } else {
          envelope = try await dispatchOperation("connect", arguments: [:])
        }
        try await attachCurrentHostBinding(
          manifestJSON: String(decoding: storage.hostManifestJSON, as: UTF8.self),
          progress: progress
        )
        return envelope
      } catch {
        await coreSession.disconnectAsync()
        if holdsLiveFileSession {
          BrainFileAccessGate.releaseLiveSession(brainID: brain.id)
          holdsLiveFileSession = false
        }
        throw error
      }
	  }

  func disconnect() async {
      await coreSession.disconnectAsync()
      if holdsLiveFileSession {
        BrainFileAccessGate.releaseLiveSession(brainID: brain.id)
        holdsLiveFileSession = false
      }
  }

  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse {
      try await ensureConnected()
      let envelope = try await dispatch(event: event, operation: event.type)
      return BrainToolResponse(toolName: event.type, envelope: envelope, rawText: envelope.rawText)
  }

  func sendEvents(_ events: [BrainEvent]) async throws -> BrainToolResponse {
      guard !events.isEmpty else {
        throw BrainCoreError.unavailable("sendEvents requires at least one event.")
      }
      var mergedEvents: [BrainEvent] = []
      var mergedMetadata: [String: String] = ["event_batch_count": "\(events.count)"]
      var rawText = ""
      for event in events {
        let response = try await sendEvent(event)
        mergedEvents.append(contentsOf: response.events)
        mergedMetadata.merge(response.metadata) { current, _ in current }
        rawText = response.rawText
      }
      return BrainToolResponse(
        toolName: "event_batch",
        text: "",
        metadata: mergedMetadata,
        events: mergedEvents,
        rawText: rawText
      )
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
      let envelope = try await dispatchOperation("host_update", arguments: [
        "kind": .string("host_attach"),
        "host_id": .string(hostID),
        "platform": .string(platform),
        "permissions": .array(permissions.map(JSONValue.string)),
        "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
        "provider_availability": .string(providerAvailability),
        "sensor_quality": .string(sensorQuality),
        "local_policy": .string(localPolicy),
      ])
      return BrainToolResponse(toolName: "host_update", envelope: envelope, rawText: envelope.rawText)
  }

  func hostCapabilityManifest(hostID: String, capabilityIDs: [String]) async throws -> BrainToolResponse {
      let envelope = try await dispatchOperation("host_update", arguments: [
        "kind": .string("capability_manifest"),
        "host_id": .string(hostID),
        "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
      ])
      return BrainToolResponse(toolName: "host_update", envelope: envelope, rawText: envelope.rawText)
  }

  func refreshFacialExpressionCatalog() async throws -> BrainToolResponse {
      let envelope = try await dispatchOperation("host_update", arguments: ["kind": .string("facial_expression_catalog")])
      return BrainToolResponse(toolName: "host_update", envelope: envelope, rawText: envelope.rawText)
  }

  func sendExperienceEvent(
    hostID: String? = nil,
    source: String = "host",
    kind: String,
    payload: String,
    salience: Double = 0.4,
    confidence: Double = 0.7,
    valence: Double = 0.0,
    arousal: Double = 0.0,
    uncertainty: Double = 0.3,
    causalParentIDs: [String] = [],
    retention: String = "episode",
    visibility: String = "internal"
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
      if let hostID, !hostID.isEmpty {
        arguments["host_id"] = .string(hostID)
      }
      arguments["kind"] = .string("experience_event")
      arguments["event_kind"] = .string(kind)
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: arguments)
      return BrainToolResponse(toolName: "stimulus_ingest", envelope: envelope, rawText: envelope.rawText)
  }

  func sendEmojiReaction(
    emoji: String,
    utteranceText: String,
    speakerLabel: String = "You",
    utteranceEventID: String? = nil
  ) async throws -> BrainTextResponse {
      try await ensureConnected()
      var arguments: [String: JSONValue] = [
        "emoji": .string(emoji),
        "utterance_text": .string(utteranceText),
        "speaker_label": .string(speakerLabel),
      ]
      if let utteranceEventID, !utteranceEventID.isEmpty {
        arguments["utterance_event_id"] = .string(utteranceEventID)
      }
      arguments["kind"] = .string("reaction")
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: arguments)
      let responseText = envelope.displayText
      var metadata = ["state": envelope.awaitingHostSenseStateLabel]
      metadata.merge(envelope.metadata()) { current, _ in current }
      metadata["display_source"] = responseText.isEmpty
        ? (envelope.awaitingHostSense ? "awaiting_host_sense" : "empty")
        : (envelope.displayTextFromEvents.isEmpty ? "result_value" : "event_envelope")
      metadata["display_text_length"] = "\(responseText.count)"
      return BrainTextResponse(
        toolName: "stimulus_ingest",
        text: responseText,
        metadata: metadata,
        events: envelope.events,
        shouldSpeak: !envelope.speechTexts.isEmpty
      )
  }

  private func attachCurrentHostBinding(
    manifestJSON: String,
    progress: CoreLoadPerformanceSession? = nil
  ) async throws {
    let manifest = try JSONValue.decodedObject(from: Data(manifestJSON.utf8))
    let hostID = Self.currentHostID()
    let platform = manifest["platform"]?.stringValue ?? "unknown"
    let capabilityIDs = manifest["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let permissions = Self.hostPermissionSummary(from: manifest)
    let providerAvailability = Self.compactJSONString(manifest["host_provider_routing"])
    let sensorQuality = Self.compactJSONString(.object([
      "sense_catalog": manifest["sense_catalog"] ?? .array([]),
      "capability_status": manifest["capability_status"] ?? .object([:]),
    ]))
    let localPolicy = Self.compactJSONString(.object([
      "biometric_policy": manifest["biometric_policy"] ?? .object([:]),
      "feature_flags": manifest["feature_flags"] ?? .object([:]),
    ]))

    if let progress {
      _ = try await progress.measure(id: "host_attach", label: "Attaching host") {
        try await hostAttach(
          hostID: hostID,
          platform: platform,
          permissions: permissions,
          capabilityIDs: capabilityIDs,
          providerAvailability: providerAvailability,
          sensorQuality: sensorQuality,
          localPolicy: localPolicy
        )
      }
    } else {
      _ = try await hostAttach(
        hostID: hostID,
        platform: platform,
        permissions: permissions,
        capabilityIDs: capabilityIDs,
        providerAvailability: providerAvailability,
        sensorQuality: sensorQuality,
        localPolicy: localPolicy
      )
    }
    if let progress {
      _ = try await progress.measure(id: "host_capability_manifest", label: "Publishing host capabilities") {
        let response = try await hostCapabilityManifest(hostID: hostID, capabilityIDs: capabilityIDs)
        progress.ingestDispatchTimings(from: response)
      }
    } else {
      _ = try await hostCapabilityManifest(hostID: hostID, capabilityIDs: capabilityIDs)
    }
    let statuses = manifest["capability_status"]?.objectValue ?? [:]
    let capabilityNames = statuses.keys.sorted()
    let batchEntries: [JSONValue] = capabilityNames.map { capability in
      let status = statuses[capability]?.stringValue ?? "unavailable"
      let metrics = Self.hostCapabilityMetrics(
        for: status,
        pendingElapsedMS: 0,
        reason: "host capability manifest"
      )
      let entry: [String: JSONValue] = [
        "capability_id": .string(capability),
        "host_id": .string(hostID),
        "permission": .string(metrics.permission),
        "availability": .string(metrics.availability),
        "quality": .number(metrics.quality),
        "reliability": .number(metrics.reliability),
        "cost": .number(metrics.cost),
        "latency_ms": .number(Double(metrics.latencyMS)),
        "risk": .number(metrics.risk),
        "unavailable_reason": .string(metrics.unavailableReason),
        "request_id": .string("host-attach-\(capability)"),
      ]
      return .object(entry)
    }
    if let progress {
      _ = try await progress.measure(id: "capability_status_batch", label: "Registering host capabilities") {
        _ = try await capabilityStatusBatch(statuses: batchEntries)
      }
    } else {
      _ = try await capabilityStatusBatch(statuses: batchEntries)
    }
  }

  private nonisolated static func currentHostID() -> String {
    let key = "Affective.hostBindingID"
    if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
      return existing
    }
    let created = "affective-host-\(UUID().uuidString)"
    UserDefaults.standard.set(created, forKey: key)
    return created
  }

  private nonisolated static func hostPermissionSummary(from manifest: [String: JSONValue]) -> [String] {
    let statuses = manifest["capability_status"]?.objectValue ?? [:]
    return statuses.keys.sorted().map { key in
      let value = statuses[key]?.stringValue ?? "unknown"
      return "\(key)=\(value)"
    }
  }

  private nonisolated static func compactJSONString(_ value: JSONValue?) -> String {
    guard let value, let data = try? value.encodedData() else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  func shortTouch(stimulusContext: StimulusContext? = nil) async throws -> BrainToolResponse {
      try await touchObservation(
        toolName: "short_touch",
        gesture: "short_touch",
        durationClass: "short",
        summary: "short touch",
        rawMagnitude: 0.45,
        stimulusContext: stimulusContext
      )
  }

  func longTouch(stimulusContext: StimulusContext? = nil) async throws -> BrainToolResponse {
      try await touchObservation(
        toolName: "long_touch",
        gesture: "long_touch",
        durationClass: "long",
        summary: "long touch",
        rawMagnitude: 0.65,
        stimulusContext: stimulusContext
      )
  }

  func pokeSequence(_ pulses: [PokePulse], stimulusContext: StimulusContext? = nil) async throws -> BrainToolResponse {
      try await ensureConnected()
      let pulseValues = pulses.map { pulse in
        JSONValue.object([
          "press_ms": .number(pulse.pressMilliseconds),
          "pause_before_ms": .number(pulse.pauseBeforeMilliseconds),
        ])
      }
      var arguments = Self.touchContext(
        gesture: "poke_sequence",
        durationClass: nil,
        stimulusContext: stimulusContext,
        extra: [
          "kind": .string("poke_sequence"),
          "summary": .string("poke sequence"),
          "payload": .string("poke sequence"),
          "pulses": .array(pulseValues),
        ]
      )
      arguments["raw_magnitude"] = .number(0.50)
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: arguments)
      return BrainToolResponse(toolName: "poke_sequence", envelope: envelope, rawText: envelope.rawText)
  }

  private func touchObservation(
    toolName: String,
    gesture: String,
    durationClass: String,
    summary: String,
    rawMagnitude: Double,
    stimulusContext: StimulusContext?
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var arguments = Self.touchContext(
        gesture: gesture,
        durationClass: durationClass,
        stimulusContext: stimulusContext,
        extra: [
          "kind": .string("touch"),
          "summary": .string(summary),
          "payload": .string(summary),
          "raw_magnitude": .number(rawMagnitude),
        ]
      )
      arguments["confidence"] = .number(1)
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: arguments)
      return BrainToolResponse(toolName: toolName, envelope: envelope, rawText: envelope.rawText)
  }

  private nonisolated static func touchContext(
    gesture: String,
    durationClass: String?,
    stimulusContext: StimulusContext?,
    extra: [String: JSONValue] = [:]
  ) -> [String: JSONValue] {
      var context: [String: JSONValue] = [
        "sense": .string("touch"),
        "sense_id": .string("touch"),
        "source": .string("button"),
        "gesture": .string(gesture),
        "input_channel": .string("physical_touch"),
        "social_signal": .bool(true),
      ]
      if let durationClass {
        context["duration_class"] = .string(durationClass)
      }
      if let stimulusContext {
        context["host_context"] = .object(stimulusContext.eventArguments)
      }
      context.merge(extra) { current, _ in current }
      return context
  }

  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String? = nil,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var observationPayload = observation.eventArguments
      observationPayload["kind"] = .string("orientation")
      observationPayload["summary"] = .string(observation.summary)
      observationPayload["payload"] = .string(observation.summary)
      observationPayload["observed_at"] = .string(Self.iso8601Now())
      if let requestID, !requestID.isEmpty { observationPayload["request_id"] = .string(requestID) }
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: observationPayload)
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func pushedMotionGestureObservation(
    _ observation: MotionGestureObservation,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var observationPayload = observation.eventArguments
      observationPayload["kind"] = .string("motion_gesture")
      observationPayload["summary"] = .string(observation.summary)
      observationPayload["payload"] = .string(observation.summary)
      observationPayload["observed_at"] = .string(Self.iso8601Now())
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: observationPayload)
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func cameraObservationIngest(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var observation: [String: JSONValue] = [
        "path": .string(path),
        "mime_type": .string(mimeType),
        "source": .string(source),
        "observed_at": .string(Self.iso8601Now()),
      ]
      if let requestID, !requestID.isEmpty {
        observation["request_id"] = .string(requestID)
      }
      observation["kind"] = .string("camera")
      let envelope = try await ingestStimulus("stimulus_ingest", arguments: observation)
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation = .internalOnly,
    precomputedIdentity: FaceRecognitionIdentityResult? = nil,
    stimulusContext: StimulusContext? = nil
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var observation: [String: JSONValue] = [
        "path": .string(path),
        "mime_type": .string(mimeType),
        "source": .string(source),
        "observed_at": .string(Self.iso8601Now()),
      ]
      if let requestID, !requestID.isEmpty {
        observation["request_id"] = .string(requestID)
      }
      if let precomputedIdentity {
        observation["host_identity"] = Self.identityJSONValue(precomputedIdentity)
      }
      if let stimulusContext {
        observation["host_context"] = .object(stimulusContext.eventArguments)
      }
      observation["kind"] = .string("camera")
      observation["summary"] = .string("camera image captured")
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: observation)
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func senseCatalog(
    senses: [PullSenseDescriptor],
    requestID: String?
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      let descriptors = senses.map {
        BrainCapabilityDescriptor(
          id: $0.senseID,
          status: $0.availability,
          reason: $0.statusReason
        )
      }
      let senseValues = descriptors.map { descriptor in
        JSONValue.object([
          "id": .string(descriptor.id),
          "status": .string(descriptor.status),
          "reason": .string(descriptor.reason ?? ""),
        ])
      }
      var arguments: [String: JSONValue] = [
        "kind": .string("sense_catalog"),
        "senses": .array(senseValues),
      ]
      if let requestID, !requestID.isEmpty { arguments["request_id"] = .string(requestID) }
      let envelope = try await dispatchOperation("host_update", arguments: arguments)
      return BrainToolResponse(toolName: "sense_catalog", envelope: envelope, rawText: envelope.rawText)
  }

  func pullSenseStatus(
    sense: String,
    direction: PullSenseDirection = .pull,
    status: PullSenseTerminalStatus,
    requestID: String?,
    timeoutMS: Int?,
    reason: String,
    availability: String?,
    permissionState: String?,
    terminal: Bool = true
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var arguments: [String: JSONValue] = [
        "kind": .string("sense_status"),
        "sense": .string(sense),
        "direction": .string(direction.rawValue),
        "status": .string(status.rawValue),
        "reason": .string([reason, timeoutMS.map { "timeout_ms=\($0)" }].compactMap { $0 }.joined(separator: " ")),
        "availability": .string(availability ?? status.rawValue),
        "permission_state": .string(permissionState ?? ""),
        "terminal": .bool(terminal),
      ]
      if let timeoutMS { arguments["timeout_ms"] = .number(Double(timeoutMS)) }
      if let requestID, !requestID.isEmpty { arguments["request_id"] = .string(requestID) }
      let envelope = try await dispatchOperation("host_update", arguments: arguments)
      return BrainToolResponse(toolName: "sense_status", envelope: envelope, rawText: envelope.rawText)
  }

  func capabilityStatus(
    capability: String,
    status: String,
    requestID: String?,
    pendingSince: Date?,
    pendingElapsedMS: Int,
    reason: String
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      let pendingReason = pendingSince.map {
        "\(reason) pending_since_unix_ms=\(($0.timeIntervalSince1970 * 1000).rounded()) pending_elapsed_ms=\(pendingElapsedMS)"
      } ?? "\(reason) pending_elapsed_ms=\(pendingElapsedMS)"
      let metrics = Self.hostCapabilityMetrics(for: status, pendingElapsedMS: pendingElapsedMS, reason: pendingReason)
      var arguments: [String: JSONValue] = [
        "kind": .string("capability_status"),
        "capability_id": .string(capability),
        "host_id": .string(Self.currentHostID()),
        "permission": .string(metrics.permission),
        "availability": .string(metrics.availability),
        "quality": .number(metrics.quality),
        "reliability": .number(metrics.reliability),
        "cost": .number(metrics.cost),
        "latency_ms": .number(Double(metrics.latencyMS)),
        "risk": .number(metrics.risk),
        "unavailable_reason": .string(metrics.unavailableReason),
      ]
      if let requestID, !requestID.isEmpty {
        arguments["request_id"] = .string(requestID)
      }
      let envelope = try await dispatchOperation("host_update", arguments: arguments)
      return BrainToolResponse(toolName: "capability_status", envelope: envelope, rawText: envelope.rawText)
  }

  func capabilityStatusBatch(statuses: [JSONValue]) async throws -> BrainToolResponse {
      try await ensureConnected()
      let envelope = try await dispatchOperation("host_update", arguments: [
        "kind": .string("capability_status_batch"),
        "host_id": .string(Self.currentHostID()),
        "statuses": .array(statuses),
      ])
      return BrainToolResponse(toolName: "capability_status_batch", envelope: envelope, rawText: envelope.rawText)
  }

	  private nonisolated static func hostCapabilityMetrics(
	    for status: String,
    pendingElapsedMS: Int,
    reason: String
  ) -> (
    permission: String,
    availability: String,
    quality: Double,
    reliability: Double,
    cost: Double,
    latencyMS: Int,
    risk: Double,
    unavailableReason: String
  ) {
    switch status {
    case "available":
      return ("granted", "available", 0.95, 0.90, 0.0, pendingElapsedMS, 0.05, "")
    case "prompt_required", "pending":
      return ("prompt_required", "degraded", 0.35, 0.45, 0.0, pendingElapsedMS, 0.25, reason)
    case "denied":
      return ("denied", "refused", 0.0, 0.0, 0.0, pendingElapsedMS, 0.70, reason)
    case "unavailable", "disabled", "disabled_by_policy":
      return ("unknown", "unavailable", 0.0, 0.0, 0.0, pendingElapsedMS, 0.55, reason)
    default:
	      return ("unknown", "unavailable", 0.0, 0.0, 0.0, pendingElapsedMS, 0.50, reason)
	    }
	  }

  private nonisolated static func canonicalPermission(from status: String?) -> String {
    switch status {
    case "available":
      return "granted"
    case "prompt_required", "pending":
      return "prompt_required"
    case "denied":
      return "denied"
    case "unavailable", "disabled", "disabled_by_policy":
      return "unknown"
    default:
      return "unknown"
    }
  }

  private nonisolated static func canonicalAvailability(from status: String?) -> String {
    switch status {
    case "available", "fulfilled":
      return "available"
    case "prompt_required", "pending":
      return "degraded"
    case "denied", "permission_denied":
      return "refused"
    default:
      return "unavailable"
    }
  }

  func interrupt(
    userText: String,
    reason: String,
    interruptedAction: String?,
    canceledQueuedActionCount: Int
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      var arguments: [String: JSONValue] = [
        "kind": .string("interrupt"),
        "text": .string(userText),
        "reason": .string(reason),
        "canceled_queued_action_count": .number(Double(canceledQueuedActionCount)),
      ]
      if let interruptedAction, !interruptedAction.isEmpty {
        arguments["interrupted_action"] = .string(interruptedAction)
      }
      let envelope = try await dispatchOperation("stimulus_ingest", arguments: arguments)
      return BrainToolResponse(toolName: "interrupt", envelope: envelope, rawText: envelope.rawText)
  }

  func sendText(
    _ text: String,
    source: LanguageInputSource = .typedText,
    attachments: [[String: JSONValue]] = [],
    stimulusContext: StimulusContext? = nil
  ) async throws -> BrainTextResponse {
      try await ensureConnected()
      coreSession.beginUserTextDispatchFromCurrentConversationGeneration()
      let envelope = try await dispatchOperation(
        "stimulus_ingest",
        arguments: Self.speechStimulusArguments(
          text: text,
          source: source,
          attachments: attachments,
          stimulusContext: stimulusContext
        )
      )
      let events = envelope.resolvedEvents()
      let responseText = envelope.displayText
      var metadata = ["state": envelope.awaitingHostSenseStateLabel]
      metadata.merge(envelope.metadata()) { current, _ in current }
      if envelope.events.isEmpty, !events.isEmpty {
        metadata["events_source"] = "synthetic_outcome_fallback"
      }
      metadata["display_source"] = responseText.isEmpty
        ? (envelope.awaitingHostSense ? "awaiting_host_sense" : "empty")
        : (envelope.displayTextFromEvents.isEmpty ? "result_value" : "event_envelope")
      metadata["display_text_length"] = "\(responseText.count)"
      let shouldSpeak = envelope.requiresHostSpeechPlayback
      return BrainTextResponse(
        toolName: "stimulus_ingest",
        text: responseText,
        metadata: metadata,
        events: events,
        shouldSpeak: shouldSpeak
      )
  }

  nonisolated static func speechStimulusArguments(
    text: String,
    source: LanguageInputSource = .typedText,
    attachments: [[String: JSONValue]] = [],
    stimulusContext: StimulusContext? = nil
  ) -> [String: JSONValue] {
      var arguments: [String: JSONValue] = [
        "kind": .string("speech"),
        "source": .string(source.rawValue),
        "text": .string(textByAppendingAttachmentMarkers(text, attachments: attachments)),
        "raw_magnitude": .number(attachments.isEmpty ? 0.85 : 0.90),
      ]
      if !attachments.isEmpty {
        arguments["attachments"] = .array(attachments.map { .object($0) })
      }
      if let stimulusContext {
        arguments["context"] = .object(stimulusContext.eventArguments)
      }
      return arguments
  }

  func requestDreamTime(prompt: String? = nil) async throws -> BrainMailboxResponse {
      var arguments = prompt.map { ["prompt": JSONValue.string($0)] } ?? [:]
      arguments["action"] = .string("request_dream_time")
      let envelope = try await dispatchOperation("mailbox_update", arguments: arguments)
      return try BrainMailboxResponse(toolName: "request_dream_time", envelope: envelope)
  }

  func brainMode() async throws -> BrainModeResponse {
      let envelope = try await dispatchOperation("brain_read", arguments: ["query": .string("brain_mode")])
      return try BrainModeResponse(toolName: "brain_mode", envelope: envelope)
  }

  func autonomyTick(stimulusContext: StimulusContext? = nil) async throws -> BrainToolResponse {
      var arguments: [String: JSONValue] = [:]
      if let stimulusContext {
        arguments["context"] = .object(stimulusContext.eventArguments)
      }
      let envelope = try await dispatchOperation("brain_step", arguments: arguments)
      return BrainToolResponse(toolName: "autonomy_tick", envelope: envelope, rawText: envelope.rawText)
  }

  func setEventSinkHandler(_ handler: BrainCoreEventSink.Handler?) {
      eventSink.setHandler(handler)
  }

  private func submitQueueableOperation(
    _ operation: String,
    arguments: [String: JSONValue]
  ) async throws -> BrainDispatchEnvelope {
      let queueKey = Self.queueableDispatchKey(operation: operation, eventObject: arguments)
      return try await messageBus.submitQueueable(key: queueKey) { [self] in
        try await self.dispatchOperationBody(operation, arguments: arguments)
      }
  }

  private func submitSerialOperation(
    _ operation: String,
    arguments: [String: JSONValue]
  ) async throws -> BrainDispatchEnvelope {
      try await messageBus.submitSerial { [self] in
        try await self.dispatchOperationBody(operation, arguments: arguments)
      }
  }

  func readModelsSnapshot() async throws -> BrainReadModelsSnapshotResponse {
      let envelope = try await dispatchOperation("brain_read", arguments: ["query": .string("models_snapshot")])
      return try BrainReadModelsSnapshotResponse(toolName: "read_models_snapshot", envelope: envelope)
  }

  func chatDryRunPrompt(text: String) async throws -> BrainChatDryRunPromptResponse {
      let envelope = try await dispatchOperation(
        "debug_prompt",
        arguments: ["text": .string(text)]
      )
      return try BrainChatDryRunPromptResponse(toolName: "chat_dry_run_prompt", envelope: envelope)
  }

  func mailboxList() async throws -> BrainMailboxListResponse {
      let envelope = try await dispatchOperation("mailbox_read", arguments: ["query": .string("list")])
      return try BrainMailboxListResponse(toolName: "mailbox_list", envelope: envelope)
  }

  func mailboxMarkRead(mailboxID: String) async throws -> BrainMailboxListResponse {
      let envelope = try await dispatchOperation(
        "mailbox_update",
        arguments: [
          "action": .string("mark_read"),
          "mailbox_id": .string(mailboxID),
        ]
      )
      return try BrainMailboxListResponse(toolName: "mailbox_mark_read", envelope: envelope)
  }

  func exportBrain(to fileURL: URL) async throws -> BrainArchiveResponse {
      let envelope = try await dispatchOperation(
        "brain_archive",
        arguments: [
          "action": .string("export"),
          "brain_file_path": .string(fileURL.path),
        ]
      )
      return try BrainArchiveResponse(toolName: "export_brain", envelope: envelope)
  }

  func importBrain(
    from fileURL: URL,
    brainID: String? = nil,
    brainRoot: URL,
    hostID: String? = nil
  ) async throws -> BrainArchiveResponse {
      var arguments: [String: JSONValue] = [
        "brain_file_path": .string(fileURL.path),
        "brain_root": .string(brainRoot.path),
      ]
      if let brainID, !brainID.isEmpty {
        arguments["brain_id"] = .string(brainID)
      }
      if let hostID, !hostID.isEmpty {
        arguments["host_id"] = .string(hostID)
      }
      arguments["action"] = .string("import")
      let envelope = try await dispatchOperation("brain_archive", arguments: arguments)
      return try BrainArchiveResponse(toolName: "import_brain", envelope: envelope)
  }

  nonisolated static func textByAppendingAttachmentMarkers(
    _ text: String,
    attachments: [[String: JSONValue]]
  ) -> String {
    let markers = attachments.compactMap(uploadedMediaMarker)
    guard !markers.isEmpty else { return text }
    return ([text] + markers).joined(separator: "\n")
  }

  private nonisolated static func uploadedMediaMarker(_ attachment: [String: JSONValue]) -> String? {
    guard
      attachment["kind"]?.stringValue == "image",
      let path = attachment["path"]?.stringValue
    else {
      return nil
    }
    let mimeType = attachment["mime_type"]?.stringValue ?? "image/jpeg"
    let source = attachment["source"]?.stringValue ?? "user_upload"
    return "[uploaded_media path=\"\(markerEscaped(path))\" mime_type=\"\(markerEscaped(mimeType))\" source=\"\(markerEscaped(source))\"]"
  }

  private nonisolated static func markerEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "]", with: "\\]")
  }

  func drainEvents() async throws -> [BrainEvent] {
      try await ensureConnected()
      let envelope = try await coreSession.drainEvents()
      guard envelope.ok else {
        let message = envelope.error?.message ?? "drain_events failed"
        throw BrainCoreError.unavailable(message)
      }
      return envelope.events
  }

  static func runGenerationProviderE2E(
    brain: BrainDescriptor,
    providerCredentials: [ProviderCredentialKey: String]? = nil
  ) throws -> String {
      _ = brain
      _ = providerCredentials
      throw BrainCoreError.unavailable("Generation provider E2E must run through the Brain Session Protocol harness.")
  }

    func ensureConnected() async throws {
      if !coreSession.isConnected {
        _ = try await connect(progress: nil)
      }
    }

    func syncConversationDispatchGeneration(_ generation: Int) async {
      coreSession.syncConversationDispatchGeneration(generation)
    }

    func ingestStimulus(_ operation: String, arguments: [String: JSONValue]) async throws -> BrainDispatchEnvelope {
      return try await submitQueueableOperation(operation, arguments: arguments)
    }

    func dispatchOperation(_ operation: String, arguments: [String: JSONValue]) async throws -> BrainDispatchEnvelope {
      if BrainCoreQueueableOperation.contains(operation) {
        return try await submitQueueableOperation(operation, arguments: arguments)
      }
      return try await submitSerialOperation(operation, arguments: arguments)
    }

    private func dispatchOperationBody(_ operation: String, arguments: [String: JSONValue]) async throws -> BrainDispatchEnvelope {
      try await ensureConnected()
      let requestID = UUID().uuidString
      var eventObject = arguments
      eventObject["type"] = .string(operation)
      let request: JSONValue = .object([
        "request_id": .string(requestID),
        "event": .object(eventObject),
      ])
      let requestData = try request.encodedData()
      Self.brainCoreLogger.info("Dispatch operation start operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) requestBytes=\(requestData.count, privacy: .public)")
      return try await dispatchPreparedRequest(operation: operation, requestData: requestData, requestID: requestID)
    }

    private static func identityJSONValue(_ identity: FaceRecognitionIdentityResult) -> JSONValue {
      var object: [String: JSONValue] = [
        "person_present": .bool(identity.personPresent),
        "match_status": .string(identity.matchStatus),
        "confidence": .number(Double(identity.confidence)),
        "people_count": .number(Double(identity.peopleCount)),
      ]
      if let personID = identity.personID {
        object["person_id"] = .string(personID)
      }
      if let candidateName = identity.candidateName {
        object["candidate_name"] = .string(candidateName)
      }
      return .object(object)
    }

    private func dispatchPreparedRequest(
      operation: String,
      requestData: Data,
      requestID: String
    ) async throws -> BrainDispatchEnvelope {
      try await ensureConnected()
      Self.brainCoreLogger.info("Dispatch start operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) requestBytes=\(requestData.count, privacy: .public)")
      let envelope = try await coreSession.dispatch(requestData: requestData)
      Self.brainCoreLogger.info("Dispatch result operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) ok=\(envelope.ok, privacy: .public) eventCount=\(envelope.events.count, privacy: .public)")
      guard envelope.ok else {
        let message = envelope.error?.message ?? "\(operation) failed"
        Self.brainCoreLogger.error("Dispatch envelope error operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) code=\(envelope.error?.code ?? "unknown", privacy: .public) message=\(message, privacy: .public)")
        throw BrainCoreError.unavailable(message)
      }
      if envelope.dispatchWasQueued {
        return envelope
      }
      return envelope
    }

    func dispatch(event: BrainEvent, operation: String) async throws -> BrainDispatchEnvelope {
      try await ensureConnected()
      let requestID = UUID().uuidString
      let encodedEventValue = try event.encodedJSONValue()
      let eventValue: JSONValue
      if case .object(var object) = encodedEventValue {
        object["type"] = .string(operation)
        if let payload = object["payload"]?.objectValue {
          if let experience = payload["experience"]?.objectValue {
            if object["text"] == nil, let text = experience["text"] {
              object["text"] = text
            }
            if let context = experience["context"]?.objectValue,
               object["pulses"] == nil,
               let pulses = context["pulses"] {
              object["pulses"] = pulses
            }
          }
          if let actionRequest = payload["capability_request"]?.objectValue {
            object["action"] = actionRequest["action"]
            object["arguments"] = actionRequest["arguments"]
            object["action_id"] = actionRequest["action_id"]
          }
          if let senseObservation = payload["sense_observation"]?.objectValue {
            object["sense"] = senseObservation["sense_id"]
            object["observation"] = senseObservation["value"]
          }
          if let capabilityStatus = payload["capability_status"]?.objectValue {
            object["capability_id"] = capabilityStatus["capability_id"]
            object["permission"] = capabilityStatus["permission"]
            object["availability"] = capabilityStatus["availability"]
            object["quality"] = capabilityStatus["quality"]
            object["reliability"] = capabilityStatus["reliability"]
            object["cost"] = capabilityStatus["cost"]
            object["latency_ms"] = capabilityStatus["latency_ms"]
            object["risk"] = capabilityStatus["risk"]
            object["unavailable_reason"] = capabilityStatus["unavailable_reason"]
            if operation == "sense_status" {
              object["status"] = capabilityStatus["status"]
              object["reason"] = capabilityStatus["reason"]
            }
          }
        }
        eventValue = .object(object)
      } else {
        eventValue = encodedEventValue
      }
      let request: JSONValue = .object([
        "request_id": .string(requestID),
        "event": eventValue,
      ])
      let requestData = try request.encodedData()
      let send: @Sendable () async throws -> BrainDispatchEnvelope = { [self] in
        try await self.dispatchPreparedRequest(operation: operation, requestData: requestData, requestID: requestID)
      }
      if BrainCoreQueueableOperation.contains(operation) {
        return try await messageBus.submitQueueable(
          key: Self.queueableDispatchKey(operation: operation, eventValue: eventValue),
          send
        )
      }
      return try await messageBus.submitSerial(send)
    }

    nonisolated static func queueableDispatchKey(
      operation: String,
      eventValue: JSONValue
    ) -> String {
      queueableDispatchKey(operation: operation, eventObject: eventValue.objectValue ?? [:])
    }

    nonisolated static func queueableDispatchKey(
      operation: String,
      eventObject: [String: JSONValue]
    ) -> String {
      if BrainCoreIngestEligibleOperation.contains(operation) {
        let kind = firstNonEmptyString(in: eventObject, keys: ["kind"]) ?? "stimulus"
        return "\(operation):\(kind):\(UUID().uuidString)"
      }
      if let sense = firstNonEmptyString(in: eventObject, keys: ["sense", "sense_id"]) {
        return "\(operation):sense:\(sense)"
      }
      if let capability = firstNonEmptyString(in: eventObject, keys: ["capability_id", "capability"]) {
        return "\(operation):capability:\(capability)"
      }
      if let action = firstNonEmptyString(in: eventObject, keys: ["action", "action_id"]) {
        return "\(operation):action:\(action)"
      }
      return operation
    }

    private nonisolated static func firstNonEmptyString(
      in object: [String: JSONValue],
      keys: [String]
    ) -> String? {
      for key in keys {
        guard let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
          continue
        }
        return value
      }
      return nil
    }

}

extension BrainCore: BrainCoreClient {}
