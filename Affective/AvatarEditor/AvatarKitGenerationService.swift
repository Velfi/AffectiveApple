#if os(macOS)
//
//  Orchestrates avatar kit image generation and vision inspection.
//  Affective
//

import AppKit
import Foundation

nonisolated enum AvatarKitGenerationStep: String, CaseIterable {
    case generatingBaseHead
    case generatingEyesAtlas
    case generatingMouthAtlas
    case preparingAssets
    case inspectingAtlases
    case applyingResults

    var title: String {
        switch self {
        case .generatingBaseHead: "Generating base head"
        case .generatingEyesAtlas: "Generating eye atlas"
        case .generatingMouthAtlas: "Generating mouth atlas"
        case .preparingAssets: "Preparing assets"
        case .inspectingAtlases: "Inspecting atlases"
        case .applyingResults: "Applying results"
        }
    }
}

nonisolated struct AvatarKitGenerationCheckpoint: Equatable {
    var generatedDirectory: URL
    var generatedPaths: [AvatarKitAssetKind: URL]
}

nonisolated struct AvatarKitGeneratedAssets: Equatable {
    var headURL: URL
    var eyesURL: URL
    var mouthURL: URL
    var headRelativePath: String
    var eyesRelativePath: String
    var mouthRelativePath: String
}

nonisolated struct AvatarKitGenerationResult: Equatable {
    var assets: AvatarKitGeneratedAssets
    var inspection: AvatarAtlasInspection
    var eyeSprites: [AvatarAtlasSprite]
    var mouthSprites: [AvatarAtlasSprite]
    var canvasWidth: Double
    var canvasHeight: Double
    var neutralEyeName: String
    var neutralMouthName: String
    var statusNote: String?
    var lowConfidenceLayout: Bool
}

nonisolated struct AvatarKitCredentialStatus: Equatable {
    var hasGoogleCredential: Bool
    var hasVisionCredential: Bool

    var isReady: Bool {
        hasGoogleCredential && hasVisionCredential
    }

    static func current(providerRouter: HostProviderRouter) throws -> AvatarKitCredentialStatus {
        let credentials = try providerRouter.configuredCredentials()
        let hasVision = ProviderCredentialKey.allCases.contains { credentials[$0] != nil }
        return AvatarKitCredentialStatus(
            hasGoogleCredential: credentials[.google] != nil,
            hasVisionCredential: hasVision
        )
    }
}

