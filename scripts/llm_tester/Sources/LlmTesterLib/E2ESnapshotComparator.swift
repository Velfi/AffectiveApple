import Foundation

public enum E2ESnapshotComparator {
    public static func compare(
        current: E2ESnapshotRunSummary,
        baseline: E2ESnapshotRunSummary
    ) -> E2ESnapshotRunSummary {
        let baselineScenarios = Dictionary(uniqueKeysWithValues: baseline.scenarios.map { ($0.id, $0) })
        let scenarios = current.scenarios.map { scenario in
            compare(scenario: scenario, baseline: baselineScenarios[scenario.id])
        }
        let succeeded = scenarios.filter { $0.status == .ok }.count
        return E2ESnapshotRunSummary(
            generatedAt: current.generatedAt,
            suiteName: current.suiteName,
            baselineName: baseline.baselineName,
            total: scenarios.count,
            succeeded: succeeded,
            failed: scenarios.count - succeeded,
            scenarios: scenarios
        )
    }

    private static func compare(
        scenario: E2ESnapshotScenarioResult,
        baseline: E2ESnapshotScenarioResult?
    ) -> E2ESnapshotScenarioResult {
        guard let baseline else {
            let marker = E2ESnapshotStep(
                id: "snapshot_baseline",
                label: "Baseline scenario",
                kind: "snapshot_compare",
                status: .changed,
                summary: "Scenario is new relative to the selected baseline.",
                assertions: [
                    .init(
                        id: "scenario_exists_in_baseline",
                        label: "Scenario exists in baseline",
                        status: .changed,
                        message: "No scenario with id '\(scenario.id)' was found in the baseline."
                    ),
                ]
            )
            return scenario.replacing(steps: [marker] + scenario.steps, status: .changed)
        }

        let baselineSteps = Dictionary(uniqueKeysWithValues: baseline.steps.map { ($0.id, $0) })
        let steps = scenario.steps.map { step in
            compare(step: step, baseline: baselineSteps[step.id])
        }
        let status = worstStatus([scenario.status] + steps.map(\.status))
        return scenario.replacing(steps: steps, status: status)
    }

    private static func compare(
        step: E2ESnapshotStep,
        baseline: E2ESnapshotStep?
    ) -> E2ESnapshotStep {
        var assertions = step.assertions
        guard let baseline else {
            assertions.append(
                .init(
                    id: "step_exists_in_baseline",
                    label: "Step exists in baseline",
                    status: .changed,
                    message: "No step with id '\(step.id)' was found in the baseline."
                )
            )
            return step.replacing(assertions: assertions, status: worstStatus([step.status, .changed]))
        }

        if step.summary != baseline.summary {
            assertions.append(
                .init(
                    id: "summary_matches_baseline",
                    label: "Summary matches baseline",
                    status: .changed,
                    message: "Step summary changed.",
                    expected: baseline.summary,
                    actual: step.summary
                )
            )
        }
        if (step.detail ?? "") != (baseline.detail ?? "") {
            assertions.append(
                .init(
                    id: "detail_matches_baseline",
                    label: "Detail matches baseline",
                    status: .changed,
                    message: "Step detail changed.",
                    expected: baseline.detail,
                    actual: step.detail
                )
            )
        }

        let baselineArtifacts = Dictionary(uniqueKeysWithValues: baseline.artifacts.map { ($0.id, $0) })
        for artifact in step.artifacts {
            guard let baselineArtifact = baselineArtifacts[artifact.id] else {
                assertions.append(
                    .init(
                        id: "artifact_\(artifact.id)_exists_in_baseline",
                        label: "\(artifact.label) exists in baseline",
                        status: .changed,
                        message: "Artifact '\(artifact.id)' is new relative to the baseline.",
                        expected: nil,
                        actual: artifact.body
                    )
                )
                continue
            }
            if artifact.body != baselineArtifact.body {
                assertions.append(
                    .init(
                        id: "artifact_\(artifact.id)_matches_baseline",
                        label: "\(artifact.label) matches baseline",
                        status: .changed,
                        message: "Artifact '\(artifact.id)' changed.",
                        expected: baselineArtifact.body,
                        actual: artifact.body
                    )
                )
            }
        }

        let status = worstStatus([step.status] + assertions.map(\.status))
        return step.replacing(assertions: assertions, status: status)
    }

    private static func worstStatus(_ statuses: [E2ESnapshotStatus]) -> E2ESnapshotStatus {
        statuses.min { E2ESnapshotReport.statusSortOrder($0) < E2ESnapshotReport.statusSortOrder($1) } ?? .ok
    }
}

private extension E2ESnapshotScenarioResult {
    func replacing(steps: [E2ESnapshotStep], status: E2ESnapshotStatus) -> E2ESnapshotScenarioResult {
        E2ESnapshotScenarioResult(
            id: id,
            label: label,
            description: description,
            qualities: qualities,
            status: status,
            durationMs: durationMs,
            steps: steps,
            artifacts: artifacts
        )
    }
}

private extension E2ESnapshotStep {
    func replacing(
        assertions: [E2ESnapshotAssertion]? = nil,
        status: E2ESnapshotStatus
    ) -> E2ESnapshotStep {
        E2ESnapshotStep(
            id: id,
            label: label,
            kind: kind,
            status: status,
            summary: summary,
            detail: detail,
            assertions: assertions ?? self.assertions,
            artifacts: artifacts
        )
    }
}
