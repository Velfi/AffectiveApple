import XCTest
@testable import LlmTesterReport

final class ScenarioGraderTests: XCTestCase {
    func testHostSenseDeliveryRequiresEmptyActions() throws {
        let bad = #"{"action_pressures":[{"action":"recognize","origin":"interaction","tags":[]}],"turn_complete":true}"#
        let grade = ScenarioGrader.grade(scenarioId: "conversation_host_sense_delivery_low_materiality", rawText: bad)
        guard case .fail = grade else {
            return XCTFail("Expected semantic failure")
        }

        let good = #"{"action_pressures":[],"turn_complete":true}"#
        XCTAssertEqual(ScenarioGrader.grade(scenarioId: "conversation_host_sense_delivery_low_materiality", rawText: good), .pass)
    }

    func testBusyMorningRequiresEmptyMatches() {
        let bad = #"{"matches":[{"memory_id":"want_connection","confidence":0.86,"evidence":"squeezed my shoulder"}]}"#
        guard case .fail = ScenarioGrader.grade(scenarioId: "want_achievement_busy_morning_hello", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
    }

    func testWfhDeepWorkRejectsCreativeMatch() {
        let bad = #"{"matches":[{"memory_id":"want_quiet_space","confidence":0.88,"evidence":"flow"},{"memory_id":"want_creative_momentum","confidence":0.84,"evidence":"firmware bug"}]}"#
        guard case .fail(let message) = ScenarioGrader.grade(scenarioId: "want_achievement_wfh_deep_work", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
        XCTAssertTrue(message.contains("want_creative_momentum"))
    }

    func testProcessCompositionInteractionRejectsWrongOrigin() {
        let bad = #"{"action_pressures":[{"action":"think_about","origin":"autonomy","query":"touch","tags":[]}],"reason":"x"}"#
        guard case .fail(let message) = ScenarioGrader.grade(scenarioId: "process_composition_interaction", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
        XCTAssertTrue(message.contains("interaction"))
    }

    func testSpeechEchoScenarioRejectsVerbatimUserUtterance() {
        let bad = #"{"salience":"medium","reason":"answering direct speech","action_pressures":[{"action":"say","origin":"autonomy","delay_ms":null,"scale":"tiny","text":"Can you hear me?","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["speech"]}]}"#
        guard case .fail(let message) = ScenarioGrader.grade(scenarioId: "conversation_speech_no_verbatim_echo", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
        XCTAssertTrue(message.contains("full user utterance"))
    }

    func testSpeechEchoScenarioAcceptsDirectNonEchoResponse() {
        let good = #"{"salience":"medium","reason":"answering direct speech","action_pressures":[{"action":"say","origin":"autonomy","delay_ms":null,"scale":"tiny","text":"Yes, I can hear you.","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["speech"]}]}"#
        XCTAssertEqual(ScenarioGrader.grade(scenarioId: "conversation_speech_no_verbatim_echo", rawText: good), .pass)
    }

    func testSpeechEchoScenarioRejectsShortGreetingEcho() {
        let bad = #"{"salience":"medium","reason":"answering direct speech","action_pressures":[{"action":"say","origin":"autonomy","delay_ms":null,"scale":"tiny","text":"Yo","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["speech"]}]}"#
        guard case .fail = ScenarioGrader.grade(scenarioId: "conversation_speech_no_verbatim_echo_yo", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
    }

    func testSpeechEchoScenarioRejectsQuotedUtteranceInsideResponse() {
        let bad = #"{"salience":"medium","reason":"answering direct speech","action_pressures":[{"action":"say","origin":"autonomy","delay_ms":null,"scale":"tiny","text":"I noticed the message 'ty Geisha.' I'm here quietly if you'd like to continue.","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["speech"]}]}"#
        guard case .fail(let message) = ScenarioGrader.grade(scenarioId: "conversation_speech_no_verbatim_echo_ty_geisha", rawText: bad) else {
            return XCTFail("Expected semantic failure")
        }
        XCTAssertTrue(message.contains("full user utterance"))
    }

    func testUnknownScenarioIsNotApplicable() {
        XCTAssertEqual(ScenarioGrader.grade(scenarioId: "conversation_greeting", rawText: #"{"action_pressures":[]}"#), .notApplicable)
    }
}
