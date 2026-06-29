//
//  AppleFoundationModelsTextClient.swift
//  Affective
//

import Foundation
#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(visionOS))
import FoundationModels
#endif

nonisolated enum AppleFoundationModelsAvailability: String, Equatable {
    case available
    case deviceNotEligible = "device_not_eligible"
    case appleIntelligenceNotEnabled = "apple_intelligence_not_enabled"
    case modelNotReady = "model_not_ready"
    case unsupportedPlatform = "unsupported_platform"
    case unsupportedLocale = "unsupported_locale"
    case unavailable

    var isAvailable: Bool {
        self == .available
    }
}

nonisolated struct AppleFoundationModelsTextRequest: Equatable {
    var instructions: String
    var prompt: String
    var maxTokens: Int
    var temperature: Double
}

nonisolated struct AppleFoundationModelsTextClient {
    nonisolated static let isFeatureEnabled = false

    typealias AvailabilityProvider = () -> AppleFoundationModelsAvailability
    typealias CompletionProvider = (AppleFoundationModelsTextRequest) async throws -> String

    var availabilityProvider: AvailabilityProvider
    var completionProvider: CompletionProvider

    init(
        availabilityProvider: @escaping AvailabilityProvider = Self.currentAvailability,
        completionProvider: @escaping CompletionProvider = Self.completeWithSystemModel
    ) {
        self.availabilityProvider = availabilityProvider
        self.completionProvider = completionProvider
    }

    var availability: AppleFoundationModelsAvailability {
        availabilityProvider()
    }

    func complete(_ request: AppleFoundationModelsTextRequest) async throws -> String {
        let availability = availabilityProvider()
        guard availability.isAvailable else {
            throw AppleFoundationModelsTextError.unavailable(availability)
        }
        let text = try await completionProvider(request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppleFoundationModelsTextError.emptyResponse
        }
        return text
    }

    static func currentAvailability() -> AppleFoundationModelsAvailability {
        guard isFeatureEnabled else {
            return .unsupportedPlatform
        }
        #if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(visionOS))
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            return .unsupportedPlatform
        }
        let model = SystemLanguageModel.default
        guard model.supportsLocale() else {
            return .unsupportedLocale
        }
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unavailable
        }
        #else
        return .unsupportedPlatform
        #endif
    }

    static func completeWithSystemModel(_ request: AppleFoundationModelsTextRequest) async throws -> String {
        #if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(visionOS))
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw AppleFoundationModelsTextError.unavailable(.unsupportedPlatform)
        }
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            instructions: request.instructions
        )
        session.prewarm()
        let response = try await session.respond(
            to: request.prompt,
            options: GenerationOptions(
                temperature: request.temperature,
                maximumResponseTokens: request.maxTokens
            )
        )
        return response.content
        #else
        throw AppleFoundationModelsTextError.unavailable(.unsupportedPlatform)
        #endif
    }
}

nonisolated enum AppleFoundationModelsTextError: Error, CustomStringConvertible {
    case unavailable(AppleFoundationModelsAvailability)
    case emptyResponse

    var description: String {
        switch self {
        case .unavailable(let availability):
            return "Apple on-device language model is \(availability.rawValue)."
        case .emptyResponse:
            return "Apple on-device language model returned no text."
        }
    }
}
