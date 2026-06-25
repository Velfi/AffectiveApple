//
//  Split from BrainCore.swift
//  Affective
//

import Foundation

#if os(iOS) || os(macOS)
  nonisolated struct ConversationTurnPayload {
    let userText: String
    let spokenText: String
    let userSummary: String
    let brainSummary: String
    let interruptedBy: String?

    static func decode(from text: String) -> ConversationTurnPayload {
      guard let data = text.data(using: .utf8),
        let object = try? JSONValue.decodedObject(from: data)
      else {
        return ConversationTurnPayload(
          userText: "", spokenText: text, userSummary: "", brainSummary: "", interruptedBy: nil)
      }

      return ConversationTurnPayload(
        userText: object["user_text"]?.stringValue ?? "",
        spokenText: object["spoken_text"]?.stringValue ?? "",
        userSummary: object["user_summary"]?.stringValue ?? "",
        brainSummary: object["brain_summary"]?.stringValue ?? "",
        interruptedBy: object["interrupted_by"]?.stringValue
      )
    }

    func metadata() -> [String: String] {
      var metadata = ["state": "mutating turn"]
      if !userText.isEmpty {
        metadata["user_text"] = userText
      }
      if !spokenText.isEmpty {
        metadata["spoken_text"] = spokenText
      }
      if !userSummary.isEmpty {
        metadata["user_summary"] = userSummary
      }
      if !brainSummary.isEmpty {
        metadata["brain_summary"] = brainSummary
      }
      if let interruptedBy {
        metadata["interrupted_by"] = interruptedBy
      }
      metadata["spoken_text_present"] = String(!spokenText.isEmpty)
      metadata["brain_summary_present"] = String(!brainSummary.isEmpty)
      metadata["user_summary_present"] = String(!userSummary.isEmpty)
      return metadata
    }

    func displaySource(rawJSON: String) -> String {
      if !spokenText.isEmpty {
        return "spoken_text"
      }
      if !brainSummary.isEmpty {
        return "brain_summary"
      }
      return rawJSON.isEmpty ? "empty" : "raw_json"
    }

    var isTestEchoResponse: Bool {
      spokenText == "I heard you say: \(userText)"
        && brainSummary == "Acknowledged the user and kept the exchange brief."
    }
  }

  nonisolated struct CommandResultPayload {
    let command: String
    let observation: String
    let spokenText: String
    let endedWithSpeech: Bool
    let interruptedBy: String?

    static func decode(from text: String) -> CommandResultPayload? {
      guard let data = text.data(using: .utf8),
        let object = try? JSONValue.decodedObject(from: data),
        object["command"] != nil,
        object["observation"] != nil,
        object["ended_with_speech"] != nil
      else {
        return nil
      }

      return CommandResultPayload(
        command: object["command"]?.stringValue ?? "",
        observation: object["observation"]?.stringValue ?? "",
        spokenText: object["spoken_text"]?.stringValue ?? "",
        endedWithSpeech: object["ended_with_speech"]?.boolValue ?? false,
        interruptedBy: Self.interruptedBy(from: object["interrupted_by"])
      )
    }

    func displayText(rawJSON: String) -> String {
      if !spokenText.isEmpty {
        return spokenText
      }
      if !observation.isEmpty {
        return observation
      }
      return ""
    }

    func metadata(rawJSON: String) -> [String: String] {
      var metadata = [
        "state": "command result",
        "command": command,
        "ended_with_speech": String(endedWithSpeech),
        "spoken_text_present": String(!spokenText.isEmpty),
        "observation_present": String(!observation.isEmpty),
        "display_source": displaySource(rawJSON: rawJSON),
        "display_text_length": "\(displayText(rawJSON: rawJSON).count)",
        "raw_json_length": "\(rawJSON.count)",
      ]
      if !spokenText.isEmpty {
        metadata["spoken_text"] = spokenText
      }
      if !observation.isEmpty {
        metadata["observation"] = observation
      }
      if let interruptedBy {
        metadata["interrupted_by"] = interruptedBy
      }
      return metadata
    }

    func displaySource(rawJSON: String) -> String {
      if !spokenText.isEmpty {
        return "spoken_text"
      }
      if !observation.isEmpty {
        return "observation"
      }
      return rawJSON.isEmpty ? "empty" : "raw_json"
    }

    static func interruptedBy(from value: JSONValue?) -> String? {
      if case .null? = value {
        return nil
      }
      if let string = value?.stringValue {
        return string
      }
      if let object = value?.objectValue {
        return object["kind"]?.stringValue
      }
      return nil
    }
  }
#endif
