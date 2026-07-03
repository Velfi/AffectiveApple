import Foundation

public enum ScenarioSemanticGrade: Equatable {
    case pass
    case fail(String)
    case notApplicable

    public var passed: Bool {
        switch self {
        case .pass, .notApplicable:
            return true
        case .fail:
            return false
        }
    }
}

public enum ScenarioGrader {
    public static func grade(scenarioId: String, jsonObject: [String: Any]) -> ScenarioSemanticGrade {
        switch scenarioId {
        case "conversation_host_sense_delivery_low_materiality":
            return emptyActionPressures(jsonObject, label: "host sense delivery with low materiality")

        case "want_achievement_busy_morning_hello",
             "want_achievement_fragmented_focus_day",
             "want_achievement_garden_win_distractor",
             "want_achievement_flow_state_interruption",
             "want_achievement_score_invariance_low",
             "want_achievement_score_invariance_high":
            return emptyMatches(jsonObject)

        case "want_achievement_wfh_deep_work":
            return wfhDeepWorkGrade(jsonObject)

        case "process_composition_interaction":
            return processCompositionGrade(jsonObject, expectedOrigin: "interaction", noCamera: true)

        case "process_composition_autonomy":
            return processCompositionGrade(jsonObject, expectedOrigin: "autonomy", noCamera: true)

        case "conversation_speech_no_verbatim_echo":
            return noVerbatimSpeechEchoGrade(jsonObject, userUtterance: "Can you hear me?")

        case "conversation_speech_no_verbatim_echo_yo":
            return noVerbatimSpeechEchoGrade(jsonObject, userUtterance: "Yo")

        case "conversation_speech_no_verbatim_echo_ty_geisha":
            return noVerbatimSpeechEchoGrade(jsonObject, userUtterance: "ty Geisha")

        default:
            return .notApplicable
        }
    }

    public static func grade(scenarioId: String, rawText: String?) -> ScenarioSemanticGrade {
        guard let rawText, !rawText.isEmpty else {
            return .notApplicable
        }
        guard let data = rawText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .notApplicable
        }
        return grade(scenarioId: scenarioId, jsonObject: object)
    }

    private static func emptyActionPressures(_ object: [String: Any], label: String) -> ScenarioSemanticGrade {
        guard let pressures = object["action_pressures"] as? [Any] else {
            return .fail("Missing action_pressures for \(label).")
        }
        if pressures.isEmpty {
            return .pass
        }
        return .fail("Expected empty action_pressures for \(label); got \(pressures.count) step(s).")
    }

    private static func emptyMatches(_ object: [String: Any]) -> ScenarioSemanticGrade {
        guard let matches = object["matches"] as? [Any] else {
            return .fail("Missing matches array.")
        }
        if matches.isEmpty {
            return .pass
        }
        let ids = matchMemoryIds(from: matches)
        return .fail("Expected no fulfilled wants; got \(ids.joined(separator: ", ")).")
    }

    private static func wfhDeepWorkGrade(_ object: [String: Any]) -> ScenarioSemanticGrade {
        guard let matches = object["matches"] as? [Any] else {
            return .fail("Missing matches array.")
        }
        let ids = Set(matchMemoryIds(from: matches))
        if ids == ["want_quiet_space"] {
            return .pass
        }
        if ids.contains("want_creative_momentum") {
            return .fail("Firmware deep work must not fulfill want_creative_momentum.")
        }
        if ids.isEmpty {
            return .fail("Expected want_quiet_space match only.")
        }
        return .fail("Expected want_quiet_space only; got \(ids.sorted().joined(separator: ", ")).")
    }

    private static func processCompositionGrade(
        _ object: [String: Any],
        expectedOrigin: String,
        noCamera: Bool
    ) -> ScenarioSemanticGrade {
        guard let pressures = object["action_pressures"] as? [[String: Any]] else {
            return .fail("Missing action_pressures array.")
        }
        if pressures.isEmpty {
            return .fail("Expected at least one action_pressure.")
        }
        let blockedCameraActions: Set<String> = ["recognize", "take_picture", "describe_image", "compare_images"]
        for (index, step) in pressures.enumerated() {
            guard let action = step["action"] as? String else {
                return .fail("Step \(index + 1) missing action.")
            }
            if noCamera, blockedCameraActions.contains(action) {
                return .fail("Camera action '\(action)' blocked when no camera available.")
            }
            let origin = step["origin"] as? String ?? expectedOrigin
            if origin != expectedOrigin {
                return .fail("Step \(index + 1) (\(action)) origin must be '\(expectedOrigin)'; got '\(origin)'.")
            }
            if action == "introspect", let query = step["query"] as? String {
                if !query.hasPrefix("skill/"), !query.hasPrefix("skills/") {
                    return .fail("introspect query must start with skill/ or skills/; got '\(query)'.")
                }
            }
            if action == "feel_about" {
                let query = step["query"] as? String
                let text = step["text"] as? String
                if query == nil || query?.isEmpty == true {
                    return .fail("feel_about requires query, not text.")
                }
                if let text, !text.isEmpty {
                    return .fail("feel_about must not use text.")
                }
                if step["scale"] != nil, let scale = step["scale"] as? String, !scale.isEmpty {
                    return .fail("feel_about must not set scale.")
                }
                if let stepKind = step["step_kind"] as? String, stepKind == "respond" {
                    return .fail("feel_about step_kind must be sync_capability, not respond.")
                }
            }
            if action == "think_about" {
                if step["scale"] != nil, let scale = step["scale"] as? String, !scale.isEmpty {
                    return .fail("think_about must not set scale.")
                }
                if let stepKind = step["step_kind"] as? String, stepKind == "respond" {
                    return .fail("think_about step_kind must be sync_capability, not respond.")
                }
            }
        }
        return .pass
    }

    private static func noVerbatimSpeechEchoGrade(_ object: [String: Any], userUtterance: String) -> ScenarioSemanticGrade {
        guard let pressures = object["action_pressures"] as? [[String: Any]] else {
            return .fail("Missing action_pressures array.")
        }
        let spoken = pressures.compactMap { pressure -> String? in
            guard let action = pressure["action"] as? String else { return nil }
            guard action == "say" || action == "speak" else { return nil }
            return pressure["text"] as? String
        }
        guard !spoken.isEmpty else {
            return .fail("Expected a say/speak action responding to fresh direct speech.")
        }
        let normalizedUser = normalizedSpeech(userUtterance)
        for text in spoken {
            let normalizedText = normalizedSpeech(text)
            if normalizedText == normalizedUser || containsNormalizedPhrase(normalizedText, normalizedUser) {
                return .fail("Visible speech included the full user utterance verbatim.")
            }
        }
        return .pass
    }

    private static func containsNormalizedPhrase(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return text == phrase
            || text.hasPrefix("\(phrase) ")
            || text.hasSuffix(" \(phrase)")
            || text.contains(" \(phrase) ")
    }

    private static func normalizedSpeech(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = text.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func matchMemoryIds(from matches: [Any]) -> [String] {
        matches.compactMap { item in
            guard let dict = item as? [String: Any],
                  let memoryId = dict["memory_id"] as? String
            else {
                return nil
            }
            return memoryId
        }
    }
}