actor AvatarKitGenerationService {
    private let imageGenerator: any AvatarKitImageGenerating
    private let visionClient: any AvatarKitVisionCompleting
    private let providerRouter: HostProviderRouter
    private let fileManager: FileManager

    init(
        providerRouter: HostProviderRouter,
        imageGenerator: (any AvatarKitImageGenerating)? = nil,
        visionClient: (any AvatarKitVisionCompleting)? = nil,
        fileManager: FileManager = .default
    ) {
        self.providerRouter = providerRouter
        self.imageGenerator = imageGenerator ?? HostImageGenerationClient(providerRouter: providerRouter)
        self.visionClient = visionClient ?? HostVisionCompletionClient(providerRouter: providerRouter)
        self.fileManager = fileManager
    }

    func generateKit(
        characterBrief: String,
        brainRoot: URL,
        checkpoint: AvatarKitGenerationCheckpoint? = nil,
        onStep: @Sendable (AvatarKitGenerationStep, String) -> Void,
        onCheckpoint: @Sendable (AvatarKitGenerationCheckpoint) -> Void = { _ in }
    ) async throws -> AvatarKitGenerationResult {
        try await validateCredentials()

        let brief = try AvatarKitGenerationPrompt.normalizedBrief(characterBrief)
        let generatedDirectory = checkpoint?.generatedDirectory ?? brainRoot
            .appendingPathComponent("avatar", isDirectory: true)
            .appendingPathComponent("generated", isDirectory: true)
            .appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        try fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)

        let prompts = try AvatarKitGenerationPrompt.allPrompts(characterBrief: brief)
        var generatedPaths = checkpoint?.generatedPaths ?? [:]

        for kind in AvatarKitAssetKind.allCases {
            if generatedPaths[kind] != nil {
                continue
            }

            try Task.checkCancellation()

            let step: AvatarKitGenerationStep = switch kind {
            case .baseHead: .generatingBaseHead
            case .eyesAtlas: .generatingEyesAtlas
            case .mouthAtlas: .generatingMouthAtlas
            }
            onStep(step, kind.assetFileName)

            guard let prompt = prompts[kind] else {
                throw AvatarKitGenerationError.generationFailed("Missing prompt for \(kind.rawValue).")
            }

            let sourceURL = try await generateAsset(
                kind: kind,
                prompt: prompt,
                generatedDirectory: generatedDirectory
            ) { detail in
                onStep(step, detail)
            }
            generatedPaths[kind] = sourceURL
            onCheckpoint(AvatarKitGenerationCheckpoint(
                generatedDirectory: generatedDirectory,
                generatedPaths: generatedPaths
            ))
        }

        onStep(.preparingAssets, "Removing backgrounds")
        try Task.checkCancellation()

        let (assets, stagingWarnings) = try stageAssets(
            generatedPaths: generatedPaths,
            stagedDirectory: generatedDirectory
        )

        return try await finalizeKitFromStagedAssets(
            assets: assets,
            stagingWarnings: stagingWarnings,
            onStep: onStep
        )
    }

    func regenerateAsset(
        kind: AvatarKitAssetKind,
        characterBrief: String,
        workingDirectory: URL,
        currentAssets: AvatarKitGeneratedAssets,
        onStep: @Sendable (AvatarKitGenerationStep, String) -> Void
    ) async throws -> AvatarKitGenerationResult {
        try await validateCredentials()

        let brief = try AvatarKitGenerationPrompt.normalizedBrief(characterBrief)
        let prompt = try AvatarKitGenerationPrompt.prompt(for: kind, characterBrief: brief)

        onStep(kind.generationStep, kind.assetFileName)
        let sourceURL = try await generateAsset(
            kind: kind,
            prompt: prompt,
            generatedDirectory: workingDirectory
        ) { detail in
            onStep(kind.generationStep, detail)
        }

        onStep(.preparingAssets, kind.assetFileName)
        var stagingWarnings: [String] = []
        let destination = workingDirectory.appendingPathComponent(kind.assetFileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if try prepareStagedAsset(from: sourceURL, to: destination, label: kind.assetFileName) {
            stagingWarnings.append(
                "\(kind.assetFileName) kept an opaque background (no transparency or key color detected)."
            )
        }

        var assets = currentAssets
        switch kind {
        case .baseHead:
            assets.headURL = destination
        case .eyesAtlas:
            assets.eyesURL = destination
        case .mouthAtlas:
            assets.mouthURL = destination
        }

        return try await finalizeKitFromStagedAssets(
            assets: assets,
            stagingWarnings: stagingWarnings,
            onStep: onStep
        )
    }

    static func stagedAssets(in directory: URL, fileManager: FileManager = .default) -> AvatarKitGeneratedAssets? {
        let headURL = directory.appendingPathComponent(AvatarKitAssetKind.baseHead.assetFileName)
        let eyesURL = directory.appendingPathComponent(AvatarKitAssetKind.eyesAtlas.assetFileName)
        let mouthURL = directory.appendingPathComponent(AvatarKitAssetKind.mouthAtlas.assetFileName)
        guard fileManager.fileExists(atPath: headURL.path),
              fileManager.fileExists(atPath: eyesURL.path),
              fileManager.fileExists(atPath: mouthURL.path) else {
            return nil
        }
        return AvatarKitGeneratedAssets(
            headURL: headURL,
            eyesURL: eyesURL,
            mouthURL: mouthURL,
            headRelativePath: "avatar/head.png",
            eyesRelativePath: "avatar/eyes.png",
            mouthRelativePath: "avatar/mouth.png"
        )
    }

    func credentialStatus() throws -> AvatarKitCredentialStatus {
        try AvatarKitCredentialStatus.current(providerRouter: providerRouter)
    }

    private func finalizeKitFromStagedAssets(
        assets: AvatarKitGeneratedAssets,
        stagingWarnings: [String],
        onStep: @Sendable (AvatarKitGenerationStep, String) -> Void
    ) async throws -> AvatarKitGenerationResult {
        onStep(.inspectingAtlases, "Analyzing layout")
        try Task.checkCancellation()

        let headSize = try imageSize(at: assets.headURL, label: assets.headRelativePath)
        let eyesSize = try imageSize(at: assets.eyesURL, label: assets.eyesRelativePath)
        let mouthSize = try imageSize(at: assets.mouthURL, label: assets.mouthRelativePath)

        let inspection = try await inspectAssets(
            assets: assets,
            headSize: headSize,
            eyesSize: eyesSize,
            mouthSize: mouthSize
        )
        try Task.checkCancellation()

        onStep(.applyingResults, "Ready for review")

        let lowConfidenceLayout = inspection.confidence.map { $0 < 0.6 } ?? false
        var statusNote = [inspection.notes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        statusNote.append(contentsOf: stagingWarnings)
        if lowConfidenceLayout, let confidence = inspection.confidence {
            statusNote.append(
                "Low-confidence layout (\(String(format: "%.0f%%", confidence * 100))). Review layer placement before saving."
            )
        }
        let combinedStatusNote = statusNote.isEmpty ? nil : statusNote.joined(separator: " ")

        return AvatarKitGenerationResult(
            assets: assets,
            inspection: inspection,
            eyeSprites: AvatarKitCanonicalSprites.eyeSprites(),
            mouthSprites: AvatarKitCanonicalSprites.mouthSprites(),
            canvasWidth: inspection.canvas.width,
            canvasHeight: inspection.canvas.height,
            neutralEyeName: AvatarKitCanonicalSprites.neutralEyeName,
            neutralMouthName: AvatarKitCanonicalSprites.neutralMouthName,
            statusNote: combinedStatusNote,
            lowConfidenceLayout: lowConfidenceLayout || !stagingWarnings.isEmpty
        )
    }

    private func generateAsset(
        kind: AvatarKitAssetKind,
        prompt: String,
        generatedDirectory: URL,
        onStepDetail: @Sendable (String) -> Void
    ) async throws -> URL {
        var image = try await imageGenerator.generate(
            prompt: prompt,
            outputDirectory: generatedDirectory,
            referenceImage: nil
        )
        try Task.checkCancellation()

        var sourceURL = URL(fileURLWithPath: image.path)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AvatarKitGenerationError.missingGeneratedImage(kind.assetFileName)
        }

        if !AvatarKitImageTransparency.hasTransparentPixels(at: sourceURL) {
            onStepDetail("\(kind.assetFileName) (removing checkerboard)")
            let fixPrompt = AvatarKitGenerationPrompt.removeCheckerboardBackgroundPrompt(for: kind)
            image = try await imageGenerator.generate(
                prompt: fixPrompt,
                outputDirectory: generatedDirectory,
                referenceImage: image
            )
            try Task.checkCancellation()
            sourceURL = URL(fileURLWithPath: image.path)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw AvatarKitGenerationError.missingGeneratedImage(kind.assetFileName)
            }
        }

        return sourceURL
    }

    private func validateCredentials() async throws {
        let credentials = try providerRouter.configuredCredentials()
        guard credentials[.google] != nil else {
            throw AvatarKitGenerationError.missingGoogleCredential
        }
        let hasVisionProvider = ProviderCredentialKey.allCases.contains { credentials[$0] != nil }
        guard hasVisionProvider else {
            throw AvatarKitGenerationError.missingVisionCredential
        }
    }

    private func stageAssets(
        generatedPaths: [AvatarKitAssetKind: URL],
        stagedDirectory: URL
    ) throws -> (AvatarKitGeneratedAssets, [String]) {
        var warnings: [String] = []

        func stage(_ kind: AvatarKitAssetKind) throws -> (URL, String) {
            guard let source = generatedPaths[kind] else {
                throw AvatarKitGenerationError.missingGeneratedImage(kind.assetFileName)
            }
            let relativePath = "avatar/\(kind.assetFileName)"
            let destination = stagedDirectory.appendingPathComponent(kind.assetFileName)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if try prepareStagedAsset(from: source, to: destination, label: kind.assetFileName) {
                warnings.append("\(kind.assetFileName) kept an opaque background (no transparency or key color detected).")
            }
            return (destination, relativePath)
        }

        let head = try stage(.baseHead)
        let eyes = try stage(.eyesAtlas)
        let mouth = try stage(.mouthAtlas)

        return (
            AvatarKitGeneratedAssets(
                headURL: head.0,
                eyesURL: eyes.0,
                mouthURL: mouth.0,
                headRelativePath: head.1,
                eyesRelativePath: eyes.1,
                mouthRelativePath: mouth.1
            ),
            warnings
        )
    }

    @discardableResult
    private func prepareStagedAsset(from source: URL, to destination: URL, label: String) throws -> Bool {
        if AvatarKitImageTransparency.hasTransparentPixels(at: source) {
            let image = try AvatarKitChromaKey.decodeImage(from: source)
            try AvatarKitChromaKey.writePNG(image, to: destination)
            return false
        }

        let decoded = try AvatarKitChromaKey.decodeImage(from: source)
        if AvatarKitChromaKey.containsDebugMagenta(in: decoded) {
            try AvatarKitChromaKey.removeDebugBackground(from: source, to: destination)
            return false
        }

        try AvatarKitChromaKey.writePNG(decoded, to: destination)
        return true
    }

    private func imageSize(at url: URL, label: String) throws -> CGSize {
        let image = try AvatarKitChromaKey.decodeImage(from: url)
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else {
            throw AvatarKitGenerationError.invalidImageSize(label)
        }
        return size
    }

    private func inspectAssets(
        assets: AvatarKitGeneratedAssets,
        headSize: CGSize,
        eyesSize: CGSize,
        mouthSize: CGSize
    ) async throws -> AvatarAtlasInspection {
        do {
            let response = try await visionClient.complete(
                HostVisionCompletionRequest(
                    prompt: AvatarAtlasInspection.visionPrompt,
                    imagePaths: [
                        assets.headURL.path,
                        assets.eyesURL.path,
                        assets.mouthURL.path,
                    ],
                    responseFormat: .jsonObject,
                    maxTokens: 2048,
                    temperature: 0,
                    jsonSchema: AvatarAtlasInspection.jsonSchema
                )
            )
            let decoded = try AvatarAtlasInspection.decode(from: response.text)
            return try decoded.validated(
                headSize: headSize,
                eyesImageSize: eyesSize,
                mouthImageSize: mouthSize
            )
        } catch {
            do {
                return try AvatarAtlasInspection.fallbackFromDetection(
                    headSize: headSize,
                    eyesImageSize: eyesSize,
                    mouthImageSize: mouthSize
                )
            } catch let fallbackError {
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let fallbackDetail = (fallbackError as? LocalizedError)?.errorDescription ?? fallbackError.localizedDescription
                throw AvatarKitGenerationError.inspectionFailed("\(detail) Autodetect fallback also failed: \(fallbackDetail)")
            }
        }
    }
}

#endif
