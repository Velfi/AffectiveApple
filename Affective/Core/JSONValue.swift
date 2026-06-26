//
//  Split from BrainCore.swift
//  Affective
//

import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  nonisolated var stringValue: String? {
    if case .string(let value) = self { value } else { nil }
  }

  nonisolated var arrayValue: [JSONValue]? {
    if case .array(let value) = self { value } else { nil }
  }

  nonisolated var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { value } else { nil }
  }

  nonisolated var boolValue: Bool? {
    if case .bool(let value) = self { value } else { nil }
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  nonisolated func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  nonisolated func encodedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  nonisolated static func decodedObject(from data: Data) throws -> [String: JSONValue] {
    guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      throw BrainCoreError.malformedResponse
    }
    return object
  }
}

nonisolated struct PokePulse: Equatable {
  let pressMilliseconds: Double
  let pauseBeforeMilliseconds: Double
}

nonisolated enum LanguageInputSource: String {
  case typedText = "user_message"

  var eventType: String {
    rawValue
  }
}
