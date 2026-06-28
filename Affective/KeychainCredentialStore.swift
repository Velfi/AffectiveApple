//
//  KeychainCredentialStore.swift
//  Affective
//
//  Created by OpenAI on 6/24/26.
//

import Foundation
import Security

nonisolated enum ProviderCredentialKey: String, CaseIterable {
    case openAI = "openai_api_key"
    case anthropic = "anthropic_api_key"
    case google = "google_api_key"
    case deepseek = "deepseek_api_key"

    var account: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        case .deepseek: "DeepSeek"
        }
    }

    var sourceName: String {
        switch self {
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .google: "google"
        case .deepseek: "deepseek"
        }
    }

    var fieldLabel: String {
        "\(displayName) API key"
    }

    var creationURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .google: URL(string: "https://aistudio.google.com/app/apikey")!
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }

    static func provider(for url: URL?) -> ProviderCredentialKey? {
        switch url?.host?.lowercased() {
        case "api.openai.com":
            return .openAI
        case "api.anthropic.com":
            return .anthropic
        case "generativelanguage.googleapis.com":
            return .google
        case "api.deepseek.com":
            return .deepseek
        default:
            return nil
        }
    }

    static var supportedDisplayNames: String {
        allCases.map(\.displayName).joined(separator: ", ")
    }

    static func environmentCredentialValues() -> [ProviderCredentialKey: String] {
        let environment = ProcessInfo.processInfo.environment
        func trimmedValue(_ key: String) -> String? {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }

        var credentials: [ProviderCredentialKey: String] = [:]
        if let value = trimmedValue("OPENAI_API_KEY") {
            credentials[.openAI] = value
        }
        if let value = trimmedValue("ANTHROPIC_API_KEY") {
            credentials[.anthropic] = value
        }
        if let value = trimmedValue("GEMINI_API_KEY")
            ?? trimmedValue("GOOGLE_API_KEY")
            ?? trimmedValue("GOOGLE_AI_API_KEY") {
            credentials[.google] = value
        }
        if let value = trimmedValue("DEEPSEEK_API_KEY") {
            credentials[.deepseek] = value
        }
        return credentials
    }

    static func resolvedCredentials(using store: KeychainCredentialStore) -> [ProviderCredentialKey: String] {
        var credentials = allCases.reduce(into: [ProviderCredentialKey: String]()) { values, key in
            guard
                let value = try? store.credential(for: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else {
                return
            }
            values[key] = value
        }
        for (key, value) in environmentCredentialValues() where credentials[key] == nil {
            credentials[key] = value
        }
        return credentials
    }
}

nonisolated struct HostProviderRouter {
    typealias CredentialProvider = () throws -> [ProviderCredentialKey: String]
    typealias ProviderPicker = ([ProviderCredentialKey]) -> ProviderCredentialKey?

    let credentialProvider: CredentialProvider
    let providerPicker: ProviderPicker

    init(
        credentialProvider: @escaping CredentialProvider,
        providerPicker: @escaping ProviderPicker = { $0.randomElement() }
    ) {
        self.credentialProvider = credentialProvider
        self.providerPicker = providerPicker
    }

    func configuredCredentials() throws -> [ProviderCredentialKey: String] {
        try credentialProvider().reduce(into: [:]) { credentials, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            credentials[entry.key] = value
        }
    }

    func configuredProviders() throws -> [ProviderCredentialKey] {
        let credentials = try configuredCredentials()
        return ProviderCredentialKey.allCases.filter { credentials[$0] != nil }
    }

    func selectedProviderCredential() throws -> (provider: ProviderCredentialKey, credential: String)? {
        let credentials = try configuredCredentials()
        let providers = ProviderCredentialKey.allCases.filter { credentials[$0] != nil }
        guard let provider = providerPicker(providers), let credential = credentials[provider] else {
            return nil
        }
        return (provider, credential)
    }

    func authorizeProviderRequest(_ request: inout URLRequest) throws {
        guard let provider = ProviderCredentialKey.provider(for: request.url) else {
            return
        }
        let credentials = try configuredCredentials()
        guard let credential = credentials[provider] else {
            throw HostProviderRoutingError.missingProviderCredential(provider.displayName)
        }
        switch provider {
        case .openAI, .deepseek:
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(credential, forHTTPHeaderField: "x-api-key")
        case .google:
            guard
                let url = request.url,
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                throw HostProviderRoutingError.invalidURL(request.url?.absoluteString ?? "")
            }
            var items = components.queryItems ?? []
            if let index = items.firstIndex(where: { $0.name == "key" }) {
                items[index] = URLQueryItem(name: "key", value: credential)
            } else {
                items.append(URLQueryItem(name: "key", value: credential))
            }
            components.queryItems = items
            guard let authorizedURL = components.url else {
                throw HostProviderRoutingError.invalidURL(url.absoluteString)
            }
            request.url = authorizedURL
        }
    }
}

