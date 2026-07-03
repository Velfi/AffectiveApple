//
//  HostPromptBuilder.swift
//  Affective
//

import Foundation

nonisolated struct HostLLMRequestedModel: Decodable, Equatable {
  let provider: String
  let model: String
}

nonisolated struct HostLLMCompletionObservation: Sendable, Equatable {
  var generationID: String
  var subsystem: String
  var effortTier: String?
  var responseSize: String?
  var reasoningEffort: String?
  var requestedModels: String
  var provider: String
  var maxTokens: Int
  var responseFormat: String
  var promptHash: String
  var responseHash: String
  var promptCharacterCount: Int
  var responseCharacterCount: Int
  var promptExcerpt: String
  var responseExcerpt: String
  var contextStimulusIDs: [String]

  var eventLogBody: String {
    var parts = [String]()
    parts.append("generation_id=\(generationID)")
    if let effortTier, !effortTier.isEmpty {
      parts.append("effort_tier=\(effortTier)")
    }
    if let responseSize, !responseSize.isEmpty {
      parts.append("response_size=\(responseSize)")
    }
    if let reasoningEffort, !reasoningEffort.isEmpty {
      parts.append("reasoning_effort=\(reasoningEffort)")
    }
    parts.append("provider=\(provider)")
    parts.append("max_tokens=\(maxTokens)")
    parts.append("format=\(responseFormat)")
    parts.append("prompt_hash=\(promptHash)")
    parts.append("response_hash=\(responseHash)")
    parts.append("prompt_chars=\(promptCharacterCount)")
    parts.append("response_chars=\(responseCharacterCount)")
    if !contextStimulusIDs.isEmpty {
      parts.append("context_stimuli=\(contextStimulusIDs.joined(separator: ","))")
    }
    if !requestedModels.isEmpty {
      parts.append("models=\(requestedModels)")
    }
    return parts.joined(separator: " ")
  }

  var eventLogMetadata: [String: String] {
    var metadata: [String: String] = [
      "generation_id": generationID,
      "subsystem": subsystem,
      "provider": provider,
      "max_tokens": String(maxTokens),
      "response_format": responseFormat,
      "prompt_hash": promptHash,
      "response_hash": responseHash,
      "prompt_chars": String(promptCharacterCount),
      "response_chars": String(responseCharacterCount),
    ]
    if !promptExcerpt.isEmpty {
      metadata["prompt_excerpt"] = promptExcerpt
    }
    if !responseExcerpt.isEmpty {
      metadata["response_excerpt"] = responseExcerpt
    }
    if !contextStimulusIDs.isEmpty {
      metadata["context_stimulus_ids"] = contextStimulusIDs.joined(separator: ",")
    }
    if let effortTier, !effortTier.isEmpty {
      metadata["effort_tier"] = effortTier
    }
    if let responseSize, !responseSize.isEmpty {
      metadata["response_size"] = responseSize
    }
    if let reasoningEffort, !reasoningEffort.isEmpty {
      metadata["reasoning_effort"] = reasoningEffort
    }
    if !requestedModels.isEmpty {
      metadata["requested_models"] = requestedModels
    }
    return metadata
  }
}

nonisolated struct HostLLMPromptInput: Equatable {
  var systemPrompt: String
  var userPrompt: String
  var responseFormat: HostResponseFormat
  var jsonSchema: String?

  init(
    systemPrompt: String,
    userPrompt: String,
    responseFormat: HostResponseFormat = .text,
    jsonSchema: String? = nil
  ) {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.responseFormat = responseFormat
    self.jsonSchema = jsonSchema
  }

  init(payload: HostLLMPromptPayload) {
    self.init(
      systemPrompt: payload.systemPrompt,
      userPrompt: payload.userPrompt,
      responseFormat: HostResponseFormat(rawValue: payload.responseFormat) ?? .text,
      jsonSchema: payload.jsonSchema
    )
  }
}

