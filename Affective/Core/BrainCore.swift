//
//  BrainCore.swift
//  Affective
//

import Foundation
import os

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
  func shortTouch() async throws -> BrainToolResponse
  func longTouch() async throws -> BrainToolResponse
  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse
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
    presentation: BrainEventPresentation
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
  func autonomyTick() async throws -> BrainToolResponse
  func readModelsSnapshot() async throws -> BrainReadModelsSnapshotResponse
  func requestDreamTime(prompt: String?) async throws -> BrainMailboxResponse
  func mailboxList() async throws -> BrainMailboxListResponse
  func mailboxMarkRead(mailboxID: String) async throws -> BrainMailboxListResponse
  func exportBrain(to fileURL: URL) async throws -> BrainArchiveResponse
  func importBrain(from fileURL: URL, brainID: String?, brainRoot: URL, hostID: String?) async throws -> BrainArchiveResponse
}

actor BrainCore {
  nonisolated static let brainCoreLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "brain-core")
  nonisolated static let credentialStore = KeychainCredentialStore()
  nonisolated static let ffiLock = NSRecursiveLock()
  // Dedicated thread for synchronous engine dispatch. The embedded engine calls
  // back into the host (e.g. host LLM completion) and those callbacks block on a
  // DispatchSemaphore while a child Task runs. Blocking a Swift cooperative-pool
  // thread that way risks starving the pool (and trips the runtime's
  // "unsafeForcedSync called from Swift Concurrent context" diagnostic), so the
  // blocking FFI work runs here instead of on the actor's executor.
  // GCD worker threads use a ~512 KiB stack; conversation turns can exceed that
  // once memory, observations, and runtime actors are composed, so this thread
  // uses an explicit 8 MiB stack.
  nonisolated private static let ffiWorker = FFIWorker()

  private final class FFIWorker: @unchecked Sendable {
    private static let stackSize = 8 * 1024 * 1024

    private final class Bootstrap: @unchecked Sendable {
      weak var worker: FFIWorker?
    }

    private let thread: Thread
    private let bootstrap = Bootstrap()
    private var blocks: [() -> Void] = []
    private let lock = NSLock()
    private let workAvailable = DispatchSemaphore(value: 0)

    init() {
      let bootstrap = self.bootstrap
      let thread = Thread {
        guard let worker = bootstrap.worker else { return }
        while true {
          worker.workAvailable.wait()
          worker.lock.lock()
          if worker.blocks.isEmpty {
            worker.lock.unlock()
            continue
          }
          let block = worker.blocks.removeFirst()
          worker.lock.unlock()
          block()
        }
      }
      thread.stackSize = Self.stackSize
      thread.name = "com.zelda-built-this.AMBI.brain-core.ffi"
      thread.qualityOfService = .userInitiated
      self.thread = thread
      bootstrap.worker = self
      thread.start()
    }

    var isOnWorkerThread: Bool {
      Thread.current === thread
    }

    func async(_ block: @escaping () -> Void) {
      lock.lock()
      blocks.append(block)
      lock.unlock()
      workAvailable.signal()
    }

    func sync<T>(_ block: @escaping () -> T) -> T {
      if isOnWorkerThread {
        return block()
      }
      var result: T!
      let done = DispatchSemaphore(value: 0)
      async {
        result = block()
        done.signal()
      }
      done.wait()
      return result
    }
  }

  let brain: BrainDescriptor
  private let tracksLiveFileSession: Bool

  nonisolated static func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private final class CoreSession: @unchecked Sendable {
      private var handle: AffectiveCoreHandle?
      private var hostServices: EmbeddedHostServices?

      init() {}

      deinit {
        Self.destroyHandle(handle, onWorker: BrainCore.ffiWorker.isOnWorkerThread)
      }

      var isConnected: Bool {
        handle != nil
      }

      func install(handle: AffectiveCoreHandle, hostServices: EmbeddedHostServices) {
        self.handle = handle
        self.hostServices = hostServices
      }

      func disconnect() {
        guard let handleToDestroy = takeHandleForTeardown() else { return }
        Self.destroyHandle(handleToDestroy, onWorker: BrainCore.ffiWorker.isOnWorkerThread)
      }

      func disconnectAsync() async {
        guard let handleToDestroy = takeHandleForTeardown() else { return }
        await Self.destroyHandleAsync(handleToDestroy)
      }

      func drainEventsJSON() async -> AffectiveCoreCopiedResult {
        guard let activeHandle = handle else {
          return BrainCore.drainEventsJSON(nil)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<AffectiveCoreCopiedResult, Never>) in
          BrainCore.ffiWorker.async {
            let output = BrainCore.drainEventsJSON(activeHandle)
            continuation.resume(returning: output)
          }
        }
      }

      func dispatchJSON(requestData: Data) async -> AffectiveCoreCopiedResult {
        guard let activeHandle = handle else {
          return BrainCore.dispatchJSON(nil, requestJSON: nil, requestJSONLength: 0)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<AffectiveCoreCopiedResult, Never>) in
          BrainCore.ffiWorker.async {
            let output = requestData.withUnsafeBytes { requestBuffer in
              let requestPointer = requestBuffer.bindMemory(to: UInt8.self).baseAddress
              return BrainCore.dispatchJSON(
                activeHandle,
                requestJSON: requestPointer,
                requestJSONLength: requestData.count
              )
            }
            continuation.resume(returning: output)
          }
        }
      }

      private func takeHandleForTeardown() -> AffectiveCoreHandle? {
        let handleToDestroy = handle
        handle = nil
        hostServices = nil
        return handleToDestroy
      }

      private static func destroyHandle(_ handle: AffectiveCoreHandle?, onWorker: Bool) {
        guard let handle else { return }
        let destroy = {
          BrainCore.withFFI {
            affective_core_embedded_destroy(handle)
          }
        }
        if onWorker {
          destroy()
        } else {
          BrainCore.ffiWorker.sync(destroy)
        }
      }

      private static func destroyHandleAsync(_ handle: AffectiveCoreHandle) async {
        if BrainCore.ffiWorker.isOnWorkerThread {
          BrainCore.withFFI {
            affective_core_embedded_destroy(handle)
          }
          return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          BrainCore.ffiWorker.async {
            BrainCore.withFFI {
              affective_core_embedded_destroy(handle)
            }
            continuation.resume()
          }
        }
      }
    }

    private let coreSession = CoreSession()
    private var isConnecting = false
    private var holdsLiveFileSession = false
    private var dispatchInFlight = false
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []

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
      let hostServices = EmbeddedHostServices(textProviderPreference: textProviderPreference)
      do {
        let created: (status: Int32, handle: AffectiveCoreHandle?, errorMessage: String)
        if let progress {
          created = progress.measureSync(id: "embedded_create", label: "Starting embedded core") {
            storage.withConfig { config in
              withUnsafePointer(to: config) { pointer in
                hostServices.withHostServices { services in
                  withUnsafePointer(to: services) { servicesPointer in
                    Self.createCore(pointer, hostServices: servicesPointer)
                  }
                }
              }
            }
          }
        } else {
          created = storage.withConfig { config in
            withUnsafePointer(to: config) { pointer in
              hostServices.withHostServices { services in
                withUnsafePointer(to: services) { servicesPointer in
                  Self.createCore(pointer, hostServices: servicesPointer)
                }
              }
            }
          }
        }
        guard created.status == 0, let handle = created.handle else {
          throw BrainCoreError.unavailable(created.errorMessage)
        }
        coreSession.install(handle: handle, hostServices: hostServices)
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
      let envelope = try await dispatchOperation("host_attach", arguments: [
        "host_id": .string(hostID),
        "platform": .string(platform),
        "permissions": .array(permissions.map(JSONValue.string)),
        "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
        "provider_availability": .string(providerAvailability),
        "sensor_quality": .string(sensorQuality),
        "local_policy": .string(localPolicy),
      ])
      return BrainToolResponse(toolName: "host_attach", envelope: envelope, rawText: envelope.rawText)
  }

  func hostCapabilityManifest(hostID: String, capabilityIDs: [String]) async throws -> BrainToolResponse {
      let envelope = try await dispatchOperation("host_capability_manifest", arguments: [
        "host_id": .string(hostID),
        "capability_ids": .array(capabilityIDs.map(JSONValue.string)),
      ])
      return BrainToolResponse(toolName: "host_capability_manifest", envelope: envelope, rawText: envelope.rawText)
  }

  func refreshFacialExpressionCatalog() async throws -> BrainToolResponse {
      let envelope = try await dispatchOperation("refresh_facial_expression_catalog", arguments: [:])
      return BrainToolResponse(toolName: "refresh_facial_expression_catalog", envelope: envelope, rawText: envelope.rawText)
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
      let envelope = try await dispatchOperation("send_experience_event", arguments: arguments)
      return BrainToolResponse(toolName: "send_experience_event", envelope: envelope, rawText: envelope.rawText)
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
      let envelope = try await dispatchOperation("emoji_reaction", arguments: arguments)
      let responseText = envelope.displayText
      var metadata = ["state": envelope.awaitingHostSenseStateLabel]
      metadata.merge(envelope.metadata()) { current, _ in current }
      metadata["display_source"] = responseText.isEmpty
        ? (envelope.awaitingHostSense ? "awaiting_host_sense" : "empty")
        : (envelope.displayTextFromEvents.isEmpty ? "result_value" : "event_envelope")
      metadata["display_text_length"] = "\(responseText.count)"
      return BrainTextResponse(
        toolName: "emoji_reaction",
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

  func shortTouch() async throws -> BrainToolResponse {
      try await ensureConnected()
      let event = BrainEvent.hostEvent(
        payload: .experience(BrainExperiencePayload(
          kind: "short_touch",
          modality: .structured,
          role: .other,
          text: "short touch",
          media: [],
          context: nil
        )),
        visibility: .public,
        presentation: .chat
      )
      let envelope = try await dispatch(event: event, operation: "short_touch")
      return BrainToolResponse(toolName: "short_touch", envelope: envelope, rawText: envelope.rawText)
  }

  func longTouch() async throws -> BrainToolResponse {
      try await ensureConnected()
      let event = BrainEvent.hostEvent(
        payload: .experience(BrainExperiencePayload(
          kind: "long_touch",
          modality: .structured,
          role: .other,
          text: "long touch",
          media: [],
          context: nil
        )),
        visibility: .public,
        presentation: .chat
      )
      let envelope = try await dispatch(event: event, operation: "long_touch")
      return BrainToolResponse(toolName: "long_touch", envelope: envelope, rawText: envelope.rawText)
  }

  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse {
      try await ensureConnected()
      let pulseValues = pulses.map { pulse in
        JSONValue.object([
          "press_ms": .number(pulse.pressMilliseconds),
          "pause_before_ms": .number(pulse.pauseBeforeMilliseconds),
        ])
      }
      let event = BrainEvent.hostEvent(
        payload: .experience(BrainExperiencePayload(
          kind: "poke_sequence",
          modality: .structured,
          role: .other,
          text: "poke sequence",
          media: [],
          context: .object(["pulses": .array(pulseValues)])
        )),
        visibility: .public,
        presentation: .chat
      )
      let envelope = try await dispatch(event: event, operation: "poke_sequence")
      return BrainToolResponse(toolName: "poke_sequence", envelope: envelope, rawText: envelope.rawText)
  }

  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String? = nil,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      let observedAt = Self.iso8601Now()
      var observationPayload = observation.eventArguments
      observationPayload["observed_at"] = .string(observedAt)
      let event = BrainEvent.hostEvent(
        payload: .senseObservation(BrainSenseObservationPayload(
          senseID: "orientation",
          modality: .structured,
          summary: observation.summary,
          media: [],
          value: .object(observationPayload),
          confidence: nil,
          observedAt: observedAt
        )),
        presentation: presentation,
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "sense_observation")
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func pushedMotionGestureObservation(
    _ observation: MotionGestureObservation,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
      try await ensureConnected()
      let observedAt = Self.iso8601Now()
      var observationPayload = observation.eventArguments
      observationPayload["observed_at"] = .string(observedAt)
      let event = BrainEvent.hostEvent(
        payload: .senseObservation(BrainSenseObservationPayload(
          senseID: "motion_gesture",
          modality: .structured,
          summary: observation.summary,
          media: [],
          value: .object(observationPayload),
          confidence: nil,
          observedAt: observedAt
        )),
        presentation: presentation
      )
      let envelope = try await dispatch(event: event, operation: "sense_observation")
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
  }

  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation = .internalOnly
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
      let observedAt = observation["observed_at"]?.stringValue ?? Self.iso8601Now()
      let event = BrainEvent.hostEvent(
        payload: .senseObservation(BrainSenseObservationPayload(
          senseID: "camera",
          modality: .image,
          summary: "camera image captured",
          media: [BrainMediaRef(kind: .image, path: path, url: nil, mimeType: mimeType, caption: source)],
          value: .object(observation),
          confidence: nil,
          observedAt: observedAt
        )),
        presentation: presentation,
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "sense_observation")
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
      let event = BrainEvent.hostEvent(
        payload: .capabilityManifest(BrainCapabilityManifestPayload(
          capabilities: [],
          senses: descriptors
        )),
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "sense_catalog")
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
      let event = BrainEvent.hostEvent(
        payload: .capabilityStatus(BrainCapabilityStatusPayload(
          capabilityID: "\(sense)_read",
          status: status.rawValue,
          reason: [reason, timeoutMS.map { "timeout_ms=\($0)" }].compactMap { $0 }.joined(separator: " "),
          permission: Self.canonicalPermission(from: permissionState ?? availability),
          availability: Self.canonicalAvailability(from: availability ?? status.rawValue),
          quality: status == .fulfilled ? 0.85 : 0.0,
          reliability: status == .fulfilled ? 0.80 : 0.0,
          cost: 0.0,
          latencyMS: timeoutMS,
          risk: status == .fulfilled ? 0.05 : 0.40,
          unavailableReason: status == .fulfilled ? "" : reason
        )),
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "sense_status")
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
      let envelope = try await dispatchOperation("capability_status", arguments: arguments)
      return BrainToolResponse(toolName: "capability_status", envelope: envelope, rawText: envelope.rawText)
  }

  func capabilityStatusBatch(statuses: [JSONValue]) async throws -> BrainToolResponse {
      try await ensureConnected()
      let envelope = try await dispatchOperation("capability_status_batch", arguments: [
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
    case "unavailable", "disabled_by_policy":
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
    case "unavailable", "disabled_by_policy":
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
      var context: [String: JSONValue] = [
        "reason": .string(reason),
        "canceled_queued_action_count": .number(Double(canceledQueuedActionCount)),
      ]
      if let interruptedAction, !interruptedAction.isEmpty {
        context["interrupted_action"] = .string(interruptedAction)
      }
      let event = BrainEvent.hostEvent(
        payload: .experience(BrainExperiencePayload(
          kind: "user_interrupt_message",
          modality: .text,
          role: .other,
          text: userText,
          media: [],
          context: .object(context)
        )),
        visibility: .public,
        presentation: .chat
      )
      let envelope = try await dispatch(event: event, operation: "interrupt")
      return BrainToolResponse(toolName: "interrupt", envelope: envelope, rawText: envelope.rawText)
  }

  func sendText(
    _ text: String,
    source: LanguageInputSource = .typedText,
    attachments: [[String: JSONValue]] = [],
    stimulusContext: StimulusContext? = nil
  ) async throws -> BrainTextResponse {
      try await ensureConnected()
      let conversationText = Self.textByAppendingAttachmentMarkers(text, attachments: attachments)
      let envelope = try await dispatchOperation(
        "user_text",
        arguments: ["text": .string(conversationText)]
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
      let shouldSpeak = !envelope.speechTexts.isEmpty || events.contains { $0.capability == "speak" }
      return BrainTextResponse(
        toolName: "user_text",
        text: responseText,
        metadata: metadata,
        events: events,
        shouldSpeak: shouldSpeak
      )
  }

  func requestDreamTime(prompt: String? = nil) async throws -> BrainMailboxResponse {
      let envelope = try await dispatchOperation(
        "request_dream_time",
        arguments: prompt.map { ["text": .string($0)] } ?? [:]
      )
      return try BrainMailboxResponse(toolName: "request_dream_time", envelope: envelope)
  }

  func brainMode() async throws -> BrainModeResponse {
      let envelope = try await dispatchOperation("brain_mode", arguments: [:])
      return try BrainModeResponse(toolName: "brain_mode", envelope: envelope)
  }

  func autonomyTick() async throws -> BrainToolResponse {
      let envelope = try await dispatchOperation("autonomy_tick", arguments: [:])
      return BrainToolResponse(toolName: "autonomy_tick", envelope: envelope, rawText: envelope.rawText)
  }

  func readModelsSnapshot() async throws -> BrainReadModelsSnapshotResponse {
      let envelope = try await dispatchOperation("read_models_snapshot", arguments: [:])
      return try BrainReadModelsSnapshotResponse(toolName: "read_models_snapshot", envelope: envelope)
  }

  func chatDryRunPrompt(text: String) async throws -> BrainChatDryRunPromptResponse {
      let envelope = try await dispatchOperation(
        "chat_dry_run_prompt",
        arguments: ["text": .string(text)]
      )
      return try BrainChatDryRunPromptResponse(toolName: "chat_dry_run_prompt", envelope: envelope)
  }

  func mailboxList() async throws -> BrainMailboxListResponse {
      let envelope = try await dispatchOperation("mailbox_list", arguments: [:])
      return try BrainMailboxListResponse(toolName: "mailbox_list", envelope: envelope)
  }

  func mailboxMarkRead(mailboxID: String) async throws -> BrainMailboxListResponse {
      let envelope = try await dispatchOperation(
        "mailbox_mark_read",
        arguments: ["mailbox_id": .string(mailboxID)]
      )
      return try BrainMailboxListResponse(toolName: "mailbox_mark_read", envelope: envelope)
  }

  func exportBrain(to fileURL: URL) async throws -> BrainArchiveResponse {
      let envelope = try await dispatchOperation(
        "export_brain",
        arguments: ["brain_file_path": .string(fileURL.path)]
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
      let envelope = try await dispatchOperation("import_brain", arguments: arguments)
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
      let output = await coreSession.drainEventsJSON()
      let text = try Self.checkedCopiedString(output, operation: "drain_events")
      let envelope = try BrainDispatchEnvelope.decode(from: text)
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
      try brain.validateForCoreConnection()
      let storage = CoreConfigStorage(
        brain: brain,
        providerCredentials: providerCredentials,
        textProviderPreference: .random
      )
      let explicitProviderCredentials = providerCredentials
      let hostServices = EmbeddedHostServices(
        credentialProvider: { explicitProviderCredentials ?? CoreConfigStorage.providerCredentials() },
        textProviderPreference: .random
      )
      let result = storage.withConfig { config in
        withUnsafePointer(to: config) { pointer in
          hostServices.withHostServices { services in
            withUnsafePointer(to: services) { servicesPointer in
              Self.withCopiedResult(operation: "api_e2e") { data, errorMessage in
                affective_core_embedded_api_e2e(pointer, servicesPointer, &data, &errorMessage)
              }
            }
          }
        }
      }
      return try checkedCopiedString(result, operation: "api_e2e")
  }

    func ensureConnected() async throws {
      if !coreSession.isConnected {
        _ = try await connect(progress: nil)
      }
    }

    func dispatchOperation(_ operation: String, arguments: [String: JSONValue]) async throws -> BrainDispatchEnvelope {
      await acquireDispatchTurn()
      defer { releaseDispatchTurn() }
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
      let output = await coreSession.dispatchJSON(requestData: requestData)
      Self.brainCoreLogger.info("Dispatch operation result operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) status=\(output.status, privacy: .public) dataBytes=\(output.dataBytes, privacy: .public) errorBytes=\(output.errorBytes, privacy: .public)")
      let text = try Self.checkedCopiedString(output, operation: operation)
      let envelope = try BrainDispatchEnvelope.decode(from: text)
      guard envelope.ok else {
        let message = envelope.error?.message ?? "\(operation) failed"
        Self.brainCoreLogger.error("Dispatch operation envelope error operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) code=\(envelope.error?.code ?? "unknown", privacy: .public) message=\(message, privacy: .public)")
        throw BrainCoreError.unavailable(message)
      }
      return try await mergeDrainedEvents(into: envelope)
    }

    private func acquireDispatchTurn() async {
      while true {
        if !dispatchInFlight {
          dispatchInFlight = true
          return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          dispatchWaiters.append(continuation)
        }
      }
    }

    private func releaseDispatchTurn() {
      if dispatchWaiters.isEmpty {
        dispatchInFlight = false
        return
      }
      let next = dispatchWaiters.removeFirst()
      next.resume()
    }

    func dispatch(event: BrainEvent, operation: String) async throws -> BrainDispatchEnvelope {
      await acquireDispatchTurn()
      defer { releaseDispatchTurn() }
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
      Self.brainCoreLogger.info("Dispatch start operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) requestBytes=\(requestData.count, privacy: .public)")
      let output = await coreSession.dispatchJSON(requestData: requestData)
      Self.brainCoreLogger.info("Dispatch result operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) status=\(output.status, privacy: .public) dataBytes=\(output.dataBytes, privacy: .public) errorBytes=\(output.errorBytes, privacy: .public)")
		      let text = try Self.checkedCopiedString(output, operation: operation)
		      let envelope = try BrainDispatchEnvelope.decode(from: text)
		      guard envelope.ok else {
		        let message = envelope.error?.message ?? "\(operation) failed"
		        Self.brainCoreLogger.error("Dispatch envelope error operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) code=\(envelope.error?.code ?? "unknown", privacy: .public) message=\(message, privacy: .public)")
		        throw BrainCoreError.unavailable(message)
	      }
      return try await mergeDrainedEvents(into: envelope)
    }

    private func mergeDrainedEvents(into envelope: BrainDispatchEnvelope) async throws -> BrainDispatchEnvelope {
      let drained = try await drainAllEvents()
      guard !drained.isEmpty else { return envelope }
      return BrainDispatchEnvelope(
        requestID: envelope.requestID,
        ok: envelope.ok,
        events: envelope.events + drained,
        result: envelope.result,
        error: envelope.error,
        budget: envelope.budget,
        timings: envelope.timings,
        rawText: envelope.rawText
      )
    }

    private func drainAllEvents() async throws -> [BrainEvent] {
      var merged: [BrainEvent] = []
      for _ in 0..<32 {
        let batch = try await drainEvents()
        if batch.isEmpty { break }
        merged.append(contentsOf: batch)
      }
      return merged
    }

		    static func checkedCopiedString(_ result: AffectiveCoreCopiedResult, operation: String)
	      throws -> String
	    {
      guard result.status == 0 else {
        let message = result.errorMessage
        throw BrainCoreError.unavailable(message.isEmpty ? "\(operation) failed" : message)
      }
      return result.data
    }

	    static func withFFI<Result>(_ body: () -> Result) -> Result {
	      ffiLock.lock()
	      defer { ffiLock.unlock() }
	      return body()
	    }

    static func createCore(
      _ config: UnsafePointer<AffectiveCoreEmbeddedConfig>?,
      hostServices: UnsafePointer<AffectiveCoreEmbeddedHostServices>?
    ) -> (
      status: Int32,
      handle: AffectiveCoreHandle?,
      errorMessage: String
    ) {
      withFFI {
        var handle: AffectiveCoreHandle?
        var errorMessage = AffectiveCoreEmbeddedString(ptr: nil, len: 0)
        let status = affective_core_embedded_create(config, hostServices, &handle, &errorMessage)
        defer { affective_core_embedded_free_global_string(errorMessage) }
        return (status, handle, string(from: errorMessage))
      }
    }

    static func dispatchJSON(
      _ handle: AffectiveCoreHandle?,
      requestJSON: UnsafePointer<UInt8>?,
      requestJSONLength: Int
    ) -> AffectiveCoreCopiedResult {
      withCopiedResult(operation: "dispatch_json") { data, errorMessage in
        affective_core_embedded_dispatch_json(
          handle,
          requestJSON,
          requestJSONLength,
          &data,
          &errorMessage
        )
      }
    }

    static func drainEventsJSON(_ handle: AffectiveCoreHandle?) -> AffectiveCoreCopiedResult {
      withCopiedResult(operation: "drain_events") { data, errorMessage in
        affective_core_embedded_drain_events_json(handle, &data, &errorMessage)
      }
    }

    static func withCopiedResult(
      operation _: String,
      _ body: (inout AffectiveCoreEmbeddedString, inout AffectiveCoreEmbeddedString) -> Int32
    ) -> AffectiveCoreCopiedResult {
      withFFI {
        var data = AffectiveCoreEmbeddedString(ptr: nil, len: 0)
        var errorMessage = AffectiveCoreEmbeddedString(ptr: nil, len: 0)
        let status = body(&data, &errorMessage)
        defer {
          affective_core_embedded_free_global_string(data)
          affective_core_embedded_free_global_string(errorMessage)
        }
        return AffectiveCoreCopiedResult(
          status: status,
          data: string(from: data),
          errorMessage: string(from: errorMessage),
          dataBytes: data.len,
          errorBytes: errorMessage.len
        )
      }
    }

    static func string(from value: AffectiveCoreEmbeddedString) -> String {
      guard let ptr = value.ptr, value.len > 0 else {
        return ""
      }
      let buffer = UnsafeBufferPointer(start: ptr, count: value.len)
      return String(decoding: buffer, as: UTF8.self)
    }
}

extension BrainCore: BrainCoreClient {}