nonisolated enum HostLLMCompletionProvider: Equatable {
    case appleFoundationModels
    case credential(ProviderCredentialKey)

    var displayName: String {
        switch self {
        case .appleFoundationModels:
            return "Apple Foundation Models"
        case .credential(let provider):
            return provider.displayName
        }
    }

    var sourceName: String {
        switch self {
        case .appleFoundationModels:
            return "apple_foundation_models"
        case .credential(let provider):
            return provider.sourceName
        }
    }
}

nonisolated enum HostTextProviderPreference: String, CaseIterable, Equatable {
    case random
    case local
    case openAI = "openai"
    case anthropic
    case google
    case deepseek

    var displayName: String {
        switch self {
        case .random:
            return "Random"
        case .local:
            return "Local"
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .google:
            return "Google"
        case .deepseek:
            return "DeepSeek"
        }
    }

    var credentialProvider: ProviderCredentialKey? {
        switch self {
        case .random, .local:
            return nil
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .google:
            return .google
        case .deepseek:
            return .deepseek
        }
    }
}

nonisolated enum HostProviderRoutingError: Error, CustomStringConvertible {
    case invalidURL(String)
    case missingProviderCredential(String)

    var description: String {
        switch self {
        case .invalidURL(let url): return "invalid provider URL: \(url)"
        case .missingProviderCredential(let provider): return "missing host-managed \(provider) credential"
        }
    }
}

nonisolated struct HostLLMCompletionRequest {
    var prompt: String
    var maxTokens: Int
    var responseFormat: HostResponseFormat = .text
    var jsonSchema: String = "{}"
}

nonisolated struct HostLLMCompletionResponse: Equatable {
    var text: String
    var provider: HostLLMCompletionProvider

    var source: String {
        provider.sourceName
    }
}

