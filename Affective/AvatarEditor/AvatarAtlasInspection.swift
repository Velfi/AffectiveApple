#if os(macOS)
//
//  Vision inspection schema and mapping for generated avatar atlases.
//  Affective
//

import AppKit
import Foundation

nonisolated struct AvatarAtlasInspection: Codable, Equatable {
    struct Canvas: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct LayerPlacement: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct AtlasGrid: Codable, Equatable {
        var columns: Int
        var rows: Int
        var frameX: Double
        var frameY: Double
        var frameWidth: Double
        var frameHeight: Double
    }

    var canvas: Canvas
    var eyesLayer: LayerPlacement
    var mouthLayer: LayerPlacement
    var eyesAtlas: AtlasGrid
    var mouthAtlas: AtlasGrid
    var confidence: Double?
    var notes: String?

    static let visionPrompt = """
    You are inspecting a generated modular avatar kit with three images attached in order:
    1. base head
    2. eye sprite atlas (expected 4x4 grid, 16 sprites)
    3. mouth sprite atlas (expected 4x4 grid, 16 sprites)

    Return JSON describing how to compose these assets in a layered avatar editor.
    All coordinates are in pixels relative to the base head image origin (top-left).

    Requirements:
    - canvas.width and canvas.height must match the base head pixel size.
    - eyesLayer and mouthLayer describe where each atlas layer should be positioned on the canvas so sprites overlay correctly on the base head.
    - eyesAtlas and mouthAtlas describe the sprite sheet grid inside each atlas image (columns, rows, frame offsets, frame size).
    - Assume 4 columns and 4 rows for both atlases unless the image clearly shows a different evenly divided grid.
    - If backgrounds are solid debug magenta (#FF00FF), that is expected and will be keyed out automatically.
    - If text labels appear on atlas sprites, mention that in notes and lower confidence.
    - confidence is 0.0 to 1.0 for how reliable the detected layout is.
    """

    static let jsonSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["canvas", "eyesLayer", "mouthLayer", "eyesAtlas", "mouthAtlas"],
      "properties": {
        "canvas": {
          "type": "object",
          "additionalProperties": false,
          "required": ["width", "height"],
          "properties": {
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        },
        "eyesLayer": {
          "type": "object",
          "additionalProperties": false,
          "required": ["x", "y", "width", "height"],
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        },
        "mouthLayer": {
          "type": "object",
          "additionalProperties": false,
          "required": ["x", "y", "width", "height"],
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        },
        "eyesAtlas": {
          "type": "object",
          "additionalProperties": false,
          "required": ["columns", "rows", "frameX", "frameY", "frameWidth", "frameHeight"],
          "properties": {
            "columns": { "type": "integer" },
            "rows": { "type": "integer" },
            "frameX": { "type": "number" },
            "frameY": { "type": "number" },
            "frameWidth": { "type": "number" },
            "frameHeight": { "type": "number" }
          }
        },
        "mouthAtlas": {
          "type": "object",
          "additionalProperties": false,
          "required": ["columns", "rows", "frameX", "frameY", "frameWidth", "frameHeight"],
          "properties": {
            "columns": { "type": "integer" },
            "rows": { "type": "integer" },
            "frameX": { "type": "number" },
            "frameY": { "type": "number" },
            "frameWidth": { "type": "number" },
            "frameHeight": { "type": "number" }
          }
        },
        "confidence": { "type": "number" },
        "notes": { "type": "string" }
      }
    }
    """

    static func decode(from text: String) throws -> AvatarAtlasInspection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AvatarKitGenerationError.invalidInspectionJSON("Empty vision response.")
        }
        do {
            return try JSONDecoder().decode(AvatarAtlasInspection.self, from: Data(trimmed.utf8))
        } catch {
            throw AvatarKitGenerationError.invalidInspectionJSON(error.localizedDescription)
        }
    }

    func validated(
        headSize: CGSize,
        eyesImageSize: CGSize,
        mouthImageSize: CGSize
    ) throws -> AvatarAtlasInspection {
        guard canvas.width > 0, canvas.height > 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("Canvas dimensions must be positive.")
        }
        guard abs(canvas.width - headSize.width) <= 4, abs(canvas.height - headSize.height) <= 4 else {
            throw AvatarKitGenerationError.invalidInspectionJSON(
                "Canvas size \(Int(canvas.width))x\(Int(canvas.height)) does not match base head \(Int(headSize.width))x\(Int(headSize.height))."
            )
        }

        try validateLayer(eyesLayer, name: "eyesLayer", canvasWidth: canvas.width, canvasHeight: canvas.height)
        try validateLayer(mouthLayer, name: "mouthLayer", canvasWidth: canvas.width, canvasHeight: canvas.height)
        try validateAtlasGrid(eyesAtlas, imageSize: eyesImageSize, name: "eyesAtlas")
        try validateAtlasGrid(mouthAtlas, imageSize: mouthImageSize, name: "mouthAtlas")
        return self
    }

    private func validateLayer(
        _ layer: LayerPlacement,
        name: String,
        canvasWidth: Double,
        canvasHeight: Double
    ) throws {
        guard layer.width > 0, layer.height > 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) dimensions must be positive.")
        }
        guard layer.x >= 0, layer.y >= 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) origin must be non-negative.")
        }
        guard layer.x + layer.width <= canvasWidth + 1, layer.y + layer.height <= canvasHeight + 1 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) extends outside the canvas.")
        }
    }

    private func validateAtlasGrid(
        _ grid: AtlasGrid,
        imageSize: CGSize,
        name: String
    ) throws {
        guard grid.columns > 0, grid.rows > 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) columns and rows must be positive.")
        }
        guard grid.frameWidth > 0, grid.frameHeight > 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) frame size must be positive.")
        }
        guard grid.frameX >= 0, grid.frameY >= 0 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) frame offset must be non-negative.")
        }

        let usedWidth = grid.frameX + Double(grid.columns) * grid.frameWidth
        let usedHeight = grid.frameY + Double(grid.rows) * grid.frameHeight
        guard usedWidth <= imageSize.width + 1, usedHeight <= imageSize.height + 1 else {
            throw AvatarKitGenerationError.invalidInspectionJSON("\(name) grid exceeds atlas image bounds.")
        }
    }

    func apply(to slots: inout [AvatarSlot], headRelativePath: String, eyesRelativePath: String, mouthRelativePath: String) {
        applyStaticLayer(
            kind: .head,
            relativePath: headRelativePath,
            x: canvas.width / 2,
            y: canvas.height / 2,
            width: canvas.width,
            height: canvas.height,
            to: &slots
        )
        applyAtlasLayer(
            kind: .eyes,
            relativePath: eyesRelativePath,
            placement: eyesLayer,
            grid: eyesAtlas,
            to: &slots
        )
        applyAtlasLayer(
            kind: .mouth,
            relativePath: mouthRelativePath,
            placement: mouthLayer,
            grid: mouthAtlas,
            to: &slots
        )
    }

    private func applyStaticLayer(
        kind: AvatarSlot.Kind,
        relativePath: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        to slots: inout [AvatarSlot]
    ) {
        guard let index = slots.firstIndex(where: { $0.kind == kind }) else { return }
        slots[index].isEnabled = true
        slots[index].relativePath = relativePath
        slots[index].sourceURL = nil
        slots[index].usesAtlas = false
        slots[index].isAnimatedAtlas = false
        slots[index].x = x
        slots[index].y = y
        slots[index].width = width
        slots[index].height = height
    }

    private func applyAtlasLayer(
        kind: AvatarSlot.Kind,
        relativePath: String,
        placement: LayerPlacement,
        grid: AtlasGrid,
        to slots: inout [AvatarSlot]
    ) {
        guard let index = slots.firstIndex(where: { $0.kind == kind }) else { return }
        let frameCount = grid.columns * grid.rows
        slots[index].isEnabled = true
        slots[index].relativePath = relativePath
        slots[index].sourceURL = nil
        slots[index].usesAtlas = true
        slots[index].isAnimatedAtlas = false
        slots[index].x = placement.x + placement.width / 2
        slots[index].y = placement.y + placement.height / 2
        slots[index].width = placement.width
        slots[index].height = placement.height
        slots[index].columns = grid.columns
        slots[index].rows = grid.rows
        slots[index].frameX = grid.frameX
        slots[index].frameY = grid.frameY
        slots[index].frameWidth = grid.frameWidth
        slots[index].frameHeight = grid.frameHeight
        slots[index].frames = frameCount
        slots[index].selectedFrame = 0
    }

    static func fallbackFromDetection(
        headSize: CGSize,
        eyesImageSize: CGSize,
        mouthImageSize: CGSize
    ) throws -> AvatarAtlasInspection {
        guard let eyesDetection = SpriteAtlasDetection.detect(
            imageSize: eyesImageSize,
            columns: AvatarKitCanonicalSprites.atlasColumns,
            rows: AvatarKitCanonicalSprites.atlasRows
        ),
        let mouthDetection = SpriteAtlasDetection.detect(
            imageSize: mouthImageSize,
            columns: AvatarKitCanonicalSprites.atlasColumns,
            rows: AvatarKitCanonicalSprites.atlasRows
        )
        else {
            throw AvatarKitGenerationError.invalidInspectionJSON(
                "Autodetect could not find 4x4 grids in generated atlases."
            )
        }

        let canvasWidth = Double(headSize.width)
        let canvasHeight = Double(headSize.height)
        let eyesWidth = Double(eyesImageSize.width)
        let eyesHeight = Double(eyesImageSize.height)
        let mouthWidth = Double(mouthImageSize.width)
        let mouthHeight = Double(mouthImageSize.height)

        return AvatarAtlasInspection(
            canvas: .init(width: canvasWidth, height: canvasHeight),
            eyesLayer: .init(
                x: max((canvasWidth - eyesWidth) / 2, 0),
                y: max((canvasHeight - eyesHeight) / 2, 0),
                width: eyesWidth,
                height: eyesHeight
            ),
            mouthLayer: .init(
                x: max((canvasWidth - mouthWidth) / 2, 0),
                y: max((canvasHeight - mouthHeight) / 2, 0),
                width: mouthWidth,
                height: mouthHeight
            ),
            eyesAtlas: .init(
                columns: eyesDetection.columns,
                rows: eyesDetection.rows,
                frameX: eyesDetection.frameX,
                frameY: eyesDetection.frameY,
                frameWidth: eyesDetection.frameWidth,
                frameHeight: eyesDetection.frameHeight
            ),
            mouthAtlas: .init(
                columns: mouthDetection.columns,
                rows: mouthDetection.rows,
                frameX: mouthDetection.frameX,
                frameY: mouthDetection.frameY,
                frameWidth: mouthDetection.frameWidth,
                frameHeight: mouthDetection.frameHeight
            ),
            confidence: nil,
            notes: "Layout recovered via autodetect fallback."
        )
    }
}

nonisolated enum AvatarKitGenerationError: LocalizedError, Equatable {
    case emptyCharacterBrief
    case missingGoogleCredential
    case missingVisionCredential
    case generationFailed(String)
    case inspectionFailed(String)
    case invalidInspectionJSON(String)
    case missingGeneratedImage(String)
    case invalidImageSize(String)
    case chromaKeyFailed(String)
    case opaqueBackgroundRemaining(String)

    var errorDescription: String? {
        switch self {
        case .emptyCharacterBrief:
            "Enter a character brief before generating an avatar kit."
        case .missingGoogleCredential:
            "Configure a Google API key in Settings before generating avatar images."
        case .missingVisionCredential:
            "Configure an OpenAI, Anthropic, Google, or DeepSeek API key in Settings before inspecting generated atlases."
        case .generationFailed(let detail):
            "Image generation failed: \(detail)"
        case .inspectionFailed(let detail):
            "Atlas inspection failed: \(detail)"
        case .invalidInspectionJSON(let detail):
            "Invalid atlas inspection JSON: \(detail)"
        case .missingGeneratedImage(let asset):
            "Generated image missing for \(asset)."
        case .invalidImageSize(let detail):
            "Could not read generated image size: \(detail)"
        case .chromaKeyFailed(let detail):
            "Could not remove debug background: \(detail)"
        case .opaqueBackgroundRemaining(let asset):
            "Generated \(asset) has no real transparency after checkerboard removal. Regenerate or use a solid key-color background."
        }
    }
}

#endif
