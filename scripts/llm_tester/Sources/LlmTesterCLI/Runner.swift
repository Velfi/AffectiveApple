import Foundation
import LlmTesterReport

enum LlmTesterRunner {
    static func loadManifest(at path: String) throws -> LlmTesterManifest {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LlmTesterManifest.self, from: data)
    }

    static func makeClient(preference: HostTextProviderPreference) throws -> HostLLMCompletionClient {
        let store = KeychainCredentialStore()
        let keys = ProviderCredentialKey.credentialKeys(for: preference)
        let credentials = ProviderCredentialKey.resolvedCredentials(using: store, keys: keys)
        return HostLLMCompletionClient(
            providerRouter: HostProviderRouter(
                credentialProvider: { credentials }
            ),
            textProviderPreference: preference
        )
    }

    static func hostTextProviderPreference(for rawValue: String) -> HostTextProviderPreference {
        switch rawValue {
        case "apple", "local":
            return .local
        default:
            return HostTextProviderPreference(rawValue: rawValue) ?? .random
        }
    }

    static func hostResponseFormat(for scenario: LlmTesterScenario) -> HostResponseFormat {
        HostResponseFormat(rawValue: scenario.responseFormat) ?? .text
    }

    static func run(
        manifest: LlmTesterManifest,
        client: HostLLMCompletionClient,
        providerPreference: HostTextProviderPreference
    ) async -> LlmTesterRunSummary {
        var results: [LlmTesterScenarioResult] = []
        results.reserveCapacity(manifest.scenarios.count)

        for scenario in manifest.scenarios {
            let responseFormat = hostResponseFormat(for: scenario)
            let combinedPrompt = HostPromptBuilder.combinedPrompt(
                for: HostLLMPromptInput(
                    systemPrompt: scenario.systemPrompt,
                    userPrompt: scenario.userPrompt,
                    responseFormat: responseFormat,
                    jsonSchema: scenario.jsonSchema
                )
            )
            let started = Date()
            do {
                let completion = try await client.complete(
                    HostLLMCompletionRequest(
                        prompt: combinedPrompt,
                        maxTokens: scenario.maxTokens,
                        responseFormat: responseFormat,
                        jsonSchema: scenario.jsonSchema
                    )
                )
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                let validation = validateJSON(text: completion.text, expectsJSON: responseFormat == .jsonObject)
                let semantic = ScenarioGrader.grade(scenarioId: scenario.id, rawText: completion.text)
                let status: String
                if responseFormat != .jsonObject {
                    status = "ok"
                } else if !validation.jsonValid {
                    status = "invalid_json"
                } else if !semantic.passed {
                    status = "semantic_fail"
                } else {
                    status = "ok"
                }
                let semanticMessage: String? = switch semantic {
                case .fail(let message):
                    message
                default:
                    nil
                }
                results.append(
                    LlmTesterScenarioResult(
                        scenario: scenario,
                        combinedPrompt: combinedPrompt,
                        provider: completion.source,
                        durationMs: durationMs,
                        status: status,
                        rawText: completion.text,
                        prettyJSON: validation.prettyJSON,
                        jsonValid: validation.jsonValid,
                        semanticPassed: semantic.passed ? true : (semantic == .notApplicable ? nil : false),
                        semanticMessage: semanticMessage,
                        errorMessage: validation.errorMessage
                    )
                )
            } catch {
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                results.append(
                    LlmTesterScenarioResult(
                        scenario: scenario,
                        combinedPrompt: combinedPrompt,
                        provider: nil,
                        durationMs: durationMs,
                        status: "error",
                        rawText: nil,
                        prettyJSON: nil,
                        jsonValid: false,
                        errorMessage: String(describing: error)
                    )
                )
            }
        }

        let succeeded = results.filter { $0.status == "ok" }.count
        return LlmTesterRunSummary(
            generatedAt: iso8601Now(),
            manifestGeneratedAt: manifest.generatedAt,
            providerPreference: providerPreference.rawValue,
            total: results.count,
            succeeded: succeeded,
            failed: results.count - succeeded,
            results: results
        )
    }

    private static func validateJSON(text: String, expectsJSON: Bool) -> (jsonValid: Bool, prettyJSON: String?, errorMessage: String?) {
        guard expectsJSON else {
            return (true, nil, nil)
        }
        guard let data = text.data(using: .utf8) else {
            return (false, nil, "Response was not valid UTF-8.")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let prettyText = String(decoding: pretty, as: UTF8.self)
            return (true, prettyText, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
