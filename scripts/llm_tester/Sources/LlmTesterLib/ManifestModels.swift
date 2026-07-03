import Foundation

public struct LlmTesterManifest: Decodable {
    public let generatedAt: String
    public let scenarios: [LlmTesterScenario]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case scenarios
    }
}

public struct LlmTesterScenario: Decodable, Identifiable {
    public let id: String
    public let label: String
    public let description: String
    public let subsystem: String
    public let systemPrompt: String
    public let userPrompt: String
    public let responseFormat: String
    public let jsonSchema: String
    public let maxTokens: Int
    public let temperature: Double

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case description
        case subsystem
        case systemPrompt = "system_prompt"
        case userPrompt = "user_prompt"
        case responseFormat = "response_format"
        case jsonSchema = "json_schema"
        case maxTokens = "max_tokens"
        case temperature
    }

    public init(
        id: String,
        label: String,
        description: String,
        subsystem: String,
        systemPrompt: String,
        userPrompt: String,
        responseFormat: String,
        jsonSchema: String,
        maxTokens: Int,
        temperature: Double
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.subsystem = subsystem
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.responseFormat = responseFormat
        self.jsonSchema = jsonSchema
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct LlmTesterScenarioResult {
    public let scenario: LlmTesterScenario
    public let combinedPrompt: String
    public let provider: String?
    public let durationMs: Int
    public let status: String
    public let rawText: String?
    public let prettyJSON: String?
    public let jsonValid: Bool
    public let semanticPassed: Bool?
    public let semanticMessage: String?
    public let errorMessage: String?
    public let imageDataURL: String?

    public init(
        scenario: LlmTesterScenario,
        combinedPrompt: String,
        provider: String?,
        durationMs: Int,
        status: String,
        rawText: String?,
        prettyJSON: String?,
        jsonValid: Bool,
        semanticPassed: Bool? = nil,
        semanticMessage: String? = nil,
        errorMessage: String? = nil,
        imageDataURL: String? = nil
    ) {
        self.scenario = scenario
        self.combinedPrompt = combinedPrompt
        self.provider = provider
        self.durationMs = durationMs
        self.status = status
        self.rawText = rawText
        self.prettyJSON = prettyJSON
        self.jsonValid = jsonValid
        self.semanticPassed = semanticPassed
        self.semanticMessage = semanticMessage
        self.errorMessage = errorMessage
        self.imageDataURL = imageDataURL
    }
}

public struct LlmTesterRunSummary {
    public let generatedAt: String
    public let manifestGeneratedAt: String
    public let providerPreference: String
    public let total: Int
    public let succeeded: Int
    public let failed: Int
    public let results: [LlmTesterScenarioResult]

    public init(
        generatedAt: String,
        manifestGeneratedAt: String,
        providerPreference: String,
        total: Int,
        succeeded: Int,
        failed: Int,
        results: [LlmTesterScenarioResult]
    ) {
        self.generatedAt = generatedAt
        self.manifestGeneratedAt = manifestGeneratedAt
        self.providerPreference = providerPreference
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.results = results
    }
}

public enum LlmTesterError: Error, CustomStringConvertible {
    case missingManifest
    case invalidArguments(String)

    public var description: String {
        switch self {
        case .missingManifest:
            return "Missing required --manifest PATH."
        case .invalidArguments(let message):
            return message
        }
    }
}

public enum LlmTesterOptions {
    public struct Parsed {
        public let manifestPath: String?
        public let snapshotPath: String?
        public let baselinePath: String?
        public let outputPath: String
        public let provider: String

        public var runsSnapshotReport: Bool { snapshotPath != nil }
    }

    public static func parse(_ arguments: [String]) throws -> Parsed {
        var manifestPath: String?
        var snapshotPath: String?
        var baselinePath: String?
        var outputPath = defaultOutputPath()
        var provider = "random"

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--manifest":
                index += 1
                guard index < arguments.count else {
                    throw LlmTesterError.invalidArguments("Missing value for --manifest.")
                }
                manifestPath = arguments[index]
            case "--snapshot":
                index += 1
                guard index < arguments.count else {
                    throw LlmTesterError.invalidArguments("Missing value for --snapshot.")
                }
                snapshotPath = arguments[index]
            case "--baseline":
                index += 1
                guard index < arguments.count else {
                    throw LlmTesterError.invalidArguments("Missing value for --baseline.")
                }
                baselinePath = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw LlmTesterError.invalidArguments("Missing value for --output.")
                }
                outputPath = arguments[index]
            case "--provider":
                index += 1
                guard index < arguments.count else {
                    throw LlmTesterError.invalidArguments("Missing value for --provider.")
                }
                guard parseProviderPreference(arguments[index]) != nil else {
                    throw LlmTesterError.invalidArguments("Unknown provider '\(arguments[index])'.")
                }
                provider = arguments[index]
            case "--help", "-h":
                printUsage()
                throw LlmTesterError.invalidArguments("Help requested.")
            default:
                throw LlmTesterError.invalidArguments("Unknown argument '\(argument)'.")
            }
            index += 1
        }

        if manifestPath != nil, snapshotPath != nil {
            throw LlmTesterError.invalidArguments("Use either --manifest or --snapshot, not both.")
        }
        if baselinePath != nil, snapshotPath == nil {
            throw LlmTesterError.invalidArguments("--baseline can only be used with --snapshot.")
        }
        guard manifestPath != nil || snapshotPath != nil else {
            throw LlmTesterError.missingManifest
        }
        return Parsed(
            manifestPath: manifestPath,
            snapshotPath: snapshotPath,
            baselinePath: baselinePath,
            outputPath: outputPath,
            provider: provider
        )
    }

    public static func defaultOutputPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return FileManager.default.currentDirectoryPath + "/llm_tester_report-\(stamp).html"
    }

    public static func printUsage() {
        print(
            """
            Usage:
              LlmTester --manifest PATH [--output PATH] [--provider openai|anthropic|google|local|random]
              LlmTester --snapshot PATH [--baseline PATH] [--output PATH]

            Runs live host LLM completions for every scenario in the manifest and writes an HTML report.
            Renders structured E2E snapshot JSON as a flow report when --snapshot is used.
            """
        )
    }

    public static func parseProviderPreference(_ rawValue: String) -> String? {
        switch rawValue {
        case "apple":
            return "local"
        case "openai", "anthropic", "google", "local", "random", "deepseek":
            return rawValue
        default:
            return nil
        }
    }
}