nonisolated struct HostLLMCompletionClient {
    typealias JSONLoader = @Sendable (URLRequest) async throws -> [String: Any]
    typealias RoutePicker = ([HostLLMCompletionProvider]) -> HostLLMCompletionProvider?

    let providerRouter: HostProviderRouter
    let appleFoundationModelsClient: AppleFoundationModelsTextClient
    let textProviderPreference: HostTextProviderPreference
    let routePicker: RoutePicker
    let session: URLSession
    let jsonLoader: JSONLoader?

    init(
        providerRouter: HostProviderRouter,
        appleFoundationModelsClient: AppleFoundationModelsTextClient = AppleFoundationModelsTextClient(),
        textProviderPreference: HostTextProviderPreference = .random,
        routePicker: @escaping RoutePicker = { $0.randomElement() },
        session: URLSession = .shared,
        jsonLoader: JSONLoader? = nil
    ) {
        self.providerRouter = providerRouter
        self.appleFoundationModelsClient = appleFoundationModelsClient
        self.textProviderPreference = textProviderPreference
        self.routePicker = routePicker
        self.session = session
        self.jsonLoader = jsonLoader
    }

    func complete(_ completionRequest: HostLLMCompletionRequest) async throws -> HostLLMCompletionResponse {
        let routes = try orderedRoutes()
        guard !routes.isEmpty else {
            throw HostLLMCompletionError.unavailableProvider(textProviderPreference.rawValue)
        }

        var failures: [String] = []
        for route in routes {
            do {
                return try await complete(route, completionRequest)
            } catch {
                failures.append("\(route.displayName): \(String(describing: error))")
            }
        }
        throw HostLLMCompletionError.allRoutesFailed(failures)
    }

    private func complete(
        _ route: HostLLMCompletionProvider,
        _ completionRequest: HostLLMCompletionRequest
    ) async throws -> HostLLMCompletionResponse {
        switch route {
        case .appleFoundationModels:
            let text = try await appleFoundationModelsClient.complete(
                Self.appleRequest(from: completionRequest)
            )
            return HostLLMCompletionResponse(
                text: try responseText(
                    text,
                    responseFormat: completionRequest.responseFormat
                ),
                provider: .appleFoundationModels
            )
        case .credential(let provider):
            var providerRequest = try request(
                for: provider,
                completionRequest: completionRequest
            )
            try providerRouter.authorizeProviderRequest(&providerRequest)
            let object = try await jsonObject(for: providerRequest, provider: provider)
            return HostLLMCompletionResponse(
                text: try responseText(
                    from: object,
                    provider: provider,
                    responseFormat: completionRequest.responseFormat
                ),
                provider: .credential(provider)
            )
        }
    }

    func availableRoutes() throws -> [HostLLMCompletionProvider] {
        var routes: [HostLLMCompletionProvider] = []
        if appleFoundationModelsClient.availability.isAvailable {
            routes.append(.appleFoundationModels)
        }
        routes.append(contentsOf: try providerRouter.configuredProviders().map { .credential($0) })
        return routes
    }

    private func orderedRoutes() throws -> [HostLLMCompletionProvider] {
        let routes = try availableRoutes()
        guard !routes.isEmpty else { return [] }
        switch textProviderPreference {
        case .random:
            guard let first = routePicker(routes) else { return routes }
            var ordered = [first]
            ordered.append(contentsOf: routes.filter { $0 != first })
            return ordered
        case .local:
            return routes.filter { $0 == .appleFoundationModels }
        case .openAI, .anthropic, .google, .deepseek:
            guard let selected = try selectedRoute() else { return [] }
            return [selected]
        }
    }

    private func selectedRoute() throws -> HostLLMCompletionProvider? {
        let routes = try availableRoutes()
        switch textProviderPreference {
        case .random:
            return routePicker(routes)
        case .local:
            return routes.first { $0 == .appleFoundationModels }
        case .openAI, .anthropic, .google, .deepseek:
            return textProviderPreference.credentialProvider.flatMap { provider in
                routes.first { $0 == .credential(provider) }
            }
        }
    }

    private static func appleRequest(from request: HostLLMCompletionRequest) -> AppleFoundationModelsTextRequest {
        let components = splitPrompt(request.prompt)
        return AppleFoundationModelsTextRequest(
            instructions: components.instructions,
            prompt: components.prompt,
            maxTokens: request.maxTokens,
            temperature: 0.2
        )
    }

    private static func splitPrompt(_ prompt: String) -> (instructions: String, prompt: String) {
        let marker = "\n\nUser:\n"
        guard
            prompt.hasPrefix("System:\n"),
            let range = prompt.range(of: marker)
        else {
            return (
                "You are a concise, helpful assistant. Answer directly in plain language.",
                prompt
            )
        }

        let systemStart = prompt.index(prompt.startIndex, offsetBy: "System:\n".count)
        let instructions = String(prompt[systemStart..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = String(prompt[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            instructions.isEmpty ? "You are a concise, helpful assistant." : instructions,
            userPrompt.isEmpty ? prompt : userPrompt
        )
    }

    private func request(
        for provider: ProviderCredentialKey,
        completionRequest: HostLLMCompletionRequest
    ) throws -> URLRequest {
        switch provider {
        case .openAI:
            var body: [String: Any] = [
                "model": "gpt-4.1-nano",
                "input": completionRequest.prompt,
                "max_output_tokens": completionRequest.maxTokens,
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["text"] = [
                    "format": try openAIResponsesTextFormat(
                        name: "text_completion",
                        schema: completionRequest.jsonSchema
                    )
                ]
            }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.setValue("Bearer host-managed:\(ProviderCredentialKey.openAI.rawValue)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        case .anthropic:
            var body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": completionRequest.maxTokens,
                "messages": [
                    ["role": "user", "content": completionRequest.prompt]
                ],
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["tools"] = [
                    [
                        "name": "json_response",
                        "description": "Return exactly the requested JSON object.",
                        "input_schema": try jsonObject(from: completionRequest.jsonSchema),
                    ]
                ]
                body["tool_choice"] = ["type": "tool", "name": "json_response"]
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("host-managed:\(ProviderCredentialKey.anthropic.rawValue)", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        case .google:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")!
            components.queryItems = [URLQueryItem(name: "key", value: "host-managed:\(ProviderCredentialKey.google.rawValue)")]
            var generationConfig: [String: Any] = [
                "maxOutputTokens": completionRequest.maxTokens,
            ]
            if completionRequest.responseFormat == .jsonObject {
                generationConfig["responseMimeType"] = "application/json"
                generationConfig["responseSchema"] = try jsonObject(from: completionRequest.jsonSchema)
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            ["text": completionRequest.prompt]
                        ],
                    ]
                ],
                "generationConfig": generationConfig,
            ])
            return request
        case .deepseek:
            var body: [String: Any] = [
                "model": "deepseek-chat",
                "max_tokens": completionRequest.maxTokens,
                "messages": [
                    ["role": "user", "content": completionRequest.prompt]
                ],
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["response_format"] = ["type": "json_object"]
            }
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer host-managed:\(ProviderCredentialKey.deepseek.rawValue)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 25
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private func jsonObject(for request: URLRequest, provider: ProviderCredentialKey) async throws -> [String: Any] {
        if let jsonLoader {
            return try await jsonLoader(request)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HostLLMCompletionError.invalidProviderResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw HostLLMCompletionError.providerRejected(
                provider: provider.displayName,
                status: httpResponse.statusCode,
                body: Self.providerErrorBody(from: data)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostLLMCompletionError.invalidProviderResponse
        }
        return object
    }

    private func responseText(
        from object: [String: Any],
        provider: ProviderCredentialKey,
        responseFormat: HostResponseFormat
    ) throws -> String {
        let text: String?
        switch provider {
        case .openAI:
            text = openAIText(from: object)
        case .deepseek:
            text = openAIChatCompletionsText(from: object)
        case .anthropic:
            text = anthropicText(from: object, responseFormat: responseFormat)
        case .google:
            text = googleText(from: object)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostLLMCompletionError.invalidProviderResponse
        }
        return try responseText(text, responseFormat: responseFormat)
    }

    private func responseText(_ text: String, responseFormat: HostResponseFormat) throws -> String {
        switch responseFormat {
        case .text:
            return cleanText(text)
        case .jsonObject:
            return try normalizedJSONObjectText(text)
        }
    }

    private func openAIChatCompletionsText(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]] else { return nil }
        for choice in choices {
            guard let message = choice["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? String {
                return content
            }
        }
        return nil
    }

    private func openAIText(from object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String {
            return text
        }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }

    private func anthropicText(from object: [String: Any], responseFormat: HostResponseFormat) -> String? {
        guard let content = object["content"] as? [[String: Any]] else { return nil }
        for part in content {
            switch responseFormat {
            case .text:
                if let text = part["text"] as? String {
                    return text
                }
            case .jsonObject:
                guard
                    part["type"] as? String == "tool_use",
                    part["name"] as? String == "json_response",
                    let input = part["input"]
                else { continue }
                return serializedJSONObjectText(input)
            }
        }
        return nil
    }

    private func googleText(from object: [String: Any]) -> String? {
        guard let candidates = object["candidates"] as? [[String: Any]] else { return nil }
        for candidate in candidates {
            guard
                let content = candidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else { continue }
            for part in parts {
                if let text = part["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }

    private func cleanText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func normalizedJSONObjectText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = markdownFenceBody(from: trimmed) ?? trimmed
        guard
            let data = candidate.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let serialized = serializedJSONObjectText(object)
        else {
            throw HostLLMCompletionError.invalidProviderResponse
        }
        return serialized
    }

    private func serializedJSONObjectText(_ object: Any) -> String? {
        guard
            let dictionary = object as? [String: Any],
            JSONSerialization.isValidJSONObject(dictionary),
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private func markdownFenceBody(from text: String) -> String? {
        guard text.hasPrefix("```") else {
            return nil
        }
        if !text.contains("\n") {
            guard text.count >= 6, text.hasSuffix("```") else {
                return nil
            }
            let bodyStart = text.index(text.startIndex, offsetBy: 3)
            let bodyEnd = text.index(text.endIndex, offsetBy: -3)
            let bodyWithOptionalLanguage = String(text[bodyStart..<bodyEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if bodyWithOptionalLanguage.hasPrefix("{") {
                return bodyWithOptionalLanguage
            }
            guard let separator = bodyWithOptionalLanguage.firstIndex(where: { $0.isWhitespace }) else {
                return nil
            }
            return String(bodyWithOptionalLanguage[separator...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = text.components(separatedBy: .newlines)
        guard
            let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            first.hasPrefix("```")
        else {
            return nil
        }
        lines.removeFirst()
        if let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
           last == "```" {
            lines.removeLast()
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func openAIResponsesTextFormat(name: String, schema: String) throws -> [String: Any] {
        [
            "type": "json_schema",
            "name": name,
            "strict": true,
            "schema": try jsonObject(from: schema),
        ]
    }

    private func openAIJSONResponseFormat(name: String, schema: String) throws -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": name,
                "strict": true,
                "schema": try jsonObject(from: schema),
            ],
        ]
    }

    private func jsonObject(from text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private static func providerErrorBody(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "empty response body" }
        let redacted = text
            .replacingOccurrences(
                of: #"sk-[A-Za-z0-9_\-]{12,}"#,
                with: "sk-REDACTED",
                options: .regularExpression
            )
        if redacted.count <= 1_000 { return redacted }
        return "\(redacted.prefix(1_000))..."
    }
}

nonisolated enum HostLLMCompletionError: Error, CustomStringConvertible {
    case missingProviderCredential
    case unavailableProvider(String)
    case providerRejected(provider: String, status: Int, body: String)
    case invalidProviderResponse
    case allRoutesFailed([String])

    var description: String {
        switch self {
        case .missingProviderCredential:
            return "missing host-managed provider credential"
        case .unavailableProvider(let provider):
            return "no configured text route is available for \(provider)"
        case .providerRejected(let provider, let status, let body):
            return "\(provider) rejected the completion request with HTTP \(status): \(body)"
        case .invalidProviderResponse:
            return "provider returned an invalid completion response"
        case .allRoutesFailed(let failures):
            return "all configured text routes failed: \(failures.joined(separator: "; "))"
        }
    }
}

nonisolated enum HostResponseFormat: String {
    case text
    case jsonObject = "json_object"
}

nonisolated struct HostVisionCompletionRequest {
    var prompt: String
    var imagePaths: [String]
    var responseFormat: HostResponseFormat
    var maxTokens: Int
    var temperature: Double
    var jsonSchema: String
}

nonisolated struct HostVisionCompletionResponse: Equatable {
    var text: String
    var provider: ProviderCredentialKey
}

nonisolated struct HostVisionCompletionClient {
    typealias JSONLoader = HostLLMCompletionClient.JSONLoader

    let providerRouter: HostProviderRouter
    let session: URLSession
    let jsonLoader: JSONLoader?

    init(
        providerRouter: HostProviderRouter,
        session: URLSession = .shared,
        jsonLoader: JSONLoader? = nil
    ) {
        self.providerRouter = providerRouter
        self.session = session
        self.jsonLoader = jsonLoader
    }

    func complete(_ completionRequest: HostVisionCompletionRequest) async throws -> HostVisionCompletionResponse {
        guard let selection = try providerRouter.selectedProviderCredential() else {
            throw HostVisionCompletionError.missingProviderCredential
        }
        var providerRequest = try request(
            for: selection.provider,
            completionRequest: completionRequest
        )
        try providerRouter.authorizeProviderRequest(&providerRequest)
        let object = try await jsonObject(for: providerRequest)
        return HostVisionCompletionResponse(
            text: try responseText(
                from: object,
                provider: selection.provider,
                responseFormat: completionRequest.responseFormat
            ),
            provider: selection.provider
        )
    }

    private func request(
        for provider: ProviderCredentialKey,
        completionRequest: HostVisionCompletionRequest
    ) throws -> URLRequest {
        switch provider {
        case .openAI:
            var content: [[String: Any]] = [
                ["type": "text", "text": completionRequest.prompt]
            ]
            for path in completionRequest.imagePaths {
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": try dataURL(for: path)
                    ],
                ])
            }
            var body: [String: Any] = [
                "model": "gpt-4.1-mini",
                "temperature": completionRequest.temperature,
                "messages": [
                    [
                        "role": "user",
                        "content": content,
                    ]
                ],
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["response_format"] = try openAIJSONResponseFormat(
                    name: "vision_description",
                    schema: completionRequest.jsonSchema
                )
            }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer host-managed:\(ProviderCredentialKey.openAI.rawValue)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        case .anthropic:
            var content: [[String: Any]] = [
                ["type": "text", "text": completionRequest.prompt]
            ]
            for path in completionRequest.imagePaths {
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": try mimeType(for: path),
                        "data": try imageBase64(for: path),
                    ],
                ])
            }
            var body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": completionRequest.maxTokens,
                "temperature": completionRequest.temperature,
                "messages": [
                    [
                        "role": "user",
                        "content": content,
                    ]
                ],
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["tools"] = [
                    [
                        "name": "json_response",
                        "description": "Return exactly the requested JSON object.",
                        "input_schema": try jsonObject(from: completionRequest.jsonSchema),
                    ]
                ]
                body["tool_choice"] = ["type": "tool", "name": "json_response"]
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("host-managed:\(ProviderCredentialKey.anthropic.rawValue)", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        case .google:
            var parts: [[String: Any]] = [
                ["text": completionRequest.prompt]
            ]
            for path in completionRequest.imagePaths {
                parts.append([
                    "inlineData": [
                        "mimeType": try mimeType(for: path),
                        "data": try imageBase64(for: path),
                    ]
                ])
            }
            var generationConfig: [String: Any] = [
                "temperature": completionRequest.temperature,
                "maxOutputTokens": completionRequest.maxTokens,
            ]
            if completionRequest.responseFormat == .jsonObject {
                generationConfig["responseMimeType"] = "application/json"
            }
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")!
            components.queryItems = [URLQueryItem(name: "key", value: "host-managed:\(ProviderCredentialKey.google.rawValue)")]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "contents": [
                    [
                        "role": "user",
                        "parts": parts,
                    ]
                ],
                "generationConfig": generationConfig,
            ])
            return request
        case .deepseek:
            var content: [[String: Any]] = [
                ["type": "text", "text": completionRequest.prompt]
            ]
            for path in completionRequest.imagePaths {
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": try dataURL(for: path)
                    ],
                ])
            }
            var body: [String: Any] = [
                "model": "deepseek-chat",
                "temperature": completionRequest.temperature,
                "messages": [
                    [
                        "role": "user",
                        "content": content,
                    ]
                ],
            ]
            if completionRequest.responseFormat == .jsonObject {
                body["response_format"] = ["type": "json_object"]
            }
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer host-managed:\(ProviderCredentialKey.deepseek.rawValue)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    private func jsonObject(for request: URLRequest) async throws -> [String: Any] {
        if let jsonLoader {
            return try await jsonLoader(request)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw HostVisionCompletionError.providerRejected
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostVisionCompletionError.invalidProviderResponse
        }
        return object
    }

    private func responseText(
        from object: [String: Any],
        provider: ProviderCredentialKey,
        responseFormat: HostResponseFormat
    ) throws -> String {
        let text: String?
        switch provider {
        case .openAI, .deepseek:
            text = openAIText(from: object)
        case .anthropic:
            text = anthropicText(from: object, responseFormat: responseFormat)
        case .google:
            text = googleText(from: object)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostVisionCompletionError.invalidProviderResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openAIText(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]] else { return nil }
        for choice in choices {
            guard let message = choice["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? String {
                return content
            }
        }
        return nil
    }

    private func anthropicText(from object: [String: Any], responseFormat: HostResponseFormat) -> String? {
        guard let content = object["content"] as? [[String: Any]] else { return nil }
        for part in content {
            switch responseFormat {
            case .text:
                if let text = part["text"] as? String { return text }
            case .jsonObject:
                guard
                    part["type"] as? String == "tool_use",
                    part["name"] as? String == "json_response",
                    let input = part["input"]
                else { continue }
                guard JSONSerialization.isValidJSONObject(input),
                      let data = try? JSONSerialization.data(withJSONObject: input),
                      let text = String(data: data, encoding: .utf8)
                else {
                    return nil
                }
                return text
            }
        }
        return nil
    }

    private func googleText(from object: [String: Any]) -> String? {
        guard let candidates = object["candidates"] as? [[String: Any]] else { return nil }
        for candidate in candidates {
            guard
                let content = candidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else { continue }
            for part in parts {
                if let text = part["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }

    private func dataURL(for path: String) throws -> String {
        "data:\(try mimeType(for: path));base64,\(try imageBase64(for: path))"
    }

    private func imageBase64(for path: String) throws -> String {
        try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
    }

    private func mimeType(for path: String) throws -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "png": return "image/png"
        default: throw HostVisionCompletionError.unsupportedImageType
        }
    }

    private func openAIJSONResponseFormat(name: String, schema: String) throws -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": name,
                "strict": true,
                "schema": try jsonObject(from: schema),
            ],
        ]
    }

    private func jsonObject(from text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}

nonisolated enum HostVisionCompletionError: Error {
    case missingProviderCredential
    case providerRejected
    case invalidProviderResponse
    case unsupportedImageType
}

nonisolated struct HostImageGenerationRequest {
    var prompt: String
    var outputDirectory: URL
    var referenceImagePath: String?
    var referenceMimeType: String?
}

nonisolated struct HostGeneratedImage: Equatable {
    var path: String
    var mimeType: String
}

nonisolated struct HostImageGenerationClient {
    typealias JSONLoader = HostLLMCompletionClient.JSONLoader

    let providerRouter: HostProviderRouter
    let session: URLSession
    let jsonLoader: JSONLoader?
    let model: String

    init(
        providerRouter: HostProviderRouter,
        session: URLSession = .shared,
        jsonLoader: JSONLoader? = nil,
        model: String = "gemini-3.1-flash-image"
    ) {
        self.providerRouter = providerRouter
        self.session = session
        self.jsonLoader = jsonLoader
        self.model = model
    }

    func generate(_ imageRequest: HostImageGenerationRequest) async throws -> HostGeneratedImage {
        guard (try providerRouter.configuredCredentials()[.google]) != nil else {
            throw HostImageGenerationError.missingGoogleCredential
        }
        var providerRequest = try request(
            prompt: imageRequest.prompt,
            referenceImagePath: imageRequest.referenceImagePath,
            referenceMimeType: imageRequest.referenceMimeType
        )
        try providerRouter.authorizeProviderRequest(&providerRequest)
        let object = try await jsonObject(for: providerRequest)
        let image = try generatedImage(from: object)
        try FileManager.default.createDirectory(
            at: imageRequest.outputDirectory,
            withIntermediateDirectories: true
        )
        guard let bytes = Data(base64Encoded: image.data) else {
            throw HostImageGenerationError.invalidImageData
        }
        let path = imageRequest.outputDirectory
            .appendingPathComponent("image_\(Int(Date().timeIntervalSince1970 * 1000)).\(Self.extensionForMime(image.mimeType))")
        try bytes.write(to: path, options: .atomic)
        return HostGeneratedImage(path: path.path, mimeType: image.mimeType)
    }

    private func request(
        prompt: String,
        referenceImagePath: String?,
        referenceMimeType: String?
    ) throws -> URLRequest {
        var parts: [[String: Any]] = [["text": prompt]]
        if let referenceImagePath, let referenceMimeType {
            let referenceData = try Data(contentsOf: URL(fileURLWithPath: referenceImagePath))
            parts.append([
                "inlineData": [
                    "mimeType": referenceMimeType,
                    "data": referenceData.base64EncodedString(),
                ],
            ])
        }

        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: "host-managed:\(ProviderCredentialKey.google.rawValue)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [
                [
                    "role": "user",
                    "parts": parts,
                ]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ],
        ])
        return request
    }

    private func jsonObject(for request: URLRequest) async throws -> [String: Any] {
        if let jsonLoader {
            return try await jsonLoader(request)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw HostImageGenerationError.providerRejected
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostImageGenerationError.invalidProviderResponse
        }
        return object
    }

    private func generatedImage(from object: [String: Any]) throws -> (data: String, mimeType: String) {
        if
            let output = object["output_image"] as? [String: Any],
            let image = imageData(from: output, mimeKey: "mime_type")
        {
            return image
        }
        if let candidates = object["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                guard
                    let content = candidate["content"] as? [String: Any],
                    let parts = content["parts"] as? [[String: Any]]
                else { continue }
                for part in parts {
                    if
                        let inlineData = part["inlineData"] as? [String: Any],
                        let image = imageData(from: inlineData, mimeKey: "mimeType")
                    {
                        return image
                    }
                    if
                        let inlineData = part["inline_data"] as? [String: Any],
                        let image = imageData(from: inlineData, mimeKey: "mime_type")
                    {
                        return image
                    }
                }
            }
        }
        throw HostImageGenerationError.invalidProviderResponse
    }

    private func imageData(from object: [String: Any], mimeKey: String) -> (data: String, mimeType: String)? {
        guard
            let data = object["data"] as? String,
            let mimeType = object[mimeKey] as? String
        else {
            return nil
        }
        if data.hasPrefix("data:") {
            guard
                let comma = data.firstIndex(of: ","),
                let marker = data.range(of: ";base64", range: data.startIndex..<comma)
            else {
                return nil
            }
            let parsedMimeType = String(data[data.index(data.startIndex, offsetBy: 5)..<marker.lowerBound])
            return (String(data[data.index(after: comma)...]), parsedMimeType)
        }
        return (data, mimeType)
    }

    private static func extensionForMime(_ mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/png": return "png"
        default: return "img"
        }
    }
}

