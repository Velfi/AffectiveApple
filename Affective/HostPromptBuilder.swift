//
//  HostPromptBuilder.swift
//  Affective
//

import Foundation

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
  let systemPrompt: String
  let userPrompt: String
  let responseFormat: String
  let maxTokens: Int?
  let jsonSchema: String?

  enum CodingKeys: String, CodingKey {
    case systemPrompt = "system_prompt"
    case userPrompt = "user_prompt"
    case responseFormat = "response_format"
    case maxTokens = "max_tokens"
    case jsonSchema = "json_schema"
  }

  init(
    systemPrompt: String,
    userPrompt: String,
    responseFormat: String,
    maxTokens: Int? = nil,
    jsonSchema: String? = nil
  ) {
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.responseFormat = responseFormat
    self.maxTokens = maxTokens
    self.jsonSchema = jsonSchema
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
