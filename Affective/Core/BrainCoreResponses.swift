//
//  Split from BrainCore.swift
//  Affective
//

import Foundation

nonisolated struct BrainTextResponse: Equatable {
  let toolName: String
  let text: String
  let metadata: [String: String]
  let events: [BrainEvent]
}

nonisolated struct BrainModeResponse: Equatable {
  let toolName: String
  let mode: String
  let metadata: [String: String]

  init(toolName: String, mode: String, metadata: [String: String]) {
    self.toolName = toolName
    self.mode = mode
    self.metadata = metadata
  }

  init(toolName: String, envelope: BrainDispatchEnvelope) throws {
    self.toolName = toolName
    let payload = try envelope.structuredResultValueRequired()
    guard let mode = payload.objectValue?["brain_mode"]?.stringValue, !mode.isEmpty else {
      throw BrainCoreError.malformedResponse
    }
    self.mode = mode
    var mergedMetadata = envelope.metadata()
    mergedMetadata["brain_mode"] = mode
    self.metadata = mergedMetadata
  }
}

nonisolated struct BrainReadModelsSnapshotResponse: Equatable {
  let toolName: String
  let readModels: JSONValue
  let metadata: [String: String]

  init(toolName: String, readModels: JSONValue, metadata: [String: String]) {
    self.toolName = toolName
    self.readModels = readModels
    self.metadata = metadata
  }

  init(toolName: String, envelope: BrainDispatchEnvelope) throws {
    self.toolName = toolName
    let payload = try envelope.structuredResultValueRequired()
    guard let readModels = payload.objectValue?["read_models"] else {
      throw BrainCoreError.malformedResponse
    }
    self.readModels = readModels
    var mergedMetadata = envelope.metadata()
    if let brainMode = readModels.objectValue?["brain_mode"]?.stringValue {
      mergedMetadata["brain_mode"] = brainMode
    }
    self.metadata = mergedMetadata
  }
}

nonisolated struct BrainArchiveResponse: Equatable {
  let toolName: String
  let manifest: JSONValue
  let metadata: [String: String]

  init(toolName: String, manifest: JSONValue, metadata: [String: String]) {
    self.toolName = toolName
    self.manifest = manifest
    self.metadata = metadata
  }

  init(toolName: String, payload: JSONValue) throws {
    self.toolName = toolName
    guard let manifest = payload.objectValue?["manifest"] else {
      throw BrainCoreError.unavailable("Archive response did not include a manifest.")
    }
    self.manifest = manifest
    var metadata: [String: String] = [:]
    if let brainID = manifest.objectValue?["brain_id"]?.stringValue {
      metadata["brain_id"] = brainID
    }
    if case .number(let componentCount) = manifest.objectValue?["component_count"] {
      metadata["component_count"] = "\(Int(componentCount))"
    }
    self.metadata = metadata
  }

  init(toolName: String, envelope: BrainDispatchEnvelope) throws {
    self.toolName = toolName
    guard let manifest = try envelope.archiveManifestPayload() else {
      let preview = envelope.rawText.prefix(512)
      throw BrainCoreError.unavailable("Archive response did not include a manifest: \(preview)")
    }
    self.manifest = manifest
    var mergedMetadata = envelope.metadata()
    if let brainID = manifest.objectValue?["brain_id"]?.stringValue {
      mergedMetadata["brain_id"] = brainID
    }
    if case .number(let componentCount) = manifest.objectValue?["component_count"] {
      mergedMetadata["component_count"] = "\(Int(componentCount))"
    }
    metadata = mergedMetadata
  }
}

nonisolated struct BrainMailboxListResponse: Equatable {
  let toolName: String
  let items: [BrainMailboxItem]
  let metadata: [String: String]

  init(toolName: String, items: [BrainMailboxItem], metadata: [String: String]) {
    self.toolName = toolName
    self.items = items
    self.metadata = metadata
  }

  init(toolName: String, envelope: BrainDispatchEnvelope) throws {
    self.toolName = toolName
    let payload = try envelope.structuredResultValueRequired()
    items = try BrainMailboxItem.items(from: payload)
    var mergedMetadata = envelope.metadata()
    mergedMetadata["mailbox_item_count"] = "\(items.count)"
    metadata = mergedMetadata
  }
}

nonisolated struct BrainMailboxResponse: Equatable {
  let toolName: String
  let item: BrainMailboxItem
  let metadata: [String: String]

  init(toolName: String, item: BrainMailboxItem, metadata: [String: String]) {
    self.toolName = toolName
    self.item = item
    self.metadata = metadata
  }

  init(toolName: String, envelope: BrainDispatchEnvelope) throws {
    self.toolName = toolName
    let payload = try envelope.structuredResultValueRequired()
    item = try BrainMailboxItem.item(from: payload)
    var mergedMetadata = envelope.metadata()
    mergedMetadata["mailbox_id"] = item.mailboxID
    metadata = mergedMetadata
  }
}

