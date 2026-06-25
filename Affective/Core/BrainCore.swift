//
//  BrainCore.swift
//  Affective
//

import Foundation
import os

protocol BrainCoreClient {
  func connect() async throws
  func disconnect() async
  func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> BrainToolResponse
  func shortTouch() async throws -> BrainToolResponse
  func longTouch() async throws -> BrainToolResponse
  func pokeSequence(_ pulses: [PokePulse]) async throws -> BrainToolResponse
  func orientationObservation(
    _ observation: OrientationObservation,
    requestID: String?,
    presentation: BrainEventPresentation
  ) async throws -> BrainToolResponse
  func cameraObservation(
    path: String,
    mimeType: String,
    source: String,
    requestID: String?,
    presentation: BrainEventPresentation
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
  nonisolated static let migrationFallbackWarning =
    "Host-visible behavior should come from embedded events; this legacy field is migration-only."
  let brain: BrainDescriptor

  #if os(iOS) || os(macOS)
    var handle: AffectiveCoreHandle?
    private var hostServices: EmbeddedHostServices?
  #endif

  init(brain: BrainDescriptor) {
    self.brain = brain
  }

  func connect() async throws {
    try brain.validateForCoreConnection()

    #if os(iOS) || os(macOS)
      if handle != nil {
        return
      }

      let storage = CoreConfigStorage(brain: brain)
      let hostServices = EmbeddedHostServices()
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
      self.handle = handle
      self.hostServices = hostServices
    #else
      throw unavailable()
    #endif
  }

  func disconnect() async {
    #if os(iOS) || os(macOS)
      Self.withFFI {
        affective_core_embedded_destroy(handle)
      }
      handle = nil
      hostServices = nil
    #endif
  }

  func callTool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let envelope = try dispatch(event: [
        "type": .string("tool_call"),
        "name": .string(name),
        "arguments": .object(arguments),
      ], operation: name)
      return BrainToolResponse(toolName: name, envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: name)
    #endif
  }

