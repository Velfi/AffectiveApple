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
    @Published var slots: [AvatarSlot] {
        didSet {
            sanitizeSelections()
        }
    }
    @Published var selectedSlotID: AvatarSlot.ID
    @Published var selectedAtlasSlotID: AvatarSlot.ID
    @Published var editorSection: AvatarEditorSection = .layout
    @Published var defaultExpressionID: String {
        didSet {
            sanitizeExpressionSelections()
        }
    }
    @Published var previewExpressionID: String {
        didSet {
            sanitizeExpressionSelections()
        }
    }
    @Published var expressions: [AvatarExpressionPreset] {
        didSet {
            sanitizeExpressionSelections()
        }
    }
    @Published var statusText = "Ready"

    init(brain: BrainDescriptor) {
        self.brain = brain
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
        let initialExpressions = Self.expressions(from: brain.avatarManifest, slots: initial.slots)
        expressions = initialExpressions.expressions
        defaultExpressionID = initialExpressions.defaultExpressionID
        previewExpressionID = initialExpressions.defaultExpressionID
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

    var selectedExpressionIndex: Int? {
        expressions.firstIndex { $0.id == previewExpressionID }
    }

    var atlasSlots: [AvatarSlot] {
        slots.filter(\.supportsAtlas)
    }

    var hasRenderableLayer: Bool {
        slots.contains { $0.isEnabled && $0.relativePath != nil }
    }

    var previewManifest: BrainAvatarManifest {
        BrainAvatarManifest(
            canvas: .init(width: canvasWidth, height: canvasHeight),
            clip: savedClipFrame,
            layers: slots.compactMap(\.manifestLayer),
            defaultExpression: defaultExpressionID,
            expressions: expressionManifests,
            rootURL: brain.rootURL
        )
    }

    var canvasPreviewManifest: BrainAvatarManifest {
        if editorSection == .atlases {
            return BrainAvatarManifest(
                canvas: .init(width: canvasWidth, height: canvasHeight),
                clip: savedClipFrame,
                layers: slots.compactMap(\.manifestLayer),
                rootURL: brain.rootURL
            )
        }
        return previewManifest
    }

    var canvasPreviewExpressionID: String? {
        editorSection == .atlases ? nil : previewExpressionID
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
        let initialExpressions = Self.expressions(from: brain.avatarManifest, slots: initial.slots)
        expressions = initialExpressions.expressions
        defaultExpressionID = initialExpressions.defaultExpressionID
        previewExpressionID = initialExpressions.defaultExpressionID
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
    }

    func setAsset(_ url: URL, for slotID: AvatarSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        let slot = slots[index]
        let relativePath = "avatar/\(slot.kind.assetFileName(for: url))"
        slots[index].sourceURL = url
        slots[index].relativePath = relativePath
        slots[index].isEnabled = true

        if let size = NSImage(contentsOf: url)?.pixelSize {
            if slot.kind == .background {
                canvasWidth = Double(size.width)
                canvasHeight = Double(size.height)
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

        for slot in slots {
            guard let sourceURL = slot.sourceURL, let relativePath = slot.relativePath else { continue }
            let destination = brain.rootURL.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: sourceURL, to: destination)
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

    func seedNeutralExpression() {
        guard let index = expressions.firstIndex(where: { $0.id == "neutral" }) else { return }
        expressions[index].eyesFrame = slot(kind: .eyes)?.selectedFrame ?? 0
        expressions[index].mouthFrame = slot(kind: .mouth)?.selectedFrame ?? 0
        expressions[index].blinkFramesText = defaultBlinkFramesText
        expressions[index].blinkFPS = slot(kind: .blink)?.fps ?? 12
        previewExpressionID = "neutral"
        statusText = "Seeded Neutral from the current atlas frames."
    }

    func moveClipFrame(x: Double, y: Double) {
        clipX = x
        clipY = y
        constrainClipFrame()
    }

    func scheduleClipFrameConstraint() {
        guard !isClipFrameConstraintScheduled else { return }
        isClipFrameConstraintScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClipFrameConstraintScheduled = false
            self.constrainClipFrame()
        }
    }

    func constrainClipFrame() {
        canvasWidth = normalizedDimension(canvasWidth, fallback: 1024)
        canvasHeight = normalizedDimension(canvasHeight, fallback: 1024)
        clipWidth = min(max(normalizedDimension(clipWidth, fallback: canvasWidth), 1), canvasWidth)
        clipHeight = min(max(normalizedDimension(clipHeight, fallback: canvasHeight), 1), canvasHeight)
        clipX = min(max(normalizedDimension(clipX, fallback: 0), 0), max(canvasWidth - clipWidth, 0))
        clipY = min(max(normalizedDimension(clipY, fallback: 0), 0), max(canvasHeight - clipHeight, 0))
    }

    func resetClipToCanvas() {
        clipX = 0
        clipY = 0
        clipWidth = normalizedDimension(canvasWidth, fallback: 1024)
        clipHeight = normalizedDimension(canvasHeight, fallback: 1024)
        statusText = "Clip frame now uses the full canvas."
    }

    func centerSquareClip() {
        canvasWidth = normalizedDimension(canvasWidth, fallback: 1024)
        canvasHeight = normalizedDimension(canvasHeight, fallback: 1024)
        let side = min(canvasWidth, canvasHeight)
        clipWidth = side
        clipHeight = side
        clipX = max((canvasWidth - side) / 2, 0)
        clipY = max((canvasHeight - side) / 2, 0)
        statusText = "Clip frame centered as a square."
    }

    func setClipAspect(width aspectWidth: Double, height aspectHeight: Double) {
        guard aspectWidth > 0, aspectHeight > 0 else { return }
        canvasWidth = normalizedDimension(canvasWidth, fallback: 1024)
        canvasHeight = normalizedDimension(canvasHeight, fallback: 1024)
        let canvasRatio = canvasWidth / canvasHeight
        let targetRatio = aspectWidth / aspectHeight
        if canvasRatio > targetRatio {
            clipHeight = canvasHeight
            clipWidth = canvasHeight * targetRatio
        } else {
            clipWidth = canvasWidth
            clipHeight = canvasWidth / targetRatio
        }
        clipX = max((canvasWidth - clipWidth) / 2, 0)
        clipY = max((canvasHeight - clipHeight) / 2, 0)
        constrainClipFrame()
        statusText = "Clip frame set to \(Int(aspectWidth)):\(Int(aspectHeight))."
    }

    func autodetectAtlas(slotID: AvatarSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }),
              slots[index].supportsAtlas,
              let url = assetURL(for: slots[index]),
              let size = NSImage(contentsOf: url)?.pixelSize
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
        slots[index].frames = detection.frames
        slots[index].selectedFrame = min(slots[index].selectedFrame, max(detection.frames - 1, 0))
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

        return (canvas, clip, slots)
    }

    var activeLayerResetSlotID: AvatarSlot.ID? {
        switch editorSection {
        case .layout:
            selectedSlotID
        case .atlases:
            selectedAtlasSlotID
        case .expressions, .clip:
            nil
        }
    }

    var savedClipFrame: BrainAvatarManifest.ClipFrame? {
        let canvasWidth = normalizedDimension(self.canvasWidth, fallback: 1024)
        let canvasHeight = normalizedDimension(self.canvasHeight, fallback: 1024)
        let clipWidth = normalizedDimension(self.clipWidth, fallback: canvasWidth)
        let clipHeight = normalizedDimension(self.clipHeight, fallback: canvasHeight)
        let clipX = normalizedDimension(self.clipX, fallback: 0)
        let clipY = normalizedDimension(self.clipY, fallback: 0)
        let normalized = BrainAvatarManifest.ClipFrame(
            x: min(max(clipX, 0), max(canvasWidth - max(clipWidth, 1), 0)),
            y: min(max(clipY, 0), max(canvasHeight - max(clipHeight, 1), 0)),
            width: min(max(clipWidth, 1), max(canvasWidth, 1)),
            height: min(max(clipHeight, 1), max(canvasHeight, 1))
        )
        let isFullCanvas = abs(normalized.x) < 0.0001
            && abs(normalized.y) < 0.0001
            && abs(normalized.width - canvasWidth) < 0.0001
            && abs(normalized.height - canvasHeight) < 0.0001
        return isFullCanvas ? nil : normalized
    }

    func normalizedDimension(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
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
        sanitizeExpressionSelections()
    }

    func sanitizeExpressionSelections() {
        guard !expressions.isEmpty else { return }
        let expressionIDs = Set(expressions.map(\.id))
        if !expressionIDs.contains(defaultExpressionID) {
            defaultExpressionID = expressions.first?.id ?? "neutral"
        }
        if !expressionIDs.contains(previewExpressionID) {
            previewExpressionID = defaultExpressionID
        }
    }

    static func defaultSlot(kind: AvatarSlot.Kind, from manifest: BrainAvatarManifest?) -> AvatarSlot {
        var slot = AvatarSlot(kind: kind)
        if let layer = manifest?.layers.first(where: { $0.id == kind.rawValue }) {
            slot.apply(layer, rootURL: manifest?.rootURL)
        }
        return slot
    }

    var expressionManifests: [BrainAvatarManifest.Expression] {
        expressions.map { expression in
            var layers: [String: BrainAvatarManifest.LayerOverride] = [
                AvatarSlot.Kind.eyes.rawValue: .init(frame: max(expression.eyesFrame, 0)),
                AvatarSlot.Kind.mouth.rawValue: .init(frame: max(expression.mouthFrame, 0)),
            ]
            let blinkFrames = expression.blinkFrames
            if !blinkFrames.isEmpty {
                layers[AvatarSlot.Kind.blink.rawValue] = .init(frames: blinkFrames, fps: max(expression.blinkFPS, 1))
            }
            return .init(id: expression.id, name: expression.name, layers: layers)
        }
    }

    static func expressions(
        from manifest: BrainAvatarManifest?,
        slots: [AvatarSlot]
    ) -> (defaultExpressionID: String, expressions: [AvatarExpressionPreset]) {
        let neutralEyes = slots.first { $0.kind == .eyes }?.selectedFrame ?? 0
        let neutralMouth = slots.first { $0.kind == .mouth }?.selectedFrame ?? 0
        let blinkFPS = slots.first { $0.kind == .blink }?.fps ?? 12
        var presets = AvatarExpressionPreset.defaults(
            neutralEyes: neutralEyes,
            neutralMouth: neutralMouth,
            blinkFPS: blinkFPS
        )

        for expression in manifest?.expressions ?? [] {
            guard let index = presets.firstIndex(where: { $0.id == expression.id }) else { continue }
            presets[index].apply(expression)
        }

        let defaultID = manifest?.defaultExpression
            ?? presets.first(where: { $0.id == "neutral" })?.id
            ?? presets[0].id
        return (defaultID, presets)
    }

    var defaultBlinkFramesText: String {
        if let blink = slot(kind: .blink), blink.frames > 1 {
            return (0..<blink.frames).map(String.init).joined(separator: ",")
        }
        return "0,1,2,1"
    }
}

#endif
