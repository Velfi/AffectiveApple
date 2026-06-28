import XCTest
import LlmTesterReport

final class HtmlReportTests: XCTestCase {
    func testRenderIncludesScenarioCardsAndHighlightAssets() throws {
        let scenario = makeScenario(
            id: "conversation_greeting",
            label: "Conversation turn",
            subsystem: "conversation",
            systemPrompt: "System rules",
            userPrompt: "Hello",
            jsonSchema: "{}"
        )
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: scenario,
                    combinedPrompt: "System:\nSystem rules\n\nUser:\nHello",
                    status: "ok",
                    prettyJSON: "{\n  \"action_pressures\" : [\n\n  ]\n}"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("highlight.min.js"))
        XCTAssertTrue(html.contains("conversation_greeting"))
        XCTAssertTrue(html.contains("Conversation turn"))
        XCTAssertTrue(html.contains("language-json"))
        XCTAssertTrue(html.contains("System Prompt"))
    }

    func testPromptSectionsCollapsedExceptResponse() throws {
        let scenario = makeScenario(
            userPrompt: "Stimulus: \"wave hello\"",
            jsonSchema: "{\"type\":\"object\"}"
        )
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: scenario,
                    combinedPrompt: "combined",
                    status: "ok",
                    prettyJSON: "{}"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("<details>\n  <summary>System Prompt</summary>"))
        XCTAssertTrue(html.contains("<details>\n  <summary>User Prompt</summary>"))
        XCTAssertTrue(html.contains("<details>\n  <summary>JSON Schema</summary>"))
        XCTAssertTrue(html.contains("<details>\n  <summary>Debug: combined prompt</summary>"))
        XCTAssertFalse(html.contains("<details open>\n  <summary>System Prompt</summary>"))
        XCTAssertFalse(html.contains("<summary>Combined Prompt</summary>"))
        XCTAssertTrue(html.contains("<details open>\n  <summary>Response JSON</summary>"))
    }

    func testStimulusHeadlineFromQuotedStimulus() throws {
        let headline = HtmlReport.extractStimulusHeadline(from: "Context block\nStimulus: \"hey there\"")
        XCTAssertEqual(headline, "hey there")
    }

    func testStimulusHeadlineFromWhatReachedYou() throws {
        let headline = HtmlReport.extractStimulusHeadline(from: "Context: idle\nWhat reached you: gentle tap")
        XCTAssertEqual(headline, "gentle tap")
    }

    func testStimulusHeadlineFallsBackToFirstLine() throws {
        let headline = HtmlReport.extractStimulusHeadline(from: "Plain user input\nMore lines")
        XCTAssertEqual(headline, "Plain user input")
    }

    func testCardShowsStimulusHeadline() throws {
        let scenario = makeScenario(userPrompt: "Stimulus: \"wave hello\"")
        let summary = makeSummary(
            results: [makeResult(scenario: scenario, combinedPrompt: "combined", status: "ok")]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"card-subtitle\">wave hello</p>"))
    }

    func testCardShowsScenarioDescription() throws {
        let description = "Validates that the model returns structured action pressures for a greeting turn."
        let scenario = makeScenario(description: description)
        let summary = makeSummary(
            results: [makeResult(scenario: scenario, combinedPrompt: "combined", status: "ok")]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"card-description\">\(description)</p>"))
    }

    func testResultsSortedFailuresFirst() throws {
        let ok = makeResult(
            scenario: makeScenario(id: "ok_scenario"),
            combinedPrompt: "combined",
            status: "ok"
        )
        let invalid = makeResult(
            scenario: makeScenario(id: "invalid_scenario"),
            combinedPrompt: "combined",
            status: "invalid_json",
            errorMessage: "bad json"
        )
        let error = makeResult(
            scenario: makeScenario(id: "error_scenario"),
            combinedPrompt: "combined",
            status: "error",
            errorMessage: "network"
        )
        let summary = makeSummary(results: [ok, invalid, error])

        let html = HtmlReport.render(summary: summary)
        let errorIndex = html.range(of: "error_scenario")!.lowerBound
        let invalidIndex = html.range(of: "invalid_scenario")!.lowerBound
        let okIndex = html.range(of: "ok_scenario")!.lowerBound
        XCTAssertLessThan(errorIndex, invalidIndex)
        XCTAssertLessThan(invalidIndex, okIndex)
    }

    func testStatusSortOrder() throws {
        XCTAssertLessThan(HtmlReport.statusSortOrder("error"), HtmlReport.statusSortOrder("invalid_json"))
        XCTAssertLessThan(HtmlReport.statusSortOrder("invalid_json"), HtmlReport.statusSortOrder("ok"))
    }

    func testSummaryIncludesStatusBreakdown() throws {
        let summary = makeSummary(
            total: 3,
            succeeded: 1,
            failed: 2,
            results: [
                makeResult(scenario: makeScenario(id: "a"), combinedPrompt: "c", status: "ok"),
                makeResult(scenario: makeScenario(id: "b"), combinedPrompt: "c", status: "invalid_json"),
                makeResult(scenario: makeScenario(id: "c"), combinedPrompt: "c", status: "error"),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"metric ok\""))
        XCTAssertTrue(html.contains(">OK</div><div class=\"value\">1</div>"))
        XCTAssertTrue(html.contains("class=\"metric invalid_json\""))
        XCTAssertTrue(html.contains(">Invalid JSON</div><div class=\"value\">1</div>"))
        XCTAssertTrue(html.contains("class=\"metric error\""))
        XCTAssertTrue(html.contains(">Error</div><div class=\"value\">1</div>"))
    }

    func testHoistsSharedSystemPromptWhenTwoOrMoreScenariosMatch() throws {
        let sharedPrompt = "Shared system instructions"
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "one", subsystem: "conversation", systemPrompt: sharedPrompt),
                    combinedPrompt: "combined one",
                    status: "ok"
                ),
                makeResult(
                    scenario: makeScenario(id: "two", subsystem: "conversation", systemPrompt: sharedPrompt),
                    combinedPrompt: "combined two",
                    status: "ok"
                ),
                makeResult(
                    scenario: makeScenario(id: "unique", subsystem: "intent", systemPrompt: "Different prompt"),
                    combinedPrompt: "combined unique",
                    status: "ok"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("Shared System Prompts"))
        XCTAssertTrue(html.contains("id=\"system-prompt-0\""))
        XCTAssertTrue(html.contains("Used by: one, two"))
        XCTAssertTrue(html.contains("href=\"#system-prompt-0\">▸ System prompt (shared)</a>"))
        XCTAssertTrue(html.contains("<details>\n  <summary>System Prompt</summary>"))
        let sharedLinkCount = html.components(separatedBy: "System prompt (shared)").count - 1
        XCTAssertEqual(sharedLinkCount, 2)
    }

    func testDoesNotHoistUniqueSystemPrompt() throws {
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "solo", systemPrompt: "Only one"),
                    combinedPrompt: "combined",
                    status: "ok"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertFalse(html.contains("Shared System Prompts"))
        XCTAssertTrue(html.contains("<summary>System Prompt</summary>"))
        XCTAssertFalse(html.contains("System prompt (shared)"))
    }

    func testBuildHoistedSystemPromptsRequiresAtLeastTwoMatches() throws {
        let shared = "Shared"
        let results = [
            makeResult(scenario: makeScenario(id: "a", systemPrompt: shared), combinedPrompt: "c", status: "ok"),
            makeResult(scenario: makeScenario(id: "b", systemPrompt: "Other"), combinedPrompt: "c", status: "ok"),
        ]
        XCTAssertEqual(HtmlReport.buildHoistedSystemPrompts(from: results).count, 0)
    }

    func testTableOfContentsLinksToScenarioCards() throws {
        let greeting = makeScenario(
            id: "conversation_greeting",
            label: "Conversation turn",
            userPrompt: "Stimulus: \"wave hello\""
        )
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "error_case", label: "Broken case"),
                    combinedPrompt: "c",
                    status: "error",
                    errorMessage: "boom"
                ),
                makeResult(
                    scenario: greeting,
                    combinedPrompt: "c",
                    status: "ok"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("<nav class=\"toc\" aria-label=\"Scenario table of contents\">"))
        XCTAssertTrue(html.contains("<div class=\"layout\">"))
        XCTAssertTrue(html.contains("href=\"#scenario-error_case\""))
        XCTAssertTrue(html.contains("href=\"#scenario-conversation_greeting\""))
        XCTAssertTrue(html.contains("id=\"scenario-error_case\""))
        XCTAssertTrue(html.contains("id=\"scenario-conversation_greeting\""))
        XCTAssertTrue(html.contains("<span class=\"toc-label\">error_case</span>"))
        XCTAssertTrue(html.contains("<span class=\"toc-label\">conversation_greeting</span>"))
        XCTAssertTrue(html.contains("class=\"toc-item\" data-subsystem=\"conversation\" data-status=\"error\""))
        XCTAssertTrue(html.contains("tocItems.forEach(function (item)"))
    }

    func testTableOfContentsFollowsFailureFirstOrder() throws {
        let summary = makeSummary(
            results: [
                makeResult(scenario: makeScenario(id: "ok_scenario", label: "OK case"), combinedPrompt: "c", status: "ok"),
                makeResult(
                    scenario: makeScenario(id: "invalid_scenario", label: "Invalid case"),
                    combinedPrompt: "c",
                    status: "invalid_json"
                ),
                makeResult(scenario: makeScenario(id: "error_scenario", label: "Error case"), combinedPrompt: "c", status: "error"),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        guard let tocStart = html.range(of: "<nav class=\"toc\""),
              let tocEnd = html.range(of: "</nav>", range: tocStart.upperBound..<html.endIndex)
        else {
            XCTFail("TOC nav not found")
            return
        }
        let toc = String(html[tocStart.lowerBound..<tocEnd.upperBound])
        let errorIndex = toc.range(of: "href=\"#scenario-error_scenario\"")!.lowerBound
        let invalidIndex = toc.range(of: "href=\"#scenario-invalid_scenario\"")!.lowerBound
        let okIndex = toc.range(of: "href=\"#scenario-ok_scenario\"")!.lowerBound
        XCTAssertLessThan(errorIndex, invalidIndex)
        XCTAssertLessThan(invalidIndex, okIndex)
    }

    func testScenarioAnchorIdSanitizesInvalidCharacters() throws {
        XCTAssertEqual(HtmlReport.scenarioAnchorId(for: "conversation_greeting"), "scenario-conversation_greeting")
        XCTAssertEqual(HtmlReport.scenarioAnchorId(for: "weird id/with spaces"), "scenario-weird-id-with-spaces")
    }

    func testFilterControlsPresentWithDataAttributes() throws {
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "conv_ok", subsystem: "conversation"),
                    combinedPrompt: "c",
                    status: "ok"
                ),
                makeResult(
                    scenario: makeScenario(id: "intent_error", subsystem: "intent"),
                    combinedPrompt: "c",
                    status: "error",
                    errorMessage: "boom"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("id=\"scenario-filters\""))
        XCTAssertTrue(html.contains("data-filter-type=\"subsystem\" data-filter-value=\"conversation\""))
        XCTAssertTrue(html.contains("data-filter-type=\"subsystem\" data-filter-value=\"intent\""))
        XCTAssertTrue(html.contains("data-filter-type=\"status\" data-filter-value=\"ok\""))
        XCTAssertTrue(html.contains("data-filter-type=\"status\" data-filter-value=\"error\""))
        XCTAssertTrue(html.contains("data-subsystem=\"conversation\" data-status=\"ok\""))
        XCTAssertTrue(html.contains("data-subsystem=\"intent\" data-status=\"error\""))
        XCTAssertTrue(html.contains("function applyFilters()"))
    }

    func testJsonSchemaSectionOmittedWhenEmpty() throws {
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(jsonSchema: "   "),
                    combinedPrompt: "combined",
                    status: "ok"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertFalse(html.contains("<summary>JSON Schema</summary>"))
    }

    func testCopyButtonAndEmbeddedSource() throws {
        let combinedPrompt = "System:\nRules\n\nUser:\nHello"
        let prettyJSON = "{\n  \"ok\" : true\n}"
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "copy_case"),
                    combinedPrompt: combinedPrompt,
                    status: "ok",
                    prettyJSON: prettyJSON
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"copy-btn\" data-default-label=\"Copy\">Copy</button>"))
        XCTAssertFalse(html.contains("Copy prompt"))
        XCTAssertFalse(html.contains("Copy response"))
        XCTAssertTrue(html.contains("class=\"copy-source\">\"--- Scenario: copy_case ---\\n\\nSystem:\\nRules\\n\\nUser:\\nHello\\n\\n--- Response ---\\n\\n{\\n  \\\"ok\\\" : true\\n}\"</script>"))
        XCTAssertTrue(html.contains("navigator.clipboard.writeText(text)"))
        XCTAssertTrue(html.contains("button.textContent = 'Copied!'"))
    }

    func testFullCopyTextIncludesResponseWhenPresent() throws {
        let result = makeResult(
            scenario: makeScenario(),
            combinedPrompt: "combined",
            status: "ok",
            prettyJSON: "{\n  \"ok\" : true\n}"
        )
        XCTAssertEqual(
            HtmlReport.fullCopyText(for: result),
            "--- Scenario: scenario_id ---\n\ncombined\n\n--- Response ---\n\n{\n  \"ok\" : true\n}"
        )
    }

    func testFullCopyTextIsPromptOnlyWhenNoResponse() throws {
        let result = makeResult(
            scenario: makeScenario(),
            combinedPrompt: "combined",
            status: "error"
        )
        XCTAssertEqual(HtmlReport.fullCopyText(for: result), "--- Scenario: scenario_id ---\n\ncombined")
    }

    func testAllCopyTextJoinsSortedScenarios() throws {
        let errorResult = makeResult(
            scenario: makeScenario(id: "error_case"),
            combinedPrompt: "error prompt",
            status: "error",
            rawText: "fail"
        )
        let okResult = makeResult(
            scenario: makeScenario(id: "ok_case"),
            combinedPrompt: "ok prompt",
            status: "ok",
            prettyJSON: "{\n  \"ok\" : true\n}"
        )
        XCTAssertEqual(
            HtmlReport.allCopyText(for: [okResult, errorResult]),
            """
            --- Scenario: error_case ---\n\nerror prompt\n\n--- Response ---\n\nfail\n\n--- Scenario: ok_case ---\n\nok prompt\n\n--- Response ---\n\n{\n  "ok" : true\n}
            """
        )
    }

    func testCopyAllButtonAndEmbeddedSource() throws {
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "first"),
                    combinedPrompt: "first prompt",
                    status: "ok",
                    prettyJSON: "{\n  \"first\" : true\n}"
                ),
                makeResult(
                    scenario: makeScenario(id: "second"),
                    combinedPrompt: "second prompt",
                    status: "error"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"copy-btn copy-all-btn\" data-default-label=\"Copy All\">Copy All</button>"))
        XCTAssertTrue(html.contains("class=\"copy-all-source\">\"--- Scenario: second ---\\n\\nsecond prompt\\n\\n--- Scenario: first ---\\n\\nfirst prompt\\n\\n--- Response ---\\n\\n{\\n  \\\"first\\\" : true\\n}\"</script>"))
        XCTAssertTrue(html.contains("document.querySelector('.copy-all-source')"))
    }

    func testResponseCopyTextPrefersPrettyJSON() throws {
        let result = makeResult(
            scenario: makeScenario(),
            combinedPrompt: "combined",
            status: "ok",
            prettyJSON: "{\n  \"pretty\" : true\n}",
            rawText: "{\"raw\":true}"
        )
        XCTAssertEqual(HtmlReport.responseCopyText(for: result), "{\n  \"pretty\" : true\n}")
    }

    func testResponseCopyTextFallsBackToRawText() throws {
        let result = makeResult(
            scenario: makeScenario(),
            combinedPrompt: "combined",
            status: "error",
            rawText: "provider error output"
        )
        XCTAssertEqual(HtmlReport.responseCopyText(for: result), "provider error output")
    }

    func testCopyButtonPresentWhenNoResponseText() throws {
        let summary = makeSummary(
            results: [
                makeResult(
                    scenario: makeScenario(id: "no_response"),
                    combinedPrompt: "combined",
                    status: "error"
                ),
            ]
        )

        let html = HtmlReport.render(summary: summary)
        XCTAssertTrue(html.contains("class=\"copy-btn\" data-default-label=\"Copy\">Copy</button>"))
        XCTAssertTrue(html.contains("class=\"copy-source\">\"--- Scenario: no_response ---\\n\\ncombined\"</script>"))
    }

    // MARK: - Helpers

    private func makeScenario(
        id: String = "scenario_id",
        label: String = "Scenario label",
        description: String = "Explains what this scenario validates.",
        subsystem: String = "conversation",
        systemPrompt: String = "System rules",
        userPrompt: String = "Hello",
        jsonSchema: String = ""
    ) -> LlmTesterScenario {
        LlmTesterScenario(
            id: id,
            label: label,
            description: description,
            subsystem: subsystem,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            responseFormat: "json_object",
            jsonSchema: jsonSchema,
            maxTokens: 128,
            temperature: 0.2
        )
    }

    private func makeResult(
        scenario: LlmTesterScenario,
        combinedPrompt: String,
        status: String,
        prettyJSON: String? = nil,
        rawText: String? = nil,
        errorMessage: String? = nil
    ) -> LlmTesterScenarioResult {
        LlmTesterScenarioResult(
            scenario: scenario,
            combinedPrompt: combinedPrompt,
            provider: "openai",
            durationMs: 42,
            status: status,
            rawText: rawText,
            prettyJSON: prettyJSON,
            jsonValid: prettyJSON != nil,
            errorMessage: errorMessage
        )
    }

    private func makeSummary(
        total: Int? = nil,
        succeeded: Int? = nil,
        failed: Int? = nil,
        results: [LlmTesterScenarioResult]
    ) -> LlmTesterRunSummary {
        let okCount = results.filter { $0.status == "ok" }.count
        let resolvedTotal = total ?? results.count
        let resolvedSucceeded = succeeded ?? okCount
        let resolvedFailed = failed ?? (resolvedTotal - resolvedSucceeded)
        return LlmTesterRunSummary(
            generatedAt: "2026-06-28T12:00:00Z",
            manifestGeneratedAt: "2026-06-28T11:59:00Z",
            providerPreference: "openai",
            total: resolvedTotal,
            succeeded: resolvedSucceeded,
            failed: resolvedFailed,
            results: results
        )
    }
}