nonisolated enum HostImageGenerationError: Error {
    case missingGoogleCredential
    case providerRejected
    case invalidProviderResponse
    case invalidImageData
}

nonisolated struct KeychainCredentialStore {
    private let service = "com.zelda-built-this.AMBI.provider-credentials"

    func credential(for key: ProviderCredentialKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainCredentialError.invalidStoredData
        }
        return String(data: data, encoding: .utf8)
    }

    func saveCredential(_ credential: String, for key: ProviderCredentialKey) throws {
        let data = Data(credential.utf8)
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status == errSecItemNotFound {
            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError.unhandledStatus(addStatus)
            }
            return
        }
        throw KeychainCredentialError.unhandledStatus(status)
    }

    func deleteCredential(for key: ProviderCredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unhandledStatus(status)
        }
    }

    private func baseQuery(for key: ProviderCredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
    }
}

nonisolated enum KeychainCredentialError: LocalizedError {
    case invalidStoredData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredData:
            return "The stored credential could not be decoded."
        case .unhandledStatus(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

#if os(macOS)

protocol AvatarKitImageGenerating: Sendable {
    func generate(
        prompt: String,
        outputDirectory: URL,
        referenceImage: HostGeneratedImage?
    ) async throws -> HostGeneratedImage
}

protocol AvatarKitVisionCompleting: Sendable {
    func complete(_ request: HostVisionCompletionRequest) async throws -> HostVisionCompletionResponse
}

extension HostImageGenerationClient: AvatarKitImageGenerating {
    func generate(
        prompt: String,
        outputDirectory: URL,
        referenceImage: HostGeneratedImage?
    ) async throws -> HostGeneratedImage {
        try await generate(
            .init(
                prompt: prompt,
                outputDirectory: outputDirectory,
                referenceImagePath: referenceImage?.path,
                referenceMimeType: referenceImage?.mimeType
            )
        )
    }
}

extension HostVisionCompletionClient: AvatarKitVisionCompleting {}

#endif
