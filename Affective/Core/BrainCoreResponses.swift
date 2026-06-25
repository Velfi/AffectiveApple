//
//  Split from BrainCore.swift
//  Affective
//

import Foundation

nonisolated struct BrainTextResponse: Equatable {
  let toolName: String
  let text: String
  let metadata: [String: String]
  let events: [BrainHostEvent]
}

nonisolated struct BrainStateSnapshot: Equatable {
  let toolName: String
  let text: String
  let metadata: [String: String]
}

nonisolated struct BrainToolResponse: Equatable {
  let toolName: String
  let text: String
  let rawText: String
  let metadata: [String: String]
  let shouldSpeak: Bool
  let events: [BrainHostEvent]

  init(toolName: String, rawText: String) {
    self.toolName = toolName
    self.rawText = rawText
    events = []

    let payload = CommandResultPayload.decode(from: rawText)
    if let payload {
      let displayText = payload.displayText(rawJSON: rawText)
      text = displayText
      metadata = Self.migrationFallbackMetadata(
        payload.metadata(rawJSON: rawText),
        kind: "legacy_command_result"
      )
      shouldSpeak = payload.endedWithSpeech && !payload.spokenText.isEmpty
    } else {
      text = rawText
      metadata = Self.migrationFallbackMetadata([
        "display_source": rawText.isEmpty ? "empty" : "raw_text",
        "display_text_length": "\(rawText.count)",
      ], kind: rawText.isEmpty ? "empty_legacy_result" : "raw_text")
      shouldSpeak = false
    }
  }

  init(toolName: String, envelope: BrainDispatchEnvelope, rawText: String) {
    self.toolName = toolName
    self.rawText = rawText
    events = envelope.events

    let outputJSON = envelope.toolOutputJSON ?? envelope.resultSummary ?? rawText
    let payload = CommandResultPayload.decode(from: outputJSON)
    let eventText = envelope.displayTextFromEvents
    if let payload {
      let fallbackText = payload.displayText(rawJSON: outputJSON)
      text = eventText.isEmpty ? fallbackText : eventText
      var mergedMetadata = payload.metadata(rawJSON: outputJSON)
      mergedMetadata.merge(envelope.metadata()) { current, _ in current }
      mergedMetadata["display_source"] = eventText.isEmpty ? mergedMetadata["display_source"] : "event_envelope"
      if eventText.isEmpty {
        mergedMetadata = Self.migrationFallbackMetadata(
          mergedMetadata,
          kind: "legacy_command_result"
        )
      }
      metadata = mergedMetadata
      shouldSpeak = !envelope.speechTexts.isEmpty || (payload.endedWithSpeech && !payload.spokenText.isEmpty)
    } else {
      text = eventText.isEmpty ? outputJSON : eventText
      var mergedMetadata = envelope.metadata()
      mergedMetadata["display_source"] = eventText.isEmpty ? (outputJSON.isEmpty ? "empty" : "raw_text") : "event_envelope"
      mergedMetadata["display_text_length"] = "\(text.count)"
      if eventText.isEmpty {
        mergedMetadata = Self.migrationFallbackMetadata(
          mergedMetadata,
          kind: outputJSON.isEmpty ? "empty_legacy_result" : "raw_text"
        )
      }
      metadata = mergedMetadata
      shouldSpeak = !envelope.speechTexts.isEmpty
    }
  }

  private static func migrationFallbackMetadata(_ metadata: [String: String], kind: String) -> [String: String] {
    var annotated = metadata
    annotated["migration_fallback"] = kind
    annotated["fallback_warning"] = BrainCore.migrationFallbackWarning
    return annotated
  }
}

nonisolated enum BrainEventPresentation: String, Codable, Equatable {
  case chat
  case internalOnly = "internal"
  case status
  case log

  var mirrorsToChat: Bool {
    self == .chat
  }
}