  func shortTouch() async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let envelope = try dispatch(event: [
        "type": .string("short_touch")
      ], operation: "short_touch")
      return BrainToolResponse(toolName: "short_touch", envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: "short_touch")
    #endif
  }

  func longTouch() async throws -> BrainToolResponse {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let envelope = try dispatch(event: [
        "type": .string("long_touch")
      ], operation: "long_touch")
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
      let envelope = try dispatch(event: [
        "type": .string("poke_sequence"),
        "pulses": .array(pulseValues),
      ], operation: "poke_sequence")
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
      var event: [String: JSONValue] = [
        "type": .string("sense_observation"),
        "sense": .string("orientation"),
        "observation": .object(observation.eventArguments),
        "presentation": .string(presentation.rawValue),
      ]
      if let requestID, !requestID.isEmpty {
        event["request_id"] = .string(requestID)
      }
      let envelope = try dispatch(event: event, operation: "sense_observation")
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
      ]
      if let requestID, !requestID.isEmpty {
        observation["request_id"] = .string(requestID)
      }
      var event: [String: JSONValue] = [
        "type": .string("sense_observation"),
        "sense": .string("camera"),
        "observation": .object(observation),
        "presentation": .string(presentation.rawValue),
      ]
      if let requestID, !requestID.isEmpty {
        event["request_id"] = .string(requestID)
      }
      let envelope = try dispatch(event: event, operation: "sense_observation")
      return BrainToolResponse(toolName: "sense_observation", envelope: envelope, rawText: envelope.rawText)
    #else
      throw unavailable(operation: "sense_observation")
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
      var event: [String: JSONValue] = [
        "type": .string("host_capability_status"),
        "capability": .string(capability),
        "status": .string(status),
        "pending_elapsed_ms": .number(Double(pendingElapsedMS)),
        "reason": .string(reason),
      ]
      if let requestID, !requestID.isEmpty {
        event["request_id"] = .string(requestID)
      }
      if let pendingSince {
        event["pending_since_unix_ms"] = .number((pendingSince.timeIntervalSince1970 * 1000).rounded())
      }
      let envelope = try dispatch(event: event, operation: "host_capability_status")
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
      var event: [String: JSONValue] = [
        "type": .string("interrupt"),
        "text": .string(userText),
        "reason": .string(reason),
        "canceled_queued_action_count": .number(Double(canceledQueuedActionCount)),
      ]
      if let interruptedAction, !interruptedAction.isEmpty {
        event["interrupted_action"] = .string(interruptedAction)
      }
      let envelope = try dispatch(event: event, operation: "interrupt")
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
      var event: [String: JSONValue] = [
        "type": .string(source.eventType),
        "text": .string(Self.textByAppendingAttachmentMarkers(text, attachments: attachments)),
        "source": .string(source.rawValue),
      ]
      if !attachments.isEmpty {
        event["attachments"] = .array(attachments.map { .object($0) })
      }
      if let stimulusContext {
        event["stimulus_context"] = .object(stimulusContext.eventArguments)
      }
      let envelope = try dispatch(event: event, operation: source.eventType)
      let json = envelope.conversationTurnJSON ?? envelope.rawText
      let turn = ConversationTurnPayload.decode(from: json)
      if turn.isTestEchoResponse {
        throw BrainCoreError.unavailable(
          "The embedded core selected its test echo chat service instead of a configured model provider."
        )
      }
      let eventText = envelope.displayTextFromEvents
      let responseText = eventText.isEmpty ? (turn.spokenText.isEmpty ? turn.brainSummary : turn.spokenText) : eventText
      var metadata = turn.metadata()
      metadata.merge(envelope.metadata()) { current, _ in current }
      metadata["display_source"] = eventText.isEmpty ? turn.displaySource(rawJSON: json) : "event_envelope"
      if eventText.isEmpty {
        metadata["migration_fallback"] = "legacy_conversation_turn"
        metadata["fallback_warning"] = Self.migrationFallbackWarning
      }
      metadata["display_text_length"] = "\(responseText.count)"
      metadata["raw_json_length"] = "\(json.count)"
      return BrainTextResponse(
        toolName: "conversation_turn",
        text: responseText.isEmpty ? json : responseText,
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
      let result = Self.introspect(handle)
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

  func drainEvents() async throws -> [BrainHostEvent] {
    #if os(iOS) || os(macOS)
      try await ensureConnected()
      let output = Self.drainEventsJSON(handle)
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
      let storage = CoreConfigStorage(brain: brain, providerCredentials: providerCredentials)
      let hostServices = EmbeddedHostServices()
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
      if handle == nil {
        try await connect()
      }
    }

    func dispatch(event: [String: JSONValue], operation: String) throws -> BrainDispatchEnvelope {
      let requestID = UUID().uuidString
      let request: JSONValue = .object([
        "api_version": .number(Double(EmbeddedProtocolContract.apiVersion)),
        "request_id": .string(requestID),
        "event": .object(event),
      ])
      let requestData = try request.encodedData()
      Self.brainCoreLogger.info("Dispatch start operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) requestBytes=\(requestData.count, privacy: .public)")
      let output = requestData.withUnsafeBytes { requestBuffer in
        let requestPointer = requestBuffer.bindMemory(to: UInt8.self).baseAddress
        return Self.dispatchJSON(handle, requestJSON: requestPointer, requestJSONLength: requestData.count)
      }
      Self.brainCoreLogger.info("Dispatch result operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) status=\(output.status, privacy: .public) dataBytes=\(output.dataBytes, privacy: .public) errorBytes=\(output.errorBytes, privacy: .public)")
	      let text = try Self.checkedCopiedString(output, operation: operation)
	      let envelope = try BrainDispatchEnvelope.decode(from: text)
	      if let captureRequest = Self.frontendCaptureRequestEnvelope(from: envelope) {
	        return captureRequest
	      }
	      guard envelope.ok else {
	        let message = envelope.error?.message ?? "\(operation) failed"
	        Self.brainCoreLogger.error("Dispatch envelope error operation=\(operation, privacy: .public) requestID=\(requestID, privacy: .public) code=\(envelope.error?.code ?? "unknown", privacy: .public) message=\(message, privacy: .public)")
	        throw BrainCoreError.unavailable(message)
	      }
	      return envelope
	    }

	    static func frontendCaptureRequestEnvelope(from envelope: BrainDispatchEnvelope) -> BrainDispatchEnvelope? {
	      guard
	        envelope.ok == false,
	        envelope.error?.code == "runtime_error",
	        envelope.error?.message.contains("FrontendCaptureRequested") == true
	      else {
	        return nil
	      }
	      return BrainDispatchEnvelope(
	        apiVersion: envelope.apiVersion,
	        requestID: envelope.requestID,
	        ok: true,
	        events: [
	          BrainHostEvent(
	            type: "sense_requested",
	            requestID: envelope.requestID,
	            role: nil,
	            text: "frontend camera sense requested",
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
		            responsePresentation: BrainEventPresentation.internalOnly.rawValue,
	            awaitResponse: true,
	            timeoutMS: 10_000
	          )
	        ],
	        result: nil,
	        error: nil,
	        budget: envelope.budget,
	        rawText: envelope.rawText
	      )
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
        affective_core_embedded_dispatch_json_v2(
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
        affective_core_embedded_drain_events_json_v2(handle, &data, &errorMessage)
      }
    }

    static func introspect(_ handle: AffectiveCoreHandle?) -> AffectiveCoreCopiedResult {
      withCopiedResult(operation: "introspect") { data, errorMessage in
        affective_core_embedded_introspect_json_v2(handle, &data, &errorMessage)
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
