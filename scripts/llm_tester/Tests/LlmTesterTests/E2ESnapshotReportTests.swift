import XCTest
import LlmTesterReport

final class E2ESnapshotReportTests: XCTestCase {
    func testRenderIncludesFlowchartAndJumpToFirstFailure() throws {
        let summary = makeSummary(
            scenarios: [
                makeScenario(
                    id: "honest_uncertainty",
                    status: .failed,
                    steps: [
                        makeStep(id: "seed", label: "Seed uncertain memory", status: .ok),
                        makeStep(
                            id: "ask",
                            label: "Ask later",
                            status: .failed,
                            assertions: [
                                .init(
                                    id: "source_bound",
                                    label: "Separates memory from guess",
                                    status: .failed,
                                    message: "The response treated an inference as a remembered fact.",
                                    expected: "I remember X. I am guessing Y.",
                                    actual: "I remember X and Y."
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )

        let html = E2ESnapshotReport.render(summary: summary)

        XCTAssertTrue(html.contains("E2E Snapshot Report"))
        XCTAssertTrue(html.contains("href=\"#step-honest_uncertainty-ask\">Jump to first failure</a>"))
        XCTAssertTrue(html.contains("class=\"flowchart\""))
        XCTAssertTrue(html.contains("class=\"flow-node failed\" href=\"#step-honest_uncertainty-ask\""))
        XCTAssertTrue(html.contains("id=\"step-honest_uncertainty-ask\""))
        XCTAssertTrue(html.contains("The response treated an inference as a remembered fact."))
        XCTAssertTrue(html.contains("<h4>Expected</h4>"))
        XCTAssertTrue(html.contains("<h4>Actual</h4>"))
    }

    func testFailureRailLinksScenarioToFirstProblemStep() throws {
        let summary = makeSummary(
            scenarios: [
                makeScenario(id: "ok_case", status: .ok, steps: [makeStep(status: .ok)]),
                makeScenario(
                    id: "fallibility_revision",
                    status: .changed,
                    steps: [
                        makeStep(id: "initial", status: .ok),
                        makeStep(id: "correction", status: .changed),
                    ]
                ),
            ]
        )

        let html = E2ESnapshotReport.render(summary: summary)
        XCTAssertTrue(html.contains("<nav class=\"rail\" aria-label=\"Snapshot failures and scenarios\">"))
        XCTAssertTrue(html.contains("href=\"#step-fallibility_revision-correction\""))
        XCTAssertTrue(html.contains("href=\"#scenario-ok_case\""))
    }

    func testSortsProblemScenariosBeforePassingScenarios() throws {
        let ok = makeScenario(id: "z_ok", status: .ok, steps: [makeStep(status: .ok)])
        let failed = makeScenario(id: "a_failed", status: .failed, steps: [makeStep(status: .failed)])
        let error = makeScenario(id: "m_error", status: .error, steps: [makeStep(status: .error)])

        let sorted = E2ESnapshotReport.sortedScenarios([ok, failed, error]).map(\.id)

        XCTAssertEqual(sorted, ["m_error", "a_failed", "z_ok"])
    }

    func testAnchorIdsSanitizeInvalidCharacters() throws {
        XCTAssertEqual(
            E2ESnapshotReport.scenarioAnchorId(for: "relationship specificity/zelda"),
            "scenario-relationship-specificity-zelda"
        )
        XCTAssertEqual(
            E2ESnapshotReport.stepAnchorId(scenarioId: "fallibility", stepId: "corrects me"),
            "step-fallibility-corrects-me"
        )
    }

    func testSnapshotSummaryDecodesSnakeCaseJSON() throws {
        let json = """
        {
          "generated_at": "2026-07-01T12:00:00Z",
          "suite_name": "Brain Qualities",
          "baseline_name": "main",
          "total": 1,
          "succeeded": 0,
          "failed": 1,
          "scenarios": [
            {
              "id": "honest_uncertainty",
              "label": "Honest uncertainty",
              "description": "Distinguishes memory from inference.",
              "qualities": ["honest_uncertainty"],
              "status": "failed",
              "duration_ms": 42,
              "steps": [
                {
                  "id": "ask",
                  "label": "Ask later",
                  "kind": "brain_turn",
                  "status": "failed",
                  "summary": "The brain guessed too strongly.",
                  "detail": "turn detail",
                  "assertions": [
                    {
                      "id": "source_bound",
                      "label": "Source bound",
                      "status": "failed",
                      "message": "Inference was presented as memory.",
                      "expected": "guess",
                      "actual": "memory"
                    }
                  ],
                  "artifacts": [
                    {
                      "id": "events",
                      "label": "Events",
                      "kind": "json",
                      "body": "{\\"events\\":[]}",
                      "language": "json"
                    }
                  ]
                }
              ],
              "artifacts": []
            }
          ]
        }
        """

        let summary = try JSONDecoder().decode(E2ESnapshotRunSummary.self, from: Data(json.utf8))

        XCTAssertEqual(summary.suiteName, "Brain Qualities")
        XCTAssertEqual(summary.baselineName, "main")
        XCTAssertEqual(summary.scenarios.first?.durationMs, 42)
        XCTAssertEqual(summary.scenarios.first?.steps.first?.assertions.first?.actual, "memory")
    }

    func testOptionsParseSnapshotMode() throws {
        let options = try LlmTesterOptions.parse([
            "--snapshot", "/tmp/snapshot.json",
            "--baseline", "/tmp/baseline.json",
            "--output", "/tmp/report.html",
        ])

        XCTAssertNil(options.manifestPath)
        XCTAssertEqual(options.snapshotPath, "/tmp/snapshot.json")
        XCTAssertEqual(options.baselinePath, "/tmp/baseline.json")
        XCTAssertEqual(options.outputPath, "/tmp/report.html")
        XCTAssertTrue(options.runsSnapshotReport)
    }

    func testComparatorMarksChangedArtifactWithExpectedActualDiff() throws {
        let baseline = makeSummary(
            scenarios: [
                makeScenario(
                    id: "continuity",
                    status: .ok,
                    steps: [
                        E2ESnapshotStep(
                            id: "recall",
                            label: "Recall",
                            kind: "brain_turn",
                            status: .ok,
                            summary: "Remembered the right fact.",
                            artifacts: [
                                .init(id: "response", label: "Response", body: "I remember the blue room."),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let current = makeSummary(
            scenarios: [
                makeScenario(
                    id: "continuity",
                    status: .ok,
                    steps: [
                        E2ESnapshotStep(
                            id: "recall",
                            label: "Recall",
                            kind: "brain_turn",
                            status: .ok,
                            summary: "Remembered the right fact.",
                            artifacts: [
                                .init(id: "response", label: "Response", body: "I remember the green room."),
                            ]
                        ),
                    ]
                ),
            ]
        )

        let compared = E2ESnapshotComparator.compare(current: current, baseline: baseline)
        let step = try XCTUnwrap(compared.scenarios.first?.steps.first)
        let assertion = try XCTUnwrap(step.assertions.first { $0.id == "artifact_response_matches_baseline" })

        XCTAssertEqual(compared.failed, 1)
        XCTAssertEqual(compared.scenarios.first?.status, .changed)
        XCTAssertEqual(step.status, .changed)
        XCTAssertEqual(assertion.expected, "I remember the blue room.")
        XCTAssertEqual(assertion.actual, "I remember the green room.")

        let html = E2ESnapshotReport.render(summary: compared)
        XCTAssertTrue(html.contains("Artifact 'response' changed."))
        XCTAssertTrue(html.contains("I remember the blue room."))
        XCTAssertTrue(html.contains("I remember the green room."))
    }

    func testOptionsRejectBaselineWithoutSnapshot() throws {
        XCTAssertThrowsError(
            try LlmTesterOptions.parse([
                "--manifest", "/tmp/manifest.json",
                "--baseline", "/tmp/baseline.json",
            ])
        )
    }

    func testBrainQualityScenarioCatalogCoversRequestedQualities() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = packageRoot
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("brain_quality_scenarios.json")
        let data = try Data(contentsOf: fixtureURL)
        let summary = try JSONDecoder().decode(E2ESnapshotRunSummary.self, from: data)

        XCTAssertEqual(summary.scenarios.count, 9)
        XCTAssertEqual(summary.total, 9)

        let scenarioIds = Set(summary.scenarios.map(\.id))
        XCTAssertTrue(scenarioIds.contains("continuity_remembers_what_happened"))
        XCTAssertTrue(scenarioIds.contains("consequence_experience_changes_behavior"))
        XCTAssertTrue(scenarioIds.contains("slowness_deep_change_gradual"))
        XCTAssertTrue(scenarioIds.contains("fallibility_misremember_infer_revise"))
        XCTAssertTrue(scenarioIds.contains("boundaries_not_only_to_please"))
        XCTAssertTrue(scenarioIds.contains("non_social_interests_cares_besides_user"))
        XCTAssertTrue(scenarioIds.contains("relationship_specificity_different_people"))
        XCTAssertTrue(scenarioIds.contains("self_consistency_actions_reflect_state"))
        XCTAssertTrue(scenarioIds.contains("honest_uncertainty_memory_vs_guess"))

        for scenario in summary.scenarios {
            XCTAssertFalse(scenario.steps.isEmpty, "\(scenario.id) should define a flow.")
            XCTAssertFalse(scenario.qualities.isEmpty, "\(scenario.id) should name the quality it demonstrates.")
        }
    }

    func testBrainQualityLiveSampleRendersFlowchartFailure() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = packageRoot
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("brain_quality_live_sample.json")
        let data = try Data(contentsOf: fixtureURL)
        let summary = try JSONDecoder().decode(E2ESnapshotRunSummary.self, from: data)

        let html = E2ESnapshotReport.render(summary: summary)

        XCTAssertEqual(summary.suiteName, "Brain Quality Live E2E")
        XCTAssertTrue(html.contains("href=\"#step-continuity_remembers_what_happened-continuity_evidence\">Jump to first failure</a>"))
        XCTAssertTrue(html.contains("class=\"flow-node failed\" href=\"#step-continuity_remembers_what_happened-continuity_evidence\""))
        XCTAssertTrue(html.contains("North Star continuity evidence"))
    }

    func testSnapshotReportIncludesCopyButtonsAndSources() throws {
        let summary = makeSummary(
            scenarios: [
                makeScenario(
                    id: "copy_snapshot",
                    status: .failed,
                    steps: [
                        makeStep(
                            id: "assert",
                            label: "Assert",
                            status: .failed,
                            assertions: [
                                .init(
                                    id: "diff",
                                    label: "Diff",
                                    status: .failed,
                                    message: "Mismatch.",
                                    expected: "expected text",
                                    actual: "actual text"
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )

        let html = E2ESnapshotReport.render(summary: summary)

        XCTAssertTrue(html.contains("class=\"copy-btn copy-all-btn\" data-default-label=\"Copy All\">Copy All</button>"))
        XCTAssertTrue(html.contains("class=\"copy-btn\" data-default-label=\"Copy\">Copy</button>"))
        XCTAssertTrue(html.contains("class=\"copy-btn copy-local-btn\" data-default-label=\"Copy\">Copy</button>"))
        XCTAssertTrue(html.contains("class=\"copy-all-source\">\"--- Scenario: copy_snapshot"))
        XCTAssertTrue(html.contains("navigator.clipboard.writeText(text)"))
        XCTAssertTrue(html.contains("document.querySelector('.copy-all-source')"))
    }

    func testSnapshotScenarioCopyTextIncludesStepsAssertionsAndArtifacts() throws {
        let scenario = makeScenario(
            id: "copy_payload",
            status: .failed,
            steps: [
                makeStep(
                    id: "check",
                    label: "Check",
                    status: .failed,
                    assertions: [
                        .init(
                            id: "assertion",
                            label: "Assertion",
                            status: .failed,
                            message: "The gate failed.",
                            expected: "expected",
                            actual: "actual"
                        ),
                    ]
                ),
            ]
        )

        let text = E2ESnapshotReport.scenarioCopyText(for: scenario)

        XCTAssertTrue(text.contains("--- Scenario: copy_payload ---"))
        XCTAssertTrue(text.contains("--- Step: check ---"))
        XCTAssertTrue(text.contains("Assertion: Assertion [failed]"))
        XCTAssertTrue(text.contains("Expected:\nexpected"))
        XCTAssertTrue(text.contains("Artifact: Event envelope (json)"))
    }

    private func makeSummary(
        scenarios: [E2ESnapshotScenarioResult]
    ) -> E2ESnapshotRunSummary {
        let succeeded = scenarios.filter { $0.status == .ok }.count
        return E2ESnapshotRunSummary(
            generatedAt: "2026-07-01T12:00:00Z",
            suiteName: "Brain Qualities",
            baselineName: "main",
            total: scenarios.count,
            succeeded: succeeded,
            failed: scenarios.count - succeeded,
            scenarios: scenarios
        )
    }

    private func makeScenario(
        id: String,
        status: E2ESnapshotStatus,
        steps: [E2ESnapshotStep]
    ) -> E2ESnapshotScenarioResult {
        E2ESnapshotScenarioResult(
            id: id,
            label: id.replacingOccurrences(of: "_", with: " "),
            description: "Demonstrates a brain quality end to end.",
            qualities: ["honest_uncertainty", "fallibility"],
            status: status,
            durationMs: 123,
            steps: steps,
            artifacts: [
                .init(id: "snapshot", label: "Stored snapshot", body: "{\"ok\":true}", language: "json"),
            ]
        )
    }

    private func makeStep(
        id: String = "step",
        label: String = "Step",
        status: E2ESnapshotStatus,
        assertions: [E2ESnapshotAssertion] = []
    ) -> E2ESnapshotStep {
        E2ESnapshotStep(
            id: id,
            label: label,
            kind: "brain_turn",
            status: status,
            summary: "A step in the scenario.",
            detail: "request -> response -> read-model",
            assertions: assertions,
            artifacts: [
                .init(id: "events", label: "Event envelope", body: "{\"events\":[]}", language: "json"),
            ]
        )
    }
}
