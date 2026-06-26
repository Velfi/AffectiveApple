//
//  BrainCore.swift
//  Affective
//

import Foundation
import os

protocol BrainCoreClient {
  func connect() async throws
  func disconnect() async
  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse
  func sendEvents(_ events: [BrainEvent]) async throws -> BrainToolResponse
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
  func hostCapabilityStatus(
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
  func refreshState() async throws -> BrainStateSnapshot
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
  nonisolated static let ffiQueue = DispatchQueue(label: "com.zelda-built-this.AMBI.brain-core.ffi")
  let brain: BrainDescriptor

  nonisolated static func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  #if os(iOS) || os(macOS)
    private final class CoreSession: @unchecked Sendable {
      private let queue: DispatchQueue
      private var handle: AffectiveCoreHandle?
      private var hostServices: EmbeddedHostServices?
      private static let queueKey = DispatchSpecificKey<Bool>()

      init(queue: DispatchQueue = BrainCore.ffiQueue) {
        self.queue = queue
        self.queue.setSpecific(key: Self.queueKey, value: true)
      }

      deinit {
        disconnect()
      }

      var isConnected: Bool {
        handle != nil
      }

      func install(handle: AffectiveCoreHandle, hostServices: EmbeddedHostServices) {
        self.handle = handle
        self.hostServices = hostServices
      }

      func disconnect() {
        let destroy = { [self] in
          guard let handle else {
            hostServices = nil
            return
          }
          BrainCore.withFFI {
            affective_core_embedded_destroy(handle)
          }
          self.handle = nil
          hostServices = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
          destroy()
        } else {
          queue.sync(execute: destroy)
        }
      }

      func introspect() -> AffectiveCoreCopiedResult {
        queue.sync { [self] in
          BrainCore.introspect(handle)
        }
      }

      func drainEventsJSON() -> AffectiveCoreCopiedResult {
        queue.sync { [self] in
          BrainCore.drainEventsJSON(handle)
        }
      }

      func dispatchJSON(requestData: Data) async -> AffectiveCoreCopiedResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<AffectiveCoreCopiedResult, Never>) in
          queue.async { [self, requestData] in
            let output = requestData.withUnsafeBytes { requestBuffer in
              let requestPointer = requestBuffer.bindMemory(to: UInt8.self).baseAddress
              return BrainCore.dispatchJSON(handle, requestJSON: requestPointer, requestJSONLength: requestData.count)
            }
            continuation.resume(returning: output)
          }
        }
      }
    }

    private let coreSession = CoreSession()
  #endif

  init(brain: BrainDescriptor) {
    self.brain = brain
  }

  func connect() async throws {
    try brain.validateForCoreConnection()

    #if os(iOS) || os(macOS)
      if coreSession.isConnected {
        return
      }

      let textProviderPreference = CoreConfigStorage.textProviderPreference(brain: brain)
      let storage = CoreConfigStorage(
        brain: brain,
        textProviderPreference: textProviderPreference
      )
      let hostServices = EmbeddedHostServices(textProviderPreference: textProviderPreference)
      let created = storage.withConfig { config in
        withUnsafePointer(to: config) { pointer in
          hostServices.withHostServices { services in
            withUnsafePointer(to: services) { servicesPointer in
              Self.createCore(pointer, hostServices: servicesPointer)
            }
          }
        }
      }
      guard created.status == 0, let handle = created.handle else {
        throw BrainCoreError.unavailable(created.errorMessage)
      }
      coreSession.install(handle: handle, hostServices: hostServices)
    #else
      throw unavailable()
    #endif
  }

  func disconnect() async {
    #if os(iOS) || os(macOS)
      coreSession.disconnect()
    #endif
  }

  func sendEvent(_ event: BrainEvent) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let envelope = try await dispatch(event: event, operation: event.type)
      return BrainToolResponse(toolName: event.type, envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: event.type)
    #endif
  }

  func sendEvents(_ events: [BrainEvent]) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      guard let first = events.first else {
        throw BrainCoreError.unavailable("sendEvents requires at least one event.")
      }
      try await ensureConnected()
      let eventValues = try events.map { try $0.encodedJSONValue() }
      let batch = BrainEvent.hostEvent(
        payload: .actionRequest(BrainActionRequestPayload(
          actionID: UUID().uuidString,
          action: "event_batch",
          arguments: .object(["events": .array(eventValues)]),
          requires: [],
          awaitResponse: true
        )),
        target: first.target,
        visibility: first.visibility,
        presentation: first.presentation,
        traceID: first.traceID,
        turnID: first.turnID,
        loopID: first.loopID
      )
      let envelope = try await dispatch(event: batch, operation: "event_batch")
      return BrainToolResponse(toolName: "event_batch", envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: "event_batch")
    #endif
  }

  func shortTouch() async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "short_touch")
    #endif
  }

  func longTouch() async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "long_touch")
    #endif
  }

  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "poke_sequence")
    #endif
  }

  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String? = nil,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "sense_observation")
    #endif
  }

  func pushedMotionGestureObservation(
    _ observation: MotionGestureObservation,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "sense_observation")
    #endif
  }

  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation = .internalOnly
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "sense_observation")
    #endif
  }

  func senseCatalog(
    senses: [PullSenseDescriptor],
    requestID: String?
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "sense_catalog")
    #endif
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
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let event = BrainEvent.hostEvent(
        payload: .capabilityStatus(BrainCapabilityStatusPayload(
          capabilityID: "\(sense)_read",
          status: status.rawValue,
          reason: [reason, timeoutMS.map { "timeout_ms=\($0)" }].compactMap { $0 }.joined(separator: " "),
          permissionState: permissionState ?? availability
        )),
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "sense_status")
      return BrainToolResponse(toolName: "sense_status", envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: "sense_status")
    #endif
  }

  func hostCapabilityStatus(
    capability: String,
    status: String,
    requestID: String?,
    pendingSince: Date?,
    pendingElapsedMS: Int,
    reason: String
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let pendingReason = pendingSince.map {
        "\(reason) pending_since_unix_ms=\(($0.timeIntervalSince1970 * 1000).rounded()) pending_elapsed_ms=\(pendingElapsedMS)"
      } ?? "\(reason) pending_elapsed_ms=\(pendingElapsedMS)"
      let event = BrainEvent.hostEvent(
        payload: .capabilityStatus(BrainCapabilityStatusPayload(
          capabilityID: capability,
          status: status,
          reason: pendingReason,
          permissionState: status
        )),
        traceID: requestID ?? UUID().uuidString,
        parentID: requestID
      )
      let envelope = try await dispatch(event: event, operation: "host_capability_status")
      return BrainToolResponse(toolName: "host_capability_status", envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: "host_capability_status")
    #endif
  }

  func interrupt(
    userText: String,
    reason: String,
    interruptedAction: String?,
    canceledQueuedActionCount: Int
  ) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
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
    #else
      throw unavailable(operation: "interrupt")
    #endif
  }

  func sendText(
    _ text: String,
    source: LanguageInputSource = .typedText,
    attachments: [[String: JSONValue]] = [],
    stimulusContext: StimulusContext? = nil
  ) async throws -> BrainTextResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let media = attachments.compactMap { attachment -> BrainMediaRef? in
        guard let kind = attachment["kind"]?.stringValue else { return nil }
        let modality = BrainEventModality(rawValue: kind) ?? .media
        return BrainMediaRef(
          kind: modality,
          path: attachment["path"]?.stringValue,
          url: attachment["url"]?.stringValue,
          mimeType: attachment["mime_type"]?.stringValue,
          caption: attachment["caption"]?.stringValue ?? attachment["source"]?.stringValue
        )
      }
      var contextObject: [String: JSONValue] = [
        "source": .string(source.rawValue),
        "perception": .string("heard_language"),
      ]
      if !attachments.isEmpty {
        contextObject["attachments"] = .array(attachments.map { .object($0) })
      }
      if let stimulusContext {
        contextObject["stimulus_context"] = .object(stimulusContext.eventArguments)
      }
      let event = BrainEvent.hostEvent(
        payload: .experience(BrainExperiencePayload(
          kind: source.eventType,
          modality: media.isEmpty ? .text : .media,
          role: .other,
          text: Self.textByAppendingAttachmentMarkers(text, attachments: attachments),
          media: media,
          context: .object(contextObject)
        )),
        visibility: .public,
        presentation: .chat,
        turnID: UUID().uuidString
      )
      let envelope = try await dispatch(event: event, operation: source.eventType)
      let legacyJSON = envelope.conversationTurnJSON
      let turn = legacyJSON.flatMap(ConversationTurnPayload.decode)
      if turn?.isTestEchoResponse == true {
        throw BrainCoreError.unavailable(
          "The embedded core selected its test echo chat service instead of a configured model provider."
        )
      }
      let eventText = envelope.displayTextFromEvents
      let summaryText = envelope.resultRawResult == false ? (envelope.resultSummary ?? "") : ""
      let responseText = eventText.isEmpty ? summaryText : eventText
      var metadata = ["state": "mutating turn"]
      metadata.merge(envelope.metadata()) { current, _ in current }
      metadata["display_source"] = eventText.isEmpty
        ? (summaryText.isEmpty ? "empty" : "result_summary")
        : "event_envelope"
      metadata["display_text_length"] = "\(responseText.count)"
      metadata["raw_json_length"] = "\(legacyJSON?.count ?? 0)"
      return BrainTextResponse(
        toolName: "conversation_turn",
        text: responseText,
        metadata: metadata,
        events: envelope.events
      )
    #else
      throw unavailable(operation: "conversation_turn")
    #endif
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

  func refreshState() async throws -> BrainStateSnapshot {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let result = coreSession.introspect()
      let text = try Self.checkedCopiedString(result, operation: "introspect")
      let envelope = try BrainDispatchEnvelope.decode(from: text)
      let displayText = envelope.resultSummary ?? text
      var metadata = envelope.metadata()
      metadata["display_source"] = envelope.resultSummary == nil ? "raw_embedded_introspection" : "event_envelope"
      metadata["display_text_length"] = "\(displayText.count)"
      return BrainStateSnapshot(
        toolName: "introspect",
        text: displayText,
        metadata: metadata
      )
    #else
      throw unavailable(operation: "introspect")
    #endif
  }

  func drainEvents() async throws -> [BrainEvent] {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let output = coreSession.drainEventsJSON()
      let text = try Self.checkedCopiedString(output, operation: "drain_events")
      let envelope = try BrainDispatchEnvelope.decode(from: text)
      guard envelope.ok else {
        let message = envelope.error?.message ?? "drain_events failed"
        throw BrainCoreError.unavailable(message)
      }
      return envelope.events
    #else
      throw unavailable(operation: "drain_events")
    #endif
  }

  static func runGenerationProviderE2E(
    brain: BrainDescriptor,
    providerCredentials: [ProviderCredentialKey: String]? = nil
  ) throws -> String {
    #if os(iOS) || os(macOS)
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
    #else
      throw BrainCoreError.unavailable(
        "api_e2e needs the AffectiveCore Zig core linked for brain \(brain.id).")
    #endif
  }

  func unavailable(operation: String = "connect") -> BrainCoreError {
    .unavailable("\(operation) needs the AffectiveCore Zig core linked for brain \(brain.id).")
  }

  #if os(iOS) || os(macOS)
    func ensureConnected() async throws {
      if !coreSession.isConnected {
        try await connect()
      }
    }

    func dispatch(event: BrainEvent, operation: String) async throws -> BrainDispatchEnvelope {
      let requestID = UUID().uuidString
      let eventValue = try event.encodedJSONValue()
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
	      return envelope
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

    static func introspect(_ handle: AffectiveCoreHandle?) -> AffectiveCoreCopiedResult {
      withCopiedResult(operation: "introspect") { data, errorMessage in
        affective_core_embedded_introspect_json(handle, &data, &errorMessage)
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
  #endif
}

extension BrainCore: BrainCoreClient {}