nonisolated struct BrainMailboxItem: Codable, Equatable, Sendable {
  let mailboxID: String
  let kind: String
  let title: String
  let text: String
  let imageArtifactID: String?
  let imageSpecJSON: String
  let wakingThought: String
  let visibleLesson: String
  let debugDetails: String
  let sourceEventIDs: [String]
  let sourceDreamID: String?
  let createdAtMS: Int64

  private enum CodingKeys: String, CodingKey {
    case mailboxID = "mailbox_id"
    case kind
    case title
    case text
    case imageArtifactID = "image_artifact_id"
    case imageSpecJSON = "image_spec_json"
    case wakingThought = "waking_thought"
    case visibleLesson = "visible_lesson"
    case debugDetails = "debug_details"
    case sourceEventIDs = "source_event_ids"
    case sourceDreamID = "source_dream_id"
    case createdAtMS = "created_at_ms"
  }

  static func items(from payload: JSONValue) throws -> [BrainMailboxItem] {
    guard let values = payload.objectValue?["items"]?.arrayValue else {
      throw BrainCoreError.malformedResponse
    }
    return try values.map(decode)
  }

  static func item(from payload: JSONValue) throws -> BrainMailboxItem {
    guard let value = payload.objectValue?["mailbox_item"] else {
      throw BrainCoreError.malformedResponse
    }
    return try decode(value)
  }

  private static func decode(_ value: JSONValue) throws -> BrainMailboxItem {
    try JSONDecoder().decode(BrainMailboxItem.self, from: value.encodedData())
  }
}

nonisolated struct BrainToolResponse: Equatable {
  let toolName: String
  let text: String
  let rawText: String
  let metadata: [String: String]
  let shouldSpeak: Bool
  let events: [BrainEvent]

  init(
    toolName: String,
    text: String,
    metadata: [String: String],
    shouldSpeak: Bool = false,
    events: [BrainEvent],
    rawText: String = ""
  ) {
    self.toolName = toolName
    self.text = text
    self.metadata = metadata
    self.shouldSpeak = shouldSpeak
    self.events = events
    self.rawText = rawText
  }

  init(toolName: String, envelope: BrainDispatchEnvelope, rawText: String) {
    self.toolName = toolName
    self.rawText = rawText
    events = envelope.events

    let eventText = envelope.displayText
    text = eventText

    var mergedMetadata = envelope.metadata()
    mergedMetadata["display_source"] = eventText.isEmpty
      ? (envelope.awaitingHostSense ? "awaiting_host_sense" : "empty")
      : (envelope.displayTextFromEvents.isEmpty ? "result_value" : "event_envelope")
    mergedMetadata["display_text_length"] = "\(text.count)"
    metadata = mergedMetadata
    shouldSpeak = !envelope.speechTexts.isEmpty
  }
}

nonisolated enum BrainEventPresentation: String, Codable, Equatable, Sendable {
  case chat
  case internalOnly = "internal"
  case status
  case log

  var mirrorsToChat: Bool {
    self == .chat
  }
}

nonisolated enum BrainEventEndpoint: String, Codable, Equatable, Sendable {
  case brain
  case host
  case user
  case system
}

nonisolated enum BrainEventVisibility: String, Codable, Equatable, Sendable {
  case `private`
  case diagnostic
  case `public`
}

nonisolated enum BrainEventModality: String, Codable, Equatable, Sendable {
  case text
  case image
  case audio
  case video
  case scalar
  case structured
  case media
  case face
  case facialExpression = "facial_expression"
}

nonisolated enum BrainParticipantRole: String, Codable, Equatable, Sendable {
  case selfRole = "self"
  case other
  case user
  case brain
  case host
  case system
  case unknown

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    self = Self(rawValue: value) ?? .unknown
  }
}

nonisolated enum BrainSenseDirection: String, Codable, Equatable, Sendable {
  case pull
  case push
  case both
}

nonisolated enum BrainActionStatus: String, Codable, Equatable, Sendable {
  case succeeded
  case denied
  case unavailable
  case failed
  case cancelled
  case timedOut = "timed_out"
}

nonisolated enum BrainMemoryLayer: String, Codable, Equatable, Sendable, CaseIterable {
  case working
  case episodic
  case semantic
  case procedural
  case affective
  case relational
  case autobiographical
  case prospective
}

nonisolated enum BrainMemoryOperation: String, Codable, Equatable, Sendable {
  case remember
  case recall
  case forget
  case consolidate
  case summarize
  case pin
  case inspect
  case scheduleReminder = "schedule_reminder"
  case inspectReminders = "inspect_reminders"
}

nonisolated enum BrainLoopPhase: String, Codable, Equatable, Sendable {
  case idle
  case receivingExperience
  case appraising
  case recalling
  case thinking
  case planning
  case awaitingHostAction
  case integratingResult
  case remembering
  case expressing
  case sleeping
  case error
}

nonisolated struct BrainMediaRef: Codable, Equatable, Sendable {
  let kind: BrainEventModality
  let path: String?
  let url: String?
  let mimeType: String?
  let caption: String?

  private enum CodingKeys: String, CodingKey {
    case kind
    case path
    case url
    case mimeType = "mime_type"
    case caption
  }
}