nonisolated struct HostLLMPromptPayload: Decodable {
  let subsystem: String?
  let systemPrompt: String
  let userPrompt: String
  let responseFormat: String
  let responseSize: String?
  let effortTier: String?
  let reasoningEffort: String?
  let maxTokens: Int?
  let temperature: Double?
  let jsonSchema: String?
  let models: [HostLLMRequestedModel]?

  enum CodingKeys: String, CodingKey {
    case subsystem
    case systemPrompt = "system_prompt"
    case userPrompt = "user_prompt"
    case responseFormat = "response_format"
    case responseSize = "response_size"
    case effortTier = "effort_tier"
    case reasoningEffort = "reasoning_effort"
    case maxTokens = "max_tokens"
    case temperature
    case jsonSchema = "json_schema"
    case models
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subsystem = try container.decodeIfPresent(String.self, forKey: .subsystem)
    systemPrompt = try container.decode(HostLLMJSONStringField.self, forKey: .systemPrompt).value
    userPrompt = try container.decode(HostLLMJSONStringField.self, forKey: .userPrompt).value
    responseFormat = try container.decode(String.self, forKey: .responseFormat)
    responseSize = try container.decodeIfPresent(String.self, forKey: .responseSize)
    effortTier = try container.decodeIfPresent(String.self, forKey: .effortTier)
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
    temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
    jsonSchema = try container.decodeIfPresent(HostLLMJSONStringField.self, forKey: .jsonSchema)?.value
    models = try container.decodeIfPresent([HostLLMRequestedModel].self, forKey: .models)
  }

  init(
    subsystem: String? = nil,
    systemPrompt: String,
    userPrompt: String,
    responseFormat: String,
    responseSize: String? = nil,
    effortTier: String? = nil,
    reasoningEffort: String? = nil,
    maxTokens: Int? = nil,
    temperature: Double? = nil,
    jsonSchema: String? = nil,
    models: [HostLLMRequestedModel]? = nil
  ) {
    self.subsystem = subsystem
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.responseFormat = responseFormat
    self.responseSize = responseSize
    self.effortTier = effortTier
    self.reasoningEffort = reasoningEffort
    self.maxTokens = maxTokens
    self.temperature = temperature
    self.jsonSchema = jsonSchema
    self.models = models
  }

  func completionObservation(
    provider: String,
    maxTokens: Int,
    prompt: String,
    response: String,
    generationID: String = UUID().uuidString
  ) -> HostLLMCompletionObservation {
    HostLLMCompletionObservation(
      generationID: generationID,
      subsystem: subsystem ?? "unknown",
      effortTier: effortTier,
      responseSize: responseSize,
      reasoningEffort: reasoningEffort,
      requestedModels: models?.map { "\($0.provider):\($0.model)" }.joined(separator: ", ") ?? "",
      provider: provider,
      maxTokens: maxTokens,
      responseFormat: responseFormat,
      promptHash: Self.stableTextHash(prompt),
      responseHash: Self.stableTextHash(response),
      promptCharacterCount: prompt.count,
      responseCharacterCount: response.count,
      promptExcerpt: Self.excerpt(prompt, limit: 240),
      responseExcerpt: Self.excerpt(response, limit: 240),
      contextStimulusIDs: Self.extractStimulusIDs(from: prompt)
    )
  }

  nonisolated static func stableTextHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
  }

  nonisolated static func excerpt(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit))
  }

  nonisolated static func extractStimulusIDs(from text: String) -> [String] {
    var ids = [String]()
    var seen = Set<String>()
    var remainder = text[...]
    while let range = remainder.range(of: "id=stimulus_") {
      var cursor = range.upperBound
      while cursor < remainder.endIndex {
        let character = remainder[cursor]
        guard character.isNumber else { break }
        cursor = remainder.index(after: cursor)
      }
      guard cursor > range.upperBound else {
        remainder = remainder[cursor...]
        continue
      }
      let id = "stimulus_" + String(remainder[range.upperBound..<cursor])
      if !seen.contains(id) {
        seen.insert(id)
        ids.append(String(id))
      }
      remainder = remainder[cursor...]
    }
    return ids
  }
}

nonisolated enum HostLLMJSONStringField: Decodable {
  case text(String)
  case bytes([UInt8])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self = .text(text)
      return
    }
    if let bytes = try? container.decode([UInt8].self) {
      self = .bytes(bytes)
      return
    }
    throw DecodingError.typeMismatch(
      HostLLMJSONStringField.self,
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Expected String or [UInt8] for host LLM prompt field"
      )
    )
  }

  var value: String {
    switch self {
    case .text(let text):
      return text
    case .bytes(let bytes):
      return String(decoding: bytes, as: UTF8.self)
    }
  }
}

nonisolated enum HostPromptBuilder {
  static func combinedPrompt(for input: HostLLMPromptInput) -> String {
    var sections = [
      "System:\n\(input.systemPrompt)",
      "User:\n\(input.userPrompt)",
    ]
    if input.responseFormat == .jsonObject {
      var jsonInstruction = "Return only a valid JSON object."
      if let schema = input.jsonSchema?.trimmingCharacters(in: .whitespacesAndNewlines), !schema.isEmpty {
        jsonInstruction += "\nJSON schema:\n\(schema)"
      }
      sections.append(jsonInstruction)
    }
    return sections.joined(separator: "\n\n")
  }

  static func combinedPrompt(for payload: HostLLMPromptPayload) -> String {
    combinedPrompt(for: HostLLMPromptInput(payload: payload))
  }
}
