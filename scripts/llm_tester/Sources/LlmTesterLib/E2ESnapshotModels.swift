import Foundation

public enum E2ESnapshotStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case ok
    case changed
    case failed
    case error
    case skipped

    public var isSuccessful: Bool {
        switch self {
        case .ok:
            return true
        case .changed, .failed, .error, .skipped:
            return false
        }
    }
}

public struct E2ESnapshotAssertion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let status: E2ESnapshotStatus
    public let message: String
    public let expected: String?
    public let actual: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case status
        case message
        case expected
        case actual
    }

    public init(
        id: String,
        label: String,
        status: E2ESnapshotStatus,
        message: String,
        expected: String? = nil,
        actual: String? = nil
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.message = message
        self.expected = expected
        self.actual = actual
    }
}

public struct E2ESnapshotArtifact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String
    public let body: String
    public let language: String

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case kind
        case body
        case language
    }

    public init(
        id: String,
        label: String,
        kind: String = "text",
        body: String,
        language: String = "plaintext"
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.body = body
        self.language = language
    }
}

public struct E2ESnapshotStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let kind: String
    public let status: E2ESnapshotStatus
    public let summary: String
    public let detail: String?
    public let assertions: [E2ESnapshotAssertion]
    public let artifacts: [E2ESnapshotArtifact]

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case kind
        case status
        case summary
        case detail
        case assertions
        case artifacts
    }

    public init(
        id: String,
        label: String,
        kind: String,
        status: E2ESnapshotStatus,
        summary: String,
        detail: String? = nil,
        assertions: [E2ESnapshotAssertion] = [],
        artifacts: [E2ESnapshotArtifact] = []
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.status = status
        self.summary = summary
        self.detail = detail
        self.assertions = assertions
        self.artifacts = artifacts
    }
}

public struct E2ESnapshotScenarioResult: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String
    public let qualities: [String]
    public let status: E2ESnapshotStatus
    public let durationMs: Int
    public let steps: [E2ESnapshotStep]
    public let artifacts: [E2ESnapshotArtifact]

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case description
        case qualities
        case status
        case durationMs = "duration_ms"
        case steps
        case artifacts
    }

    public init(
        id: String,
        label: String,
        description: String,
        qualities: [String],
        status: E2ESnapshotStatus,
        durationMs: Int,
        steps: [E2ESnapshotStep],
        artifacts: [E2ESnapshotArtifact] = []
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.qualities = qualities
        self.status = status
        self.durationMs = durationMs
        self.steps = steps
        self.artifacts = artifacts
    }

    public var firstProblemStep: E2ESnapshotStep? {
        steps.first { !$0.status.isSuccessful }
    }
}

public struct E2ESnapshotRunSummary: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let suiteName: String
    public let baselineName: String
    public let total: Int
    public let succeeded: Int
    public let failed: Int
    public let scenarios: [E2ESnapshotScenarioResult]

    private enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case suiteName = "suite_name"
        case baselineName = "baseline_name"
        case total
        case succeeded
        case failed
        case scenarios
    }

    public init(
        generatedAt: String,
        suiteName: String,
        baselineName: String,
        total: Int,
        succeeded: Int,
        failed: Int,
        scenarios: [E2ESnapshotScenarioResult]
    ) {
        self.generatedAt = generatedAt
        self.suiteName = suiteName
        self.baselineName = baselineName
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.scenarios = scenarios
    }
}