nonisolated struct BrainExperiencePayload: Codable, Equatable, Sendable {
  let kind: String
  let modality: BrainEventModality
  let role: BrainParticipantRole?
  let text: String?
  let media: [BrainMediaRef]
  let context: JSONValue?
}

nonisolated struct BrainSenseRequestPayload: Codable, Equatable, Sendable {
  let senseID: String
  let direction: BrainSenseDirection
  let timeoutMS: Int?
  let responsePresentation: BrainEventPresentation

  private enum CodingKeys: String, CodingKey {
    case senseID = "sense_id"
    case direction
    case timeoutMS = "timeout_ms"
    case responsePresentation = "response_presentation"
  }
}

nonisolated struct BrainSenseObservationPayload: Codable, Equatable, Sendable {
  let senseID: String
  let modality: BrainEventModality
  let summary: String
  let media: [BrainMediaRef]
  let value: JSONValue?
  let confidence: Double?
  let observedAt: String

  private enum CodingKeys: String, CodingKey {
    case senseID = "sense_id"
    case modality
    case summary
    case media
    case value
    case confidence
    case observedAt = "observed_at"
  }
}

nonisolated struct BrainCapabilityDescriptor: Codable, Equatable, Sendable {
  let id: String
  let status: String
  let reason: String?
}

nonisolated struct BrainCapabilityManifestPayload: Codable, Equatable, Sendable {
  let capabilities: [BrainCapabilityDescriptor]
  let senses: [BrainCapabilityDescriptor]
}

nonisolated struct BrainCapabilityStatusPayload: Codable, Equatable, Sendable {
  let capabilityID: String
  let status: String?
  let reason: String?
  let permission: String?
  let availability: String?
  let quality: Double?
  let reliability: Double?
  let cost: Double?
  let latencyMS: Int?
  let risk: Double?
  let unavailableReason: String?

  private enum CodingKeys: String, CodingKey {
    case capabilityID = "capability_id"
    case status
    case reason
    case permission
    case availability
    case quality
    case reliability
    case cost
    case latencyMS = "latency_ms"
    case risk
    case unavailableReason = "unavailable_reason"
  }

  init(
    capabilityID: String,
    status: String? = nil,
    reason: String? = nil,
    permission: String? = nil,
    availability: String? = nil,
    quality: Double? = nil,
    reliability: Double? = nil,
    cost: Double? = nil,
    latencyMS: Int? = nil,
    risk: Double? = nil,
    unavailableReason: String? = nil
  ) {
    self.capabilityID = capabilityID
    self.status = status
    self.reason = reason
    self.permission = permission
    self.availability = availability
    self.quality = quality
    self.reliability = reliability
    self.cost = cost
    self.latencyMS = latencyMS
    self.risk = risk
    self.unavailableReason = unavailableReason
  }
}

nonisolated struct BrainThoughtPayload: Codable, Equatable, Sendable {
  let text: String
  let salience: Double?
  let tags: [String]
}

nonisolated struct BrainAppraisalPayload: Codable, Equatable, Sendable {
  let valence: Double?
  let arousal: Double?
  let salience: Double?
  let confidence: Double?
  let novelty: Double?
  let tags: [String]
  let summary: String?
}

nonisolated struct BrainNeedStatePayload: Codable, Equatable, Sendable {
  let needs: [String: Double]
  let summary: String?
}

nonisolated struct BrainAttentionStatePayload: Codable, Equatable, Sendable {
  let focusEventID: String?
  let competingEventIDs: [String]
  let summary: String
  let suppressionReason: String?

  private enum CodingKeys: String, CodingKey {
    case focusEventID = "focus_event_id"
    case competingEventIDs = "competing_event_ids"
    case summary
    case suppressionReason = "suppression_reason"
  }
}

nonisolated struct BrainIntentionPayload: Codable, Equatable, Sendable {
  let goal: String
  let priority: Double?
  let expectedAction: String?
  let stoppingCondition: String?

  private enum CodingKeys: String, CodingKey {
    case goal
    case priority
    case expectedAction = "expected_action"
    case stoppingCondition = "stopping_condition"
  }
}

nonisolated struct BrainActionRequestPayload: Codable, Equatable, Sendable {
  let actionID: String
  let action: String
  let arguments: JSONValue
  let requires: [String]
  let awaitResponse: Bool

  private enum CodingKeys: String, CodingKey {
    case actionID = "action_id"
    case action
    case arguments
    case requires
    case awaitResponse = "await_response"
  }
}

nonisolated struct BrainActionResultPayload: Codable, Equatable, Sendable {
  let actionID: String
  let status: BrainActionStatus
  let summary: String
  let result: JSONValue?
  let error: BrainEventErrorPayload?

  private enum CodingKeys: String, CodingKey {
    case actionID = "action_id"
    case status
    case summary
    case result
    case error
  }
}