nonisolated struct BrainHostEvent: Codable, Equatable {
  let type: String
  let requestID: String?
  let role: String?
  let text: String?
  let state: String?
  let enabled: Bool?
  let kind: String?
  let title: String?
  let body: String?
  let sense: String?
  let eyes: String?
  let mouth: String?
  let durationMS: Int?
  let mediaKind: String?
  let path: String?
  let url: String?
  let mimeType: String?
  let caption: String?
  let rawRef: String?
  let originalBytes: Int?
  let presentation: String?
  let responsePresentation: String?
  let awaitResponse: Bool?
  let timeoutMS: Int?

  init(
    type: String,
    requestID: String?,
    role: String?,
    text: String?,
    state: String?,
    enabled: Bool?,
    kind: String?,
    title: String?,
    body: String?,
    sense: String?,
    eyes: String?,
    mouth: String?,
    durationMS: Int?,
    mediaKind: String?,
    path: String?,
    url: String?,
    mimeType: String?,
    caption: String?,
    rawRef: String?,
    originalBytes: Int?,
    presentation: String? = nil,
    responsePresentation: String? = nil,
    awaitResponse: Bool? = nil,
    timeoutMS: Int? = nil
  ) {
    self.type = type
    self.requestID = requestID
    self.role = role
    self.text = text
    self.state = state
    self.enabled = enabled
    self.kind = kind
    self.title = title
    self.body = body
    self.sense = sense
    self.eyes = eyes
    self.mouth = mouth
    self.durationMS = durationMS
    self.mediaKind = mediaKind
    self.path = path
    self.url = url
    self.mimeType = mimeType
    self.caption = caption
    self.rawRef = rawRef
    self.originalBytes = originalBytes
    self.presentation = presentation
    self.responsePresentation = responsePresentation
    self.awaitResponse = awaitResponse
    self.timeoutMS = timeoutMS
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case requestID = "request_id"
    case role
    case text
    case state
    case enabled
    case kind
    case title
    case body
    case sense
    case eyes
    case mouth
    case durationMS = "duration_ms"
    case mediaKind = "media_kind"
    case path
    case url
    case mimeType = "mime_type"
    case caption
    case rawRef = "raw_ref"
    case originalBytes = "original_bytes"
    case presentation
    case responsePresentation = "response_presentation"
    case awaitResponse = "await_response"
    case timeoutMS = "timeout_ms"
  }
}

nonisolated struct BrainDispatchEnvelope: Codable, Equatable {
  let apiVersion: Int
  let requestID: String
  let ok: Bool
  let events: [BrainHostEvent]
  let result: JSONValue?
  let error: BrainDispatchError?
  let budget: BrainDispatchBudget?
  let rawText: String

  private enum CodingKeys: String, CodingKey {
    case apiVersion = "api_version"
    case requestID = "request_id"
    case ok
    case events
    case result
    case error
    case budget
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    apiVersion = try container.decode(Int.self, forKey: .apiVersion)
    requestID = try container.decode(String.self, forKey: .requestID)
    ok = try container.decode(Bool.self, forKey: .ok)
    events = try container.decodeIfPresent([BrainHostEvent].self, forKey: .events) ?? []
    result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
    error = try container.decodeIfPresent(BrainDispatchError.self, forKey: .error)
    budget = try container.decodeIfPresent(BrainDispatchBudget.self, forKey: .budget)
    rawText = ""
  }

  init(
    apiVersion: Int,
    requestID: String,
    ok: Bool,
    events: [BrainHostEvent],
    result: JSONValue?,
    error: BrainDispatchError?,
    budget: BrainDispatchBudget? = nil,
    rawText: String = ""
  ) {
    self.apiVersion = apiVersion
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
    try container.encode(apiVersion, forKey: .apiVersion)
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
      apiVersion: decoded.apiVersion,
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
      event.type == "speech_requested" ? event.text : nil
    }.filter { !$0.isEmpty }
  }

  var displayTextFromEvents: String {
    if let chatText = events.last(where: { $0.type == "chat_message" && $0.role == "brain" })?.text,
      !chatText.isEmpty
    {
      return chatText
    }
    if let speechText = speechTexts.last {
      return speechText
    }
    if let commandBody = events.last(where: { $0.type == "command_log" })?.body,
      !commandBody.isEmpty
    {
      return commandBody
    }
    if let captureBody = events.last(where: { $0.type == "capture_requested" })?.body,
      !captureBody.isEmpty
    {
      return captureBody
    }
    if let senseBody = events.last(where: { $0.type == "sense_requested" })?.body,
      !senseBody.isEmpty
    {
      return senseBody
    }
    return ""
  }

  var conversationTurnJSON: String? {
    if resultRawResult == true,
      let summary = resultSummary,
      eventType == "typed_text" || eventType == "speech_transcript"
    {
      return summary
    }
    return nil
  }

  var toolOutputJSON: String? {
    if resultRawResult == true, let summary = resultSummary, eventType == "tool_call" {
      return summary
    }
    return nil
  }

  var resultSummary: String? {
    result?.objectValue?["summary"]?.stringValue
  }

  var resultRawResult: Bool? {
    result?.objectValue?["raw_result"]?.boolValue
  }

  var eventType: String? {
    result?.objectValue?["event_type"]?.stringValue
  }

  func metadata() -> [String: String] {
    var values = [
      "api_version": "\(apiVersion)",
      "request_id": requestID,
      "event_count": "\(events.count)",
      "event_types": events.map(\.type).joined(separator: ","),
      "speech_event_count": "\(speechTexts.count)",
    ]
    if let budget {
      values["budget_max_bytes"] = "\(budget.maxBytes)"
      values["budget_used_bytes"] = "\(budget.usedBytes)"
      values["budget_compacted"] = "\(budget.compacted)"
      values["budget_dropped_event_count"] = "\(budget.droppedEventCount)"
      values["budget_raw_refs"] = budget.rawRefs.joined(separator: ",")
    }
    return values
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
