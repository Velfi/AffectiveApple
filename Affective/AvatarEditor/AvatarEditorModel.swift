#if os(macOS)
//
//  Split from AvatarEditorView.swift
//  Affective
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class AvatarEditorModel: ObservableObject {
    let brain: BrainDescriptor
    var isClipFrameConstraintScheduled = false
    @Published var canvasWidth: Double
    @Published var canvasHeight: Double
    @Published var clipX: Double
    @Published var clipY: Double
    @Published var clipWidth: Double
    @Published var clipHeight: Double
    @Published var clipAspectMode: ClipAspectMode = .free
    @Published var customClipAspectWidth: Double = 16
    @Published var customClipAspectHeight: Double = 9
    @Published var slots: [AvatarSlot] {
        didSet {
            sanitizeSelections()
            syncSpriteTablesIfNeeded()
        }
    }
    @Published var selectedSlotID: AvatarSlot.ID
    @Published var selectedAtlasSlotID: AvatarSlot.ID
    @Published var editorSection: AvatarEditorSection = .layout
    @Published var eyeSprites: [AvatarAtlasSprite] {
        didSet { sanitizeSpriteSelections() }
    }
    @Published var mouthSprites: [AvatarAtlasSprite] {
        didSet { sanitizeSpriteSelections() }
    }
    @Published var neutralEyeName: String
    @Published var neutralMouthName: String
    @Published var neutralBlinkFramesText: String
    @Published var neutralBlinkFPS: Double
    @Published var previewEyeName: String
    @Published var previewMouthName: String
    @Published var characterBrief = ""
    @Published var generationStep: AvatarKitGenerationStep?
    @Published var completedGenerationSteps: Set<AvatarKitGenerationStep> = []
    @Published var isGenerating = false
    @Published var generatedPreviewURLs: [AvatarKitAssetKind: URL] = [:]
    @Published var generationError: String?
    @Published var failedGenerationStep: AvatarKitGenerationStep?
    @Published var generationCheckpoint: AvatarKitGenerationCheckpoint?
    @Published var generationWorkingDirectory: URL?
    @Published var regeneratingAssetKind: AvatarKitAssetKind?
    @Published var credentialStatus = AvatarKitCredentialStatus(hasGoogleCredential: false, hasVisionCredential: false)
    @Published var layoutConfidenceWarning: String?
    @Published var highlightsSave = false
    @Published var statusText = "Ready"

    private let generationService: AvatarKitGenerationService
    private var generationTask: Task<Void, Never>?
    private static let characterBriefDefaultsKey = "AvatarEditor.characterBrief"

    init(
        brain: BrainDescriptor,
        generationService: AvatarKitGenerationService? = nil
    ) {
        self.brain = brain
        self.generationService = generationService ?? AvatarKitGenerationService(
            providerRouter: HostProviderRouter(
                credentialProvider: CoreConfigStorage.providerCredentials
            )
        )
        let initial = Self.slots(from: brain.avatarManifest)
        slots = initial.slots
        canvasWidth = initial.canvas.width
        canvasHeight = initial.canvas.height
        clipX = initial.clip.x
        clipY = initial.clip.y
        clipWidth = initial.clip.width
        clipHeight = initial.clip.height
        selectedSlotID = AvatarSlot.Kind.head.rawValue
        selectedAtlasSlotID = AvatarSlot.Kind.eyes.rawValue

        let spriteState = Self.spriteState(from: brain.avatarManifest, slots: initial.slots)
        eyeSprites = spriteState.eyeSprites
        mouthSprites = spriteState.mouthSprites
        neutralEyeName = spriteState.neutralEyeName
        neutralMouthName = spriteState.neutralMouthName
        neutralBlinkFramesText = spriteState.neutralBlinkFramesText
        neutralBlinkFPS = spriteState.neutralBlinkFPS
        previewEyeName = spriteState.neutralEyeName
        previewMouthName = spriteState.neutralMouthName

        if brain.avatarManifest == nil && !Self.hasExistingAvatarAssets(at: brain.rootURL) {
            editorSection = .generate
        }

        characterBrief = UserDefaults.standard.string(forKey: Self.characterBriefDefaultsKey) ?? ""
        constrainClipFrame()
        refreshCredentialStatus()
    }

    deinit {
        generationTask?.cancel()
    }

    func refreshCredentialStatus() {
        credentialStatus = (try? AvatarKitCredentialStatus.current(
            providerRouter: HostProviderRouter(credentialProvider: CoreConfigStorage.providerCredentials)
        )) ?? AvatarKitCredentialStatus(hasGoogleCredential: false, hasVisionCredential: false)
    }

    static func hasExistingAvatarAssets(at brainRoot: URL) -> Bool {
        let avatarDirectory = brainRoot.appendingPathComponent("avatar", isDirectory: true)
        let fileManager = FileManager.default
        let assetNames = ["head.png", "eyes.png", "mouth.png"]
        if assetNames.contains(where: { fileManager.fileExists(atPath: avatarDirectory.appendingPathComponent($0).path) }) {
            return true
        }
        return fileManager.fileExists(atPath: brainRoot.appendingPathComponent("avatar.json").path)
    }

    var hasExistingAvatarAssets: Bool {
        Self.hasExistingAvatarAssets(at: brain.rootURL) || brain.avatarManifest != nil
    }

    var hasPendingGeneratedAssets: Bool {
        slots.contains { $0.sourceURL != nil }
    }

    var selectedSlotIndex: Int? {
        slots.firstIndex { $0.id == selectedSlotID }
    }

    var selectedSlot: AvatarSlot? {
        selectedSlotIndex.map { slots[$0] }
    }

    var canResetSelectedLayer: Bool {
        activeLayerResetSlotID != nil
    }

    var selectedAtlasSlotIndex: Int? {
        slots.firstIndex { $0.id == selectedAtlasSlotID }
    }

    var selectedAtlasSlot: AvatarSlot? {
        selectedAtlasSlotIndex.map { slots[$0] }
    }

    var atlasSlots: [AvatarSlot] {
        slots.filter(\.supportsAtlas)
    }

    var hasRenderableLayer: Bool {
        slots.contains { $0.isEnabled && $0.hasRenderableContent }
    }

    var previewManifest: BrainAvatarManifest {
        BrainAvatarManifest(
            canvas: .init(width: canvasWidth, height: canvasHeight),
            clip: savedClipFrame,
            layers: slots.compactMap(\.manifestLayer),
            eyeSprites: eyeSprites,
            mouthSprites: mouthSprites,
            defaultExpression: "neutral",
            expressions: neutralExpressionManifests,
            rootURL: brain.rootURL
        )
    }

    var canvasPreviewManifest: BrainAvatarManifest {
        if editorSection == .atlases {
            return BrainAvatarManifest(
                canvas: .init(width: canvasWidth, height: canvasHeight),
                clip: savedClipFrame,
                layers: slots.compactMap(\.manifestLayer),
                eyeSprites: eyeSprites,
                mouthSprites: mouthSprites,
                rootURL: brain.rootURL
            )
        }
        return previewManifest
    }

    var savedManifest: BrainAvatarManifest {
        previewManifest
    }

    func resetToManifest() {
        let initial = Self.slots(from: brain.avatarManifest)
        slots = initial.slots
        canvasWidth = initial.canvas.width
        canvasHeight = initial.canvas.height
        clipX = initial.clip.x
        clipY = initial.clip.y
        clipWidth = initial.clip.width
        clipHeight = initial.clip.height

        let spriteState = Self.spriteState(from: brain.avatarManifest, slots: initial.slots)
        eyeSprites = spriteState.eyeSprites
        mouthSprites = spriteState.mouthSprites
        neutralEyeName = spriteState.neutralEyeName
        neutralMouthName = spriteState.neutralMouthName
        neutralBlinkFramesText = spriteState.neutralBlinkFramesText
        neutralBlinkFPS = spriteState.neutralBlinkFPS
        previewEyeName = spriteState.neutralEyeName
        previewMouthName = spriteState.neutralMouthName

        sanitizeSelections()
        statusText = "Reloaded current avatar."
    }

    func resetSelectedLayerToDefaults() {
        guard let slotID = activeLayerResetSlotID,
              let index = slots.firstIndex(where: { $0.id == slotID })
        else { return }

        let kind = slots[index].kind
        slots[index] = Self.defaultSlot(kind: kind, from: brain.avatarManifest)
        statusText = "Reset \(slots[index].title) to defaults."
    }

    func clear(slotID: AvatarSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].sourceURL = nil
        slots[index].relativePath = nil
        if slots[index].kind == .background {
            slots[index].backgroundColor = nil
            slots[index].isBackgroundTransparent = false
        }
    }

    func setAsset(_ url: URL, for slotID: AvatarSlot.ID) throws {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = slots[index]
        let relativePath = "avatar/\(slot.kind.assetFileName(for: url))"
        let fileManager = FileManager.default
        let avatarDirectory = brain.rootURL.appendingPathComponent("avatar", isDirectory: true)
        let destination = brain.rootURL.appendingPathComponent(relativePath)

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try fileManager.createDirectory(at: avatarDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)

        slots[index].sourceURL = nil
        slots[index].relativePath = relativePath
        slots[index].isEnabled = true

        if let size = AvatarAssetImageLoader.loadImage(from: destination, layerID: slotID)?.pixelSize {
            if slot.kind == .background {
                canvasWidth = Double(size.width)
                canvasHeight = Double(size.height)
                slots[index].x = canvasWidth / 2
                slots[index].y = canvasHeight / 2
                slots[index].width = Double(size.width)
                slots[index].height = Double(size.height)
                slots[index].backgroundColor = nil
                slots[index].isBackgroundTransparent = false
                resetClipToCanvas()
            }
            slots[index].width = Double(size.width)
            slots[index].height = Double(size.height)
            if slot.usesAtlas {
                slots[index].frameWidth = Double(size.width)
                slots[index].frameHeight = Double(size.height)
            }
        }
        statusText = "Selected \(url.lastPathComponent)."
    }

    func copyPendingAssets() throws {
        let fileManager = FileManager.default
        let avatarDirectory = brain.rootURL.appendingPathComponent("avatar", isDirectory: true)
        try fileManager.createDirectory(at: avatarDirectory, withIntermediateDirectories: true)

        for index in slots.indices {
            guard let sourceURL = slots[index].sourceURL, let relativePath = slots[index].relativePath else { continue }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            let destination = brain.rootURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
            slots[index].sourceURL = nil
        }
    }

    func slot(kind: AvatarSlot.Kind) -> AvatarSlot? {
        slots.first { $0.kind == kind }
    }

    func assetURL(for slot: AvatarSlot) -> URL? {
        guard let relativePath = slot.relativePath else { return nil }
        if let sourceURL = slot.sourceURL {
            return sourceURL
        }
        return brain.rootURL.appendingPathComponent(relativePath)
    }

    func assetURL(forRelativePath path: String) -> URL {
        if let slot = slots.first(where: { $0.relativePath == path }),
           let url = assetURL(for: slot) {
            return url
        }
        return brain.rootURL.appendingPathComponent(path)
    }

    func previewEyeSprite(frame: Int) {
        guard let sprite = eyeSprites.first(where: { $0.frame == frame }) else { return }
        previewEyeName = sprite.name
    }

    func previewMouthSprite(frame: Int) {
        guard let sprite = mouthSprites.first(where: { $0.frame == frame }) else { return }
        previewMouthName = sprite.name
    }

    func moveClipFrame(x: Double, y: Double) {
        clipX = x
        clipY = y
        constrainClipFrame()
    }

    func resizeClipFrame(width: Double, height: Double) {
        clipWidth = width
        clipHeight = height
        constrainClipFrame()
    }

    func worldContentBounds(padding: Double = 64, editorSection: AvatarEditorSection) -> CGRect {
        let cw = normalizedDimension(canvasWidth, defaultValue: 1024)
        let ch = normalizedDimension(canvasHeight, defaultValue: 1024)

        switch editorSection {
        case .clip, .layout, .generate, .expressions:
            return CGRect(x: 0, y: 0, width: cw, height: ch)
        case .atlases:
            var bounds = CGRect(x: 0, y: 0, width: cw, height: ch)
            for slot in slots where slot.isEnabled && slot.hasRenderableContent {
                let origin = slot.topLeftOrigin()
                bounds = bounds.union(
                    CGRect(x: origin.x, y: origin.y, width: slot.width, height: slot.height)
                )
            }
            return bounds.insetBy(dx: -padding, dy: -padding)
        }
    }

    enum ClipFrameSizeDriver {
        case width
        case height
    }

    func scheduleClipFrameConstraint(driving sizeDriver: ClipFrameSizeDriver = .width) {
        guard !isClipFrameConstraintScheduled else { return }
        isClipFrameConstraintScheduled = true
        let sizeDriver = sizeDriver
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClipFrameConstraintScheduled = false
            self.constrainClipFrame(driving: sizeDriver)
        }
    }

    func constrainClipFrame(driving sizeDriver: ClipFrameSizeDriver = .width) {
        canvasWidth = normalizedDimension(canvasWidth, defaultValue: 1024)
        canvasHeight = normalizedDimension(canvasHeight, defaultValue: 1024)
        clipWidth = max(normalizedDimension(clipWidth, defaultValue: 512), 1)
        clipHeight = max(normalizedDimension(clipHeight, defaultValue: 512), 1)

        if let ratio = clipAspectMode.ratio {
            switch sizeDriver {
            case .width:
                clipHeight = clipWidth / ratio
            case .height:
                clipWidth = clipHeight * ratio
            }
        }

        if !clipX.isFinite { clipX = 0 }
        if !clipY.isFinite { clipY = 0 }

        clipWidth = min(clipWidth, canvasWidth)
        clipHeight = min(clipHeight, canvasHeight)
        clipX = min(max(clipX, 0), max(canvasWidth - clipWidth, 0))
        clipY = min(max(clipY, 0), max(canvasHeight - clipHeight, 0))
    }

    func resetClipToCanvas() {
        clipAspectMode = .free
        clipX = 0
        clipY = 0
        clipWidth = normalizedDimension(canvasWidth, defaultValue: 1024)
        clipHeight = normalizedDimension(canvasHeight, defaultValue: 1024)
        statusText = "Clip frame now uses the full canvas."
    }

    func centerSquareClip() {
        setClipAspect(width: 1, height: 1)
        statusText = "Clip frame centered as a square."
    }

    func setClipAspect(width aspectWidth: Double, height aspectHeight: Double) {
        guard aspectWidth > 0, aspectHeight > 0 else { return }
        clipAspectMode = .locked(width: aspectWidth, height: aspectHeight)
        customClipAspectWidth = aspectWidth
        customClipAspectHeight = aspectHeight

        let ratio = aspectWidth / aspectHeight
        let defaultWidth = min(normalizedDimension(self.canvasWidth, defaultValue: 1024), 512)
        clipWidth = defaultWidth
        clipHeight = defaultWidth / ratio

        let cw = normalizedDimension(self.canvasWidth, defaultValue: 1024)
        let ch = normalizedDimension(self.canvasHeight, defaultValue: 1024)
        clipX = (cw - clipWidth) / 2
        clipY = (ch - clipHeight) / 2
        constrainClipFrame()
        statusText = "Clip frame set to \(Int(aspectWidth)):\(Int(aspectHeight))."
    }

    func setClipAspectFree() {
        clipAspectMode = .free
        statusText = "Clip aspect ratio is free."
    }

    func autodetectAtlas(slotID: AvatarSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }),
              slots[index].supportsAtlas,
              let url = assetURL(for: slots[index]),
              let size = AvatarAssetImageLoader.loadImage(from: url, layerID: slotID)?.pixelSize
        else {
            statusText = "Autodetect needs a selected atlas image."
            return
        }

        let detection = SpriteAtlasDetection.detect(
            imageSize: size,
            kind: slots[index].kind,
            current: slots[index]
        )
        slots[index].usesAtlas = true
        slots[index].columns = detection.columns
        slots[index].rows = detection.rows
        slots[index].frameX = detection.frameX
        slots[index].frameY = detection.frameY
        slots[index].frameWidth = detection.frameWidth
        slots[index].frameHeight = detection.frameHeight
        slots[index].syncAtlasGrid()
        slots[index].selectedFrame = min(slots[index].selectedFrame, max(slots[index].frames - 1, 0))
        if slots[index].kind == .blink {
            slots[index].isAnimatedAtlas = true
        }
        statusText = "Detected \(detection.columns)x\(detection.rows) atlas for \(slots[index].title)."
    }

    static func slots(from manifest: BrainAvatarManifest?) -> (canvas: BrainAvatarManifest.Canvas, clip: BrainAvatarManifest.ClipFrame, slots: [AvatarSlot]) {
        let canvas = manifest?.canvas ?? .init(width: 1024, height: 1536)
        let clip = manifest?.clip ?? .init(width: canvas.width, height: canvas.height)
        var slots = AvatarSlot.Kind.allCases.map { AvatarSlot(kind: $0) }

        for layer in manifest?.layers ?? [] {
            guard let kind = AvatarSlot.Kind(rawValue: layer.id),
                  let index = slots.firstIndex(where: { $0.kind == kind })
            else { continue }
            slots[index].apply(layer, rootURL: manifest?.rootURL)
        }

        if let backgroundIndex = slots.firstIndex(where: { $0.kind == .background }) {
            let background = slots[backgroundIndex]
            if !background.hasRenderableContent {
                slots[backgroundIndex].x = canvas.width / 2
                slots[backgroundIndex].y = canvas.height / 2
                slots[backgroundIndex].width = canvas.width
                slots[backgroundIndex].height = canvas.height
            }
        }

        return (canvas, clip, slots)
    }

    var activeLayerResetSlotID: AvatarSlot.ID? {
        switch editorSection {
        case .layout:
            selectedSlotID
        case .atlases:
            selectedAtlasSlotID
        case .generate, .expressions, .clip:
            nil
        }
    }

    var canGenerateAvatarKit: Bool {
        !characterBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && regeneratingAssetKind == nil
            && credentialStatus.isReady
    }

    var hasAnyGeneratedPreview: Bool {
        AvatarKitAssetKind.allCases.contains { previewURL(for: $0) != nil }
    }

    func previewURL(for kind: AvatarKitAssetKind) -> URL? {
        if let url = generatedPreviewURLs[kind] {
            return url
        }
        guard let slot = slot(kind: kind.slotKind) else { return nil }
        return assetURL(for: slot)
    }

    func canRegenerateAsset(_ kind: AvatarKitAssetKind) -> Bool {
        !characterBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && regeneratingAssetKind == nil
            && credentialStatus.isReady
            && currentStagedAssets() != nil
    }

    var canResumeGeneration: Bool {
        !isGenerating
            && credentialStatus.isReady
            && generationCheckpoint != nil
            && generationError != nil
    }

    func requestGenerateAvatarKit(resume: Bool = false) {
        guard canGenerateAvatarKit else { return }
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            await generateAvatarKit(resume: resume)
        }
    }

    func retryGeneration() {
        requestGenerateAvatarKit(resume: generationCheckpoint != nil)
    }

    func cancelGeneration() {
        generationTask?.cancel()
    }

    func requestRegenerateAsset(_ kind: AvatarKitAssetKind) {
        guard canRegenerateAsset(kind) else { return }
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            await regenerateAsset(kind)
        }
    }

    func currentStagedAssets() -> AvatarKitGeneratedAssets? {
        if let directory = generationWorkingDirectory,
           let assets = AvatarKitGenerationService.stagedAssets(in: directory) {
            return assets
        }
        if let directory = generationCheckpoint?.generatedDirectory,
           let assets = AvatarKitGenerationService.stagedAssets(in: directory) {
            return assets
        }
        guard let headURL = previewURL(for: .baseHead) else { return nil }
        let directory = headURL.deletingLastPathComponent()
        return AvatarKitGenerationService.stagedAssets(in: directory)
    }

    private func noteWorkingDirectory(from assets: AvatarKitGeneratedAssets) {
        generationWorkingDirectory = assets.headURL.deletingLastPathComponent()
    }

    @MainActor
    private func generateAvatarKit(resume: Bool) async {
        guard !characterBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refreshCredentialStatus()
        guard credentialStatus.isReady else {
            if !credentialStatus.hasGoogleCredential {
                statusText = AvatarKitGenerationError.missingGoogleCredential.localizedDescription
            } else {
                statusText = AvatarKitGenerationError.missingVisionCredential.localizedDescription
            }
            return
        }

        if resume {
            guard generationCheckpoint != nil else {
                generationError = "Nothing to resume."
                return
            }
            generationError = nil
            failedGenerationStep = nil
        } else {
            generationCheckpoint = nil
            generationError = nil
            failedGenerationStep = nil
            completedGenerationSteps = []
            generatedPreviewURLs = [:]
            generationWorkingDirectory = nil
        }

        isGenerating = true
        layoutConfidenceWarning = nil
        highlightsSave = false

        if resume, let checkpoint = generationCheckpoint {
            restoreCompletedSteps(from: checkpoint)
            generationStep = checkpoint.generatedPaths.count == AvatarKitAssetKind.allCases.count
                ? .preparingAssets
                : nextGenerationStep(for: checkpoint)
        } else {
            generationStep = .generatingBaseHead
        }

        UserDefaults.standard.set(characterBrief, forKey: Self.characterBriefDefaultsKey)

        do {
            let result = try await generationService.generateKit(
                characterBrief: characterBrief,
                brainRoot: brain.rootURL,
                checkpoint: resume ? generationCheckpoint : nil
            ) { [weak self] step, detail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let previous = self.generationStep {
                        self.completedGenerationSteps.insert(previous)
                    }
                    self.generationStep = step
                    self.statusText = "\(step.title): \(detail)"
                }
            } onCheckpoint: { [weak self] checkpoint in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.generationCheckpoint = checkpoint
                    self.generatedPreviewURLs = checkpoint.generatedPaths
                    self.generationWorkingDirectory = checkpoint.generatedDirectory
                }
            }

            if let finalStep = generationStep {
                completedGenerationSteps.insert(finalStep)
            }
            generationStep = nil
            isGenerating = false
            generationCheckpoint = nil
            generationError = nil
            failedGenerationStep = nil

            applyGenerationResult(result)
            noteWorkingDirectory(from: result.assets)
            editorSection = .layout
            highlightsSave = true
            if result.lowConfidenceLayout {
                layoutConfidenceWarning = result.statusNote
            }
            statusText = result.statusNote ?? "Generated avatar kit. Save to write assets and avatar.json."
        } catch is CancellationError {
            generationStep = nil
            isGenerating = false
            statusText = "Generation cancelled."
        } catch {
            failedGenerationStep = generationStep ?? failedGenerationStep ?? .preparingAssets
            generationStep = nil
            isGenerating = false
            generationError = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func restoreCompletedSteps(from checkpoint: AvatarKitGenerationCheckpoint) {
        for kind in checkpoint.generatedPaths.keys {
            switch kind {
            case .baseHead:
                completedGenerationSteps.insert(.generatingBaseHead)
            case .eyesAtlas:
                completedGenerationSteps.insert(.generatingEyesAtlas)
            case .mouthAtlas:
                completedGenerationSteps.insert(.generatingMouthAtlas)
            }
        }
    }

    private func nextGenerationStep(for checkpoint: AvatarKitGenerationCheckpoint) -> AvatarKitGenerationStep {
        if checkpoint.generatedPaths[.baseHead] == nil {
            return .generatingBaseHead
        }
        if checkpoint.generatedPaths[.eyesAtlas] == nil {
            return .generatingEyesAtlas
        }
        if checkpoint.generatedPaths[.mouthAtlas] == nil {
            return .generatingMouthAtlas
        }
        return .preparingAssets
    }

    @MainActor
    private func regenerateAsset(_ kind: AvatarKitAssetKind) async {
        guard canRegenerateAsset(kind) else { return }
        refreshCredentialStatus()

        guard let currentAssets = currentStagedAssets() else {
            generationError = "No staged avatar kit is available to update."
            statusText = generationError ?? "Regeneration failed."
            return
        }
        let workingDirectory = generationWorkingDirectory
            ?? generationCheckpoint?.generatedDirectory
            ?? currentAssets.headURL.deletingLastPathComponent()

        generationWorkingDirectory = workingDirectory
        regeneratingAssetKind = kind
        generationError = nil
        failedGenerationStep = nil
        generationStep = kind.generationStep
        highlightsSave = false

        do {
            let result = try await generationService.regenerateAsset(
                kind: kind,
                characterBrief: characterBrief,
                workingDirectory: workingDirectory,
                currentAssets: currentAssets
            ) { [weak self] step, detail in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.generationStep = step
                    self.statusText = "\(step.title): \(detail)"
                }
            }

            generationStep = nil
            regeneratingAssetKind = nil
            applyGenerationResult(result)
            noteWorkingDirectory(from: result.assets)
            highlightsSave = true
            if result.lowConfidenceLayout {
                layoutConfidenceWarning = result.statusNote
            } else {
                layoutConfidenceWarning = nil
            }
            statusText = result.statusNote ?? "Regenerated \(kind.assetFileName)."
        } catch is CancellationError {
            generationStep = nil
            regeneratingAssetKind = nil
            statusText = "Regeneration cancelled."
        } catch {
            generationStep = nil
            regeneratingAssetKind = nil
            generationError = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func applyGenerationResult(_ result: AvatarKitGenerationResult) {
        canvasWidth = result.canvasWidth
        canvasHeight = result.canvasHeight
        resetClipToCanvas()

        result.inspection.apply(
            to: &slots,
            headRelativePath: result.assets.headRelativePath,
            eyesRelativePath: result.assets.eyesRelativePath,
            mouthRelativePath: result.assets.mouthRelativePath
        )
        applyStagedAssetURLs(from: result.assets)

        eyeSprites = result.eyeSprites
        mouthSprites = result.mouthSprites
        neutralEyeName = result.neutralEyeName
        neutralMouthName = result.neutralMouthName
        previewEyeName = result.neutralEyeName
        previewMouthName = result.neutralMouthName
        neutralBlinkFramesText = Self.defaultEyeBlinkFramesText

        generatedPreviewURLs = [
            .baseHead: result.assets.headURL,
            .eyesAtlas: result.assets.eyesURL,
            .mouthAtlas: result.assets.mouthURL,
        ]

        sanitizeSelections()
    }

    private func applyStagedAssetURLs(from assets: AvatarKitGeneratedAssets) {
        let staged: [(AvatarSlot.Kind, URL)] = [
            (.head, assets.headURL),
            (.eyes, assets.eyesURL),
            (.mouth, assets.mouthURL),
        ]
        for (kind, url) in staged {
            guard let index = slots.firstIndex(where: { $0.kind == kind }) else { continue }
            slots[index].sourceURL = url
        }
    }

    func noteAvatarSaved() {
        highlightsSave = false
        layoutConfidenceWarning = nil
    }

    var savedClipFrame: BrainAvatarManifest.ClipFrame? {
        let canvasWidth = normalizedDimension(self.canvasWidth, defaultValue: 1024)
        let canvasHeight = normalizedDimension(self.canvasHeight, defaultValue: 1024)
        let clipWidth = max(normalizedDimension(self.clipWidth, defaultValue: canvasWidth), 1)
        let clipHeight = max(normalizedDimension(self.clipHeight, defaultValue: canvasHeight), 1)
        let clipX = clipX.isFinite ? clipX : 0
        let clipY = clipY.isFinite ? clipY : 0
        let normalized = BrainAvatarManifest.ClipFrame(
            x: clipX,
            y: clipY,
            width: clipWidth,
            height: clipHeight
        )
        let isFullCanvas = abs(normalized.x) < 0.0001
            && abs(normalized.y) < 0.0001
            && abs(normalized.width - canvasWidth) < 0.0001
            && abs(normalized.height - canvasHeight) < 0.0001
        return isFullCanvas ? nil : normalized
    }

    func syncAtlasGrid(for slotID: AvatarSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].syncAtlasGrid()
        syncSpriteTablesIfNeeded()
    }

    func normalizedDimension(_ value: Double, defaultValue: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultValue }
        return value
    }

    func sanitizeSelections() {
        if !slots.contains(where: { $0.id == selectedSlotID }) {
            selectedSlotID = slots.first?.id ?? AvatarSlot.Kind.head.rawValue
        }
        let atlasSlotIDs = Set(atlasSlots.map(\.id))
        if !atlasSlotIDs.contains(selectedAtlasSlotID) {
            selectedAtlasSlotID = atlasSlots.first?.id ?? AvatarSlot.Kind.eyes.rawValue
        }
        sanitizeSpriteSelections()
    }

    func sanitizeSpriteSelections() {
        if !eyeSprites.isEmpty, !eyeSprites.contains(where: { $0.name == neutralEyeName }) {
            neutralEyeName = eyeSprites[0].name
        }
        if !mouthSprites.isEmpty, !mouthSprites.contains(where: { $0.name == neutralMouthName }) {
            neutralMouthName = mouthSprites[0].name
        }
        if !eyeSprites.isEmpty, !eyeSprites.contains(where: { $0.name == previewEyeName }) {
            previewEyeName = neutralEyeName
        }
        if !mouthSprites.isEmpty, !mouthSprites.contains(where: { $0.name == previewMouthName }) {
            previewMouthName = neutralMouthName
        }
    }

    func syncSpriteTablesIfNeeded() {
        if let eyes = slot(kind: .eyes), eyes.usesAtlas {
            eyeSprites = BrainAvatarManifest.syncedSprites(
                existing: eyeSprites,
                columns: eyes.columns,
                rows: eyes.rows,
                prefix: "eyes"
            )
        }
        if let mouth = slot(kind: .mouth), mouth.usesAtlas {
            mouthSprites = BrainAvatarManifest.syncedSprites(
                existing: mouthSprites,
                columns: mouth.columns,
                rows: mouth.rows,
                prefix: "mouth"
            )
        }
    }

    static func defaultSlot(kind: AvatarSlot.Kind, from manifest: BrainAvatarManifest?) -> AvatarSlot {
        var slot = AvatarSlot(kind: kind)
        if let layer = manifest?.layers.first(where: { $0.id == kind.rawValue }) {
            slot.apply(layer, rootURL: manifest?.rootURL)
        }
        return slot
    }

    var neutralBlinkFrames: [Int] {
        neutralBlinkFramesText
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 >= 0 }
    }

    var usesSeparateBlinkAtlas: Bool {
        guard let blink = slot(kind: .blink) else { return false }
        return blink.isEnabled && blink.usesAtlas && blink.relativePath != nil
    }

    static let defaultEyeBlinkFramesText = "0,14,15,14,0"

    var neutralExpressionManifests: [BrainAvatarManifest.Expression] {
        var layers: [String: BrainAvatarManifest.LayerOverride] = [
            AvatarSlot.Kind.mouth.rawValue: .init(sprite: neutralMouthName),
        ]
        let blinkFrames = neutralBlinkFrames
        if !blinkFrames.isEmpty {
            let blinkOverride = BrainAvatarManifest.LayerOverride(
                frames: blinkFrames,
                fps: max(neutralBlinkFPS, 1)
            )
            if usesSeparateBlinkAtlas {
                layers[AvatarSlot.Kind.eyes.rawValue] = .init(sprite: neutralEyeName)
                layers[AvatarSlot.Kind.blink.rawValue] = blinkOverride
            } else {
                layers[AvatarSlot.Kind.eyes.rawValue] = blinkOverride
            }
        } else {
            layers[AvatarSlot.Kind.eyes.rawValue] = .init(sprite: neutralEyeName)
        }
        return [
            .init(id: "neutral", name: "Neutral", layers: layers),
        ]
    }

    static func spriteState(
        from manifest: BrainAvatarManifest?,
        slots: [AvatarSlot]
    ) -> (
        eyeSprites: [AvatarAtlasSprite],
        mouthSprites: [AvatarAtlasSprite],
        neutralEyeName: String,
        neutralMouthName: String,
        neutralBlinkFramesText: String,
        neutralBlinkFPS: Double
    ) {
        let eyesSlot = slots.first { $0.kind == .eyes }
        let mouthSlot = slots.first { $0.kind == .mouth }
        let blinkFPS = slots.first { $0.kind == .blink }?.fps ?? 8

        var eyeSprites = manifest?.eyeSprites ?? []
        var mouthSprites = manifest?.mouthSprites ?? []

        if eyeSprites.isEmpty, let eyesSlot, eyesSlot.usesAtlas {
            eyeSprites = BrainAvatarManifest.syncedSprites(
                existing: [],
                columns: eyesSlot.columns,
                rows: eyesSlot.rows,
                prefix: "eyes"
            )
        }
        if mouthSprites.isEmpty, let mouthSlot, mouthSlot.usesAtlas {
            mouthSprites = BrainAvatarManifest.syncedSprites(
                existing: [],
                columns: mouthSlot.columns,
                rows: mouthSlot.rows,
                prefix: "mouth"
            )
        }

        let neutralExpression = manifest?.expressions.first(where: { $0.id == "neutral" })
            ?? manifest?.expressions.first(where: { $0.id == manifest?.defaultExpression })
            ?? manifest?.expressions.first

        var neutralEyeName = eyeSprites.first?.name ?? "eyes_0"
        var neutralMouthName = mouthSprites.first?.name ?? "mouth_0"
        var neutralBlinkFramesText = Self.defaultEyeBlinkFramesText
        var neutralBlinkFPS = blinkFPS

        if let neutralExpression {
            if let sprite = neutralExpression.layers[AvatarSlot.Kind.eyes.rawValue]?.sprite,
               eyeSprites.contains(where: { $0.name == sprite }) {
                neutralEyeName = sprite
            } else if let frame = neutralExpression.layers[AvatarSlot.Kind.eyes.rawValue]?.frame,
                      let sprite = eyeSprites.first(where: { $0.frame == frame }) {
                neutralEyeName = sprite.name
            }

            if let sprite = neutralExpression.layers[AvatarSlot.Kind.mouth.rawValue]?.sprite,
               mouthSprites.contains(where: { $0.name == sprite }) {
                neutralMouthName = sprite
            } else if let frame = neutralExpression.layers[AvatarSlot.Kind.mouth.rawValue]?.frame,
                      let sprite = mouthSprites.first(where: { $0.frame == frame }) {
                neutralMouthName = sprite.name
            }

            if let eyes = neutralExpression.layers[AvatarSlot.Kind.eyes.rawValue],
               let frames = eyes.frames,
               !frames.isEmpty {
                neutralBlinkFramesText = frames.map(String.init).joined(separator: ",")
                if let fps = eyes.fps {
                    neutralBlinkFPS = fps
                }
            } else if let blink = neutralExpression.layers[AvatarSlot.Kind.blink.rawValue] {
                if let frames = blink.frames, !frames.isEmpty {
                    neutralBlinkFramesText = frames.map(String.init).joined(separator: ",")
                }
                if let fps = blink.fps {
                    neutralBlinkFPS = fps
                }
            }
        }

        return (
            eyeSprites,
            mouthSprites,
            neutralEyeName,
            neutralMouthName,
            neutralBlinkFramesText,
            neutralBlinkFPS
        )
    }

    func copyLLMTemplateToClipboard() {
        guard !eyeSprites.isEmpty, !mouthSprites.isEmpty else {
            statusText = "Configure eyes and mouth atlases before copying an LLM template."
            return
        }

        do {
            let template = AvatarExpressionLLMTemplate.makeTemplate(
                eyeSprites: eyeSprites,
                mouthSprites: mouthSprites,
                neutralEyeName: neutralEyeName,
                neutralMouthName: neutralMouthName,
                neutralBlinkFramesText: neutralBlinkFramesText,
                neutralBlinkFPS: neutralBlinkFPS,
                blankNames: true
            )
            let text = try template.encodedJSON()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusText = "Copied LLM naming template to the clipboard."
        } catch {
            statusText = "Could not copy LLM template: \(error.localizedDescription)"
        }
    }

    func pasteLLMTemplateFromClipboard() {
        guard !eyeSprites.isEmpty, !mouthSprites.isEmpty else {
            statusText = "Configure eyes and mouth atlases before pasting an LLM template."
            return
        }

        guard let text = NSPasteboard.general.string(forType: .string) else {
            statusText = AvatarExpressionLLMTemplateError.emptyClipboard.localizedDescription
            return
        }

        do {
            let template = try AvatarExpressionLLMTemplate.decode(from: text)
            let applied = try template.applying(to: eyeSprites, currentMouthSprites: mouthSprites)
            eyeSprites = applied.eyeSprites
            mouthSprites = applied.mouthSprites
            neutralEyeName = applied.neutralEyeName
            neutralMouthName = applied.neutralMouthName
            neutralBlinkFramesText = applied.neutralBlinkFramesText
            neutralBlinkFPS = applied.neutralBlinkFPS
            previewEyeName = applied.neutralEyeName
            previewMouthName = applied.neutralMouthName
            statusText = "Applied LLM naming template from the clipboard."
        } catch {
            statusText = error.localizedDescription
        }
    }
}

#endif