nonisolated struct BrainExpressionPayload: Codable, Equatable, Sendable {
  let modality: BrainEventModality
  let role: BrainParticipantRole
  let title: String?
  let text: String?
  let media: [BrainMediaRef]
  let expressionID: String?
  let eyes: String?
  let mouth: String?
  let durationMS: Int?

  private enum CodingKeys: String, CodingKey {
    case modality
    case role
    case title
    case text
    case media
    case expressionID = "expression_id"
    case eyes
    case mouth
    case durationMS = "duration_ms"
  }
}

nonisolated struct BrainMemoryRecord: Codable, Equatable, Sendable {
  let id: String
  let layer: BrainMemoryLayer
  let summary: String
  let relevance: Double?
  let confidence: Double?
}

nonisolated struct BrainMemoryResultPayload: Codable, Equatable, Sendable {
  let operation: BrainMemoryOperation
  let records: [BrainMemoryRecord]
  let summary: String?
}

nonisolated struct BrainMemoryMutationPayload: Codable, Equatable, Sendable {
  let operation: BrainMemoryOperation
  let layer: BrainMemoryLayer
  let recordIDs: [String]
  let summary: String

  private enum CodingKeys: String, CodingKey {
    case operation
    case layer
    case recordIDs = "record_ids"
    case summary
  }
}

nonisolated struct BrainControlPayload: Codable, Equatable, Sendable {
  let phase: BrainLoopPhase?
  let sendEnabled: Bool?
  let status: String?

  private enum CodingKeys: String, CodingKey {
    case phase
    case sendEnabled = "send_enabled"
    case status
  }
}

nonisolated struct BrainMiseEnScenePayload: Codable, Equatable, Sendable {
  let name: String
  let themeColor: String?

  private enum CodingKeys: String, CodingKey {
    case name
    case themeColor = "theme_color"
  }
}

nonisolated struct BrainEventErrorPayload: Codable, Equatable, Sendable {
  let code: String
  let message: String
  let recoverable: Bool?
}

nonisolated enum BrainEventPayload: Codable, Equatable, Sendable {
  case experience(BrainExperiencePayload)
  case senseRequest(BrainSenseRequestPayload)
  case senseObservation(BrainSenseObservationPayload)
  case capabilityManifest(BrainCapabilityManifestPayload)
  case capabilityStatus(BrainCapabilityStatusPayload)
  case thought(BrainThoughtPayload)
  case appraisal(BrainAppraisalPayload)
  case needState(BrainNeedStatePayload)
  case attentionState(BrainAttentionStatePayload)
  case intention(BrainIntentionPayload)
  case capabilityRequest(BrainActionRequestPayload)
  case actionResult(BrainActionResultPayload)
  case expression(BrainExpressionPayload)
  case memoryResult(BrainMemoryResultPayload)
  case memoryMutation(BrainMemoryMutationPayload)
  case control(BrainControlPayload)
  case miseEnScene(BrainMiseEnScenePayload)
  case error(BrainEventErrorPayload)

  enum CodingKeys: String, CodingKey {
    case experience
    case senseRequest = "sense_request"
    case senseObservation = "sense_observation"
    case capabilityManifest = "capability_manifest"
    case capabilityStatus = "capability_status"
    case thought
    case appraisal
    case needState = "need_state"
    case attentionState = "attention_state"
    case intention
    case capabilityRequest = "capability_request"
    case actionResult = "action_result"
    case expression
    case memoryResult = "memory_result"
    case memoryMutation = "memory_mutation"
    case control
    case miseEnScene = "mise_en_scene"
    case error
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let value = try container.decodeIfPresent(BrainExperiencePayload.self, forKey: .experience) {
      self = .experience(value)
    } else if let value = try container.decodeIfPresent(BrainSenseRequestPayload.self, forKey: .senseRequest) {
      self = .senseRequest(value)
    } else if let value = try container.decodeIfPresent(BrainSenseObservationPayload.self, forKey: .senseObservation) {
      self = .senseObservation(value)
    } else if let value = try container.decodeIfPresent(BrainCapabilityManifestPayload.self, forKey: .capabilityManifest) {
      self = .capabilityManifest(value)
    } else if let value = try container.decodeIfPresent(BrainCapabilityStatusPayload.self, forKey: .capabilityStatus) {
      self = .capabilityStatus(value)
    } else if let value = try container.decodeIfPresent(BrainThoughtPayload.self, forKey: .thought) {
      self = .thought(value)
    } else if let value = try container.decodeIfPresent(BrainAppraisalPayload.self, forKey: .appraisal) {
      self = .appraisal(value)
    } else if let value = try container.decodeIfPresent(BrainNeedStatePayload.self, forKey: .needState) {
      self = .needState(value)
    } else if let value = try container.decodeIfPresent(BrainAttentionStatePayload.self, forKey: .attentionState) {
      self = .attentionState(value)
    } else if let value = try container.decodeIfPresent(BrainIntentionPayload.self, forKey: .intention) {
      self = .intention(value)
    } else if let value = try container.decodeIfPresent(BrainActionRequestPayload.self, forKey: .capabilityRequest) {
      self = .capabilityRequest(value)
    } else if let value = try container.decodeIfPresent(BrainActionResultPayload.self, forKey: .actionResult) {
      self = .actionResult(value)
    } else if let value = try container.decodeIfPresent(BrainExpressionPayload.self, forKey: .expression) {
      self = .expression(value)
    } else if let value = try container.decodeIfPresent(BrainMemoryResultPayload.self, forKey: .memoryResult) {
      self = .memoryResult(value)
    } else if let value = try container.decodeIfPresent(BrainMemoryMutationPayload.self, forKey: .memoryMutation) {
      self = .memoryMutation(value)
    } else if let value = try container.decodeIfPresent(BrainControlPayload.self, forKey: .control) {
      self = .control(value)
    } else if let value = try container.decodeIfPresent(BrainMiseEnScenePayload.self, forKey: .miseEnScene) {
      self = .miseEnScene(value)
    } else if let value = try container.decodeIfPresent(BrainEventErrorPayload.self, forKey: .error) {
      self = .error(value)
    } else {
      throw BrainCoreError.malformedResponse
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .experience(let value): try container.encode(value, forKey: .experience)
    case .senseRequest(let value): try container.encode(value, forKey: .senseRequest)
    case .senseObservation(let value): try container.encode(value, forKey: .senseObservation)
    case .capabilityManifest(let value): try container.encode(value, forKey: .capabilityManifest)
    case .capabilityStatus(let value): try container.encode(value, forKey: .capabilityStatus)
    case .thought(let value): try container.encode(value, forKey: .thought)
    case .appraisal(let value): try container.encode(value, forKey: .appraisal)
    case .needState(let value): try container.encode(value, forKey: .needState)
    case .attentionState(let value): try container.encode(value, forKey: .attentionState)
    case .intention(let value): try container.encode(value, forKey: .intention)
    case .capabilityRequest(let value): try container.encode(value, forKey: .capabilityRequest)
    case .actionResult(let value): try container.encode(value, forKey: .actionResult)
    case .expression(let value): try container.encode(value, forKey: .expression)
    case .memoryResult(let value): try container.encode(value, forKey: .memoryResult)
    case .memoryMutation(let value): try container.encode(value, forKey: .memoryMutation)
    case .control(let value): try container.encode(value, forKey: .control)
    case .miseEnScene(let value): try container.encode(value, forKey: .miseEnScene)
    case .error(let value): try container.encode(value, forKey: .error)
    }
  }

  var eventType: String {
    switch self {
    case .experience: "experience"
    case .senseRequest: "sense_request"
    case .senseObservation: "sense_observation"
    case .capabilityManifest: "capability_manifest"
    case .capabilityStatus: "capability_status"
    case .thought: "thought"
    case .appraisal: "appraisal"
    case .needState: "need_state"
    case .attentionState: "attention_state"
    case .intention: "intention"
    case .capabilityRequest: "capability_request"
    case .actionResult: "action_result"
    case .expression: "expression"
    case .memoryResult: "memory_result"
    case .memoryMutation: "memory_mutation"
    case .control: "control"
    case .miseEnScene: "mise_en_scene"
    case .error: "error"
    }
  }
}

nonisolated struct BrainEvent: Codable, Equatable, Sendable {
  let id: String
  let traceID: String
  let parentID: String?
  let turnID: String?
  let loopID: String?
  let occurredAt: String
  let source: BrainEventEndpoint
  let target: BrainEventEndpoint
  let visibility: BrainEventVisibility
  let presentation: BrainEventPresentation
  let payload: BrainEventPayload

  private enum CodingKeys: String, CodingKey {
    case id
    case traceID = "trace_id"
    case parentID = "parent_id"
    case turnID = "turn_id"
    case loopID = "loop_id"
    case occurredAt = "occurred_at"
    case source
    case target
    case visibility
    case presentation
    case payload
  }

  var type: String { payload.eventType }

  init(
    id: String,
    traceID: String,
    parentID: String?,
    turnID: String?,
    loopID: String?,
    occurredAt: String,
    source: BrainEventEndpoint,
    target: BrainEventEndpoint,
    visibility: BrainEventVisibility,
    presentation: BrainEventPresentation,
    payload: BrainEventPayload
  ) {
    self.id = id
    self.traceID = traceID
    self.parentID = parentID
    self.turnID = turnID
    self.loopID = loopID
    self.occurredAt = occurredAt
    self.source = source
    self.target = target
    self.visibility = visibility
    self.presentation = presentation
    self.payload = payload
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    id = try container.decode(String.self, forKey: .id)
    traceID = try container.decodeIfPresent(String.self, forKey: .traceID) ?? id
    parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
    turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    loopID = try container.decodeIfPresent(String.self, forKey: .loopID)
    occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt)
      ?? BrainEvent.iso8601Now()
    source = try container.decodeIfPresent(BrainEventEndpoint.self, forKey: .source) ?? .brain
    target = try container.decodeIfPresent(BrainEventEndpoint.self, forKey: .target) ?? .host
    visibility = try container.decodeIfPresent(BrainEventVisibility.self, forKey: .visibility) ?? .public
    presentation = try container.decodeIfPresent(BrainEventPresentation.self, forKey: .presentation) ?? .chat
    payload = try container.decode(BrainEventPayload.self, forKey: .payload)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(traceID, forKey: .traceID)
    try container.encodeIfPresent(parentID, forKey: .parentID)
    try container.encodeIfPresent(turnID, forKey: .turnID)
    try container.encodeIfPresent(loopID, forKey: .loopID)
    try container.encode(occurredAt, forKey: .occurredAt)
    try container.encode(source, forKey: .source)
    try container.encode(target, forKey: .target)
    try container.encode(visibility, forKey: .visibility)
    try container.encode(presentation, forKey: .presentation)
    try container.encode(payload, forKey: .payload)
  }

  static func hostEvent(
    payload: BrainEventPayload,
    target: BrainEventEndpoint = .brain,
    visibility: BrainEventVisibility = .diagnostic,
    presentation: BrainEventPresentation = .internalOnly,
    traceID: String = UUID().uuidString,
    parentID: String? = nil,
    turnID: String? = nil,
    loopID: String? = nil,
    occurredAt: String = BrainEvent.iso8601Now()
  ) -> BrainEvent {
    BrainEvent(
      id: UUID().uuidString,
      traceID: traceID,
      parentID: parentID,
      turnID: turnID,
      loopID: loopID,
      occurredAt: occurredAt,
      source: .host,
      target: target,
      visibility: visibility,
      presentation: presentation,
      payload: payload
    )
  }

  nonisolated static func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  func encodedJSONValue() throws -> JSONValue {
    let data = try JSONEncoder().encode(self)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

nonisolated enum PullSenseDirection: String, Codable, Equatable {
  case pull
  case push
  case both
}

nonisolated enum PullSenseTerminalStatus: String, Codable, Equatable {
  case fulfilled
  case unavailable
  case permissionDenied = "permission_denied"
  case permissionRequired = "permission_required"
  case permissionPending = "permission_pending"
  case busy
  case failed
  case cancelled
  case timedOut = "timed_out"
  case unsupported
}

nonisolated struct PullSenseDescriptor: Equatable {
  let senseID: String
  let direction: PullSenseDirection
  let availability: String
  let permissionState: String
  let statusReason: String

  var jsonValue: JSONValue {
    .object([
      "sense_id": .string(senseID),
      "sense": .string(senseID),
	      "sense_direction": .string(direction.rawValue),
	      "availability": .string(availability),
	      "permission": .string(permissionState),
	      "unavailable_reason": .string(statusReason),
	    ])
	  }
	}

nonisolated struct BrainDispatchEnvelope: Codable, Equatable {
  let requestID: String
  let ok: Bool
  let events: [BrainEvent]
  let result: JSONValue?
  let error: BrainDispatchError?
  let budget: BrainDispatchBudget?
  let rawText: String

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case ok
    case events
    case result
    case error
    case budget
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try container.decode(String.self, forKey: .requestID)
    ok = try container.decode(Bool.self, forKey: .ok)
    events = try container.decodeIfPresent([BrainEvent].self, forKey: .events) ?? []
    result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
    error = try container.decodeIfPresent(BrainDispatchError.self, forKey: .error)
    budget = try container.decodeIfPresent(BrainDispatchBudget.self, forKey: .budget)
    rawText = ""
  }

  init(
    requestID: String,
    ok: Bool,
    events: [BrainEvent],
    result: JSONValue?,
    error: BrainDispatchError?,
    budget: BrainDispatchBudget? = nil,
    rawText: String = ""
  ) {
    self.requestID = requestID
    self.ok = ok
    self.events = events
    self.result = result
    self.error = error
    self.budget = budget
    self.rawText = rawText
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(ok, forKey: .ok)
    try container.encode(events, forKey: .events)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encodeIfPresent(error, forKey: .error)
    try container.encodeIfPresent(budget, forKey: .budget)
  }

  static func decode(from text: String) throws -> BrainDispatchEnvelope {
    guard let data = text.data(using: .utf8) else {
      throw BrainCoreError.malformedResponse
    }
    var decoded = try JSONDecoder().decode(BrainDispatchEnvelope.self, from: data)
    decoded = BrainDispatchEnvelope(
      requestID: decoded.requestID,
      ok: decoded.ok,
      events: decoded.events,
      result: decoded.result,
      error: decoded.error,
      budget: decoded.budget,
      rawText: text
    )
    return decoded
  }

  var speechTexts: [String] {
    events.compactMap { event in
      if let value = event.capabilityRequestPayload,
        value.action == "speak",
        case .object(let arguments) = value.arguments
      {
        return arguments["text"]?.stringValue
      }
      return nil
    }.filter { !$0.isEmpty }
  }

  var userTextOutcomePayload: [String: JSONValue]? {
    structuredResultValue?.objectValue?["outcome"]?.objectValue
  }

  var awaitingHostSense: Bool {
    userTextOutcomePayload?["awaiting_host_sense"]?.boolValue ?? false
  }

  var spokenTextFromResult: String {
    userTextOutcomePayload?["spoken_text"]?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  var displayText: String {
    let fromEvents = displayTextFromEvents.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fromEvents.isEmpty {
      return fromEvents
    }
    return spokenTextFromResult
  }

  var displayTextFromEvents: String {
    if let expressionText = events
      .last(where: {
        $0.type == "expression" && $0.isSelfMessage && ($0.modality ?? "text") == "text"
      })?.text,
      !expressionText.isEmpty
    {
      return expressionText
    }
    if let speechText = speechTexts.last {
      return speechText
    }
    return ""
  }

  func structuredResultValueRequired() throws -> JSONValue {
    guard let value = structuredResultValue else {
      throw BrainCoreError.malformedResponse
    }
    return value
  }

  var structuredResultValue: JSONValue? {
    result?.objectValue?["value"]
  }

  func archiveManifestPayload() throws -> JSONValue? {
    structuredResultValue?.objectValue?["manifest"]
  }

  var eventType: String? {
    result?.objectValue?["event_type"]?.stringValue
  }

  func metadata() -> [String: String] {
    var values = [
      "request_id": requestID,
      "event_count": "\(events.count)",
      "event_types": uniqueEventTypes.joined(separator: ","),
      "speech_event_count": "\(speechTexts.count)",
    ]
    if let budget {
      values["budget_max_bytes"] = "\(budget.maxBytes)"
      values["budget_used_bytes"] = "\(budget.usedBytes)"
      values["budget_compacted"] = "\(budget.compacted)"
      values["budget_dropped_event_count"] = "\(budget.droppedEventCount)"
      values["budget_raw_refs"] = budget.rawRefs.joined(separator: ",")
    }
    if awaitingHostSense {
      values["awaiting_host_sense"] = "true"
    }
    if let spoken = userTextOutcomePayload?["spoken_text"]?.stringValue {
      values["spoken_text_present"] = spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }
    if let userSummary = userTextOutcomePayload?["user_summary"]?.stringValue {
      values["user_summary_present"] = userSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }
    if let brainSummary = userTextOutcomePayload?["brain_summary"]?.stringValue {
      values["brain_summary_present"] = brainSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
    }
    if let ignoredBecauseValue = result?.objectValue?["ignored_because"]?.stringValue {
      let ignoredBecause = ignoredBecauseValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !ignoredBecause.isEmpty {
        values["ignored_because"] = ignoredBecause
      }
    }
    return values
  }

  private var uniqueEventTypes: [String] {
    var seen = Set<String>()
    return events.map(\.type).filter { seen.insert($0).inserted }
  }
}

extension BrainEvent {
  nonisolated var capabilityRequestPayload: BrainActionRequestPayload? {
    switch payload {
    case .capabilityRequest(let value):
      value
    default:
      nil
    }
  }

  nonisolated var isSelfMessage: Bool {
    role == "self" || role == "brain" || role == "bot" || role == "assistant" || role == "agent"
  }

  var requestID: String? {
    switch payload {
    case .senseRequest:
      id
    case .actionResult(let value):
      value.actionID
    default:
      capabilityRequestPayload?.actionID
    }
  }

  var expressionID: String? {
    if case .expression(let value) = payload { value.expressionID } else { nil }
  }

  nonisolated var modality: String? {
    switch payload {
    case .experience(let value): value.modality.rawValue
    case .senseObservation(let value): value.modality.rawValue
    case .expression(let value): value.modality.rawValue
    default: nil
    }
  }

  var capability: String? {
    switch payload {
    case .capabilityStatus(let value): value.capabilityID
    default: capabilityRequestPayload?.action
    }
  }

  var status: String? {
    switch payload {
    case .capabilityStatus(let value): value.availability
    case .actionResult(let value): value.status.rawValue
    case .control(let value): value.status
    default: nil
    }
  }

  var reason: String? {
    switch payload {
    case .capabilityStatus(let value): value.unavailableReason ?? value.reason
    case .error(let value): value.message
    default: nil
    }
  }

  nonisolated var role: String? {
    switch payload {
    case .experience(let value): value.role?.rawValue
    case .expression(let value): value.role.rawValue
    default: nil
    }
  }

  nonisolated var text: String? {
    switch payload {
    case .experience(let value):
      return value.text
    case .thought(let value):
      return value.text
    case .appraisal(let value):
      return value.summary
    case .needState(let value):
      return value.summary
    case .attentionState(let value):
      return value.summary
    case .intention(let value):
      return value.goal
    case .capabilityRequest(let value):
      if case .object(let arguments) = value.arguments {
        return arguments["text"]?.stringValue ?? arguments["summary"]?.stringValue
      } else {
        return nil
      }
    case .actionResult(let value):
      return value.summary
    case .expression(let value):
      return value.text
    case .memoryResult(let value):
      return value.summary
    case .memoryMutation(let value):
      return value.summary
    case .control(let value):
      return value.status
    case .error(let value):
      return value.message
    default:
      return nil
    }
  }

  var state: String? {
    if case .control(let value) = payload { value.phase?.rawValue ?? value.status } else { nil }
  }

  var enabled: Bool? {
    if case .control(let value) = payload { value.sendEnabled } else { nil }
  }

  var kind: String? {
    switch payload {
    case .thought: "thought"
    case .appraisal: "appraisal"
    case .needState: "need_state"
    case .attentionState: "attention_state"
    case .intention: "intention"
    case .memoryMutation: "memory"
    default: nil
    }
  }

  var title: String? {
    switch payload {
    case .expression(let value): value.title
    case .memoryResult(let value): value.operation.rawValue
    case .memoryMutation(let value): value.operation.rawValue
    case .attentionState(let value): value.suppressionReason
    case .senseRequest(let value): "\(value.senseID) sense"
    case .capabilityRequest(let value): value.action
    case .actionResult(let value): value.actionID
    default: nil
    }
  }

  var body: String? { text }

  var sense: String? {
    switch payload {
    case .senseRequest(let value): value.senseID
    case .senseObservation(let value): value.senseID
    case .capabilityRequest(let value):
      if case .object(let arguments) = value.arguments { arguments["sense"]?.stringValue } else { nil }
    default: nil
    }
  }

  var senseID: String? { sense }

  var senseDirection: String? {
    if case .senseRequest(let value) = payload { value.direction.rawValue } else { nil }
  }

  var availability: String? {
    if case .capabilityStatus(let value) = payload { value.availability } else { nil }
  }

  var permissionState: String? {
    if case .capabilityStatus(let value) = payload { value.permission } else { nil }
  }

  var statusReason: String? { reason }

  var observedAt: String? {
    if case .senseObservation(let value) = payload { value.observedAt } else { nil }
  }

  var terminal: Bool? {
    if case .actionResult = payload { true } else { nil }
  }

  var eyes: String? {
    switch payload {
    case .expression(let value):
      return value.eyes
    case .capabilityRequest(let value):
      if case .object(let arguments) = value.arguments { return arguments["eyes"]?.stringValue } else { return nil }
    default:
      return nil
    }
  }

  var mouth: String? {
    switch payload {
    case .expression(let value):
      return value.mouth
    case .capabilityRequest(let value):
      if case .object(let arguments) = value.arguments { return arguments["mouth"]?.stringValue } else { return nil }
    default:
      return nil
    }
  }

  var durationMS: Int? {
    if case .expression(let value) = payload { value.durationMS } else { nil }
  }

  var mediaKind: String? {
    switch payload {
    case .experience(let value): value.media.first?.kind.rawValue
    case .senseObservation(let value): value.media.first?.kind.rawValue
    case .expression(let value): value.media.first?.kind.rawValue
    default: nil
    }
  }

  var path: String? {
    switch payload {
    case .experience(let value): value.media.first?.path
    case .senseObservation(let value): value.media.first?.path
    case .expression(let value): value.media.first?.path
    default: nil
    }
  }

  var url: String? {
    switch payload {
    case .experience(let value): value.media.first?.url
    case .senseObservation(let value): value.media.first?.url
    case .expression(let value): value.media.first?.url
    default: nil
    }
  }

  var mimeType: String? {
    switch payload {
    case .experience(let value): value.media.first?.mimeType
    case .senseObservation(let value): value.media.first?.mimeType
    case .expression(let value): value.media.first?.mimeType
    default: nil
    }
  }

  var caption: String? {
    switch payload {
    case .experience(let value): value.media.first?.caption
    case .senseObservation(let value): value.media.first?.caption
    case .expression(let value): value.media.first?.caption
    default: nil
    }
  }

  var responsePresentation: String? {
    if case .senseRequest(let value) = payload { value.responsePresentation.rawValue } else { nil }
  }

  var awaitResponse: Bool? {
    switch payload {
    case .capabilityRequest(let value): value.awaitResponse
    case .senseRequest(let value): value.timeoutMS != nil
    default: nil
    }
  }

  var timeoutMS: Int? {
    if case .senseRequest(let value) = payload { value.timeoutMS } else { nil }
  }
}

nonisolated struct BrainDispatchError: Codable, Equatable {
  let code: String
  let message: String
  let recoverable: Bool?
}

nonisolated struct BrainDispatchBudget: Codable, Equatable {
  let maxBytes: Int
  let usedBytes: Int
  let compacted: Bool
  let droppedEventCount: Int
  let rawRefs: [String]

  private enum CodingKeys: String, CodingKey {
    case maxBytes = "max_bytes"
    case usedBytes = "used_bytes"
    case compacted
    case droppedEventCount = "dropped_event_count"
    case rawRefs = "raw_refs"
  }
}

nonisolated enum BrainCoreError: Error, LocalizedError, Equatable {
  case malformedResponse
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .malformedResponse:
      "Brain core returned a malformed response."
    case .unavailable(let message):
      "Brain core is unavailable: \(message)"
    }
  }
}
