#if os(macOS)
//
//  Avatar kit image-generation prompts and canonical sprite names.
//  Affective
//

import Foundation

nonisolated enum AvatarKitAssetKind: String, CaseIterable {
    case baseHead
    case eyesAtlas
    case mouthAtlas

    var assetFileName: String {
        switch self {
        case .baseHead: "head.png"
        case .eyesAtlas: "eyes.png"
        case .mouthAtlas: "mouth.png"
        }
    }

    var generateOnlyLine: String {
        switch self {
        case .baseHead:
            "Generate ONLY the BASE HEAD image described below. Do not include eye or mouth sprite atlases in this output."
        case .eyesAtlas:
            "Generate ONLY the EYE SPRITE ATLAS (4x4 grid, 16 sprites) described below. Do not include the base head or mouth atlas in this output."
        case .mouthAtlas:
            "Generate ONLY the MOUTH SPRITE ATLAS (4x4 grid, 16 sprites) described below. Do not include the base head or eye atlas in this output."
        }
    }

    var layerTitle: String {
        switch self {
        case .baseHead: "Base Head"
        case .eyesAtlas: "Eye Atlas"
        case .mouthAtlas: "Mouth Atlas"
        }
    }

    var generationStep: AvatarKitGenerationStep {
        switch self {
        case .baseHead: .generatingBaseHead
        case .eyesAtlas: .generatingEyesAtlas
        case .mouthAtlas: .generatingMouthAtlas
        }
    }

    var slotKind: AvatarSlot.Kind {
        switch self {
        case .baseHead: .head
        case .eyesAtlas: .eyes
        case .mouthAtlas: .mouth
        }
    }
}

extension AvatarKitAssetKind: Identifiable {
    var id: String { rawValue }
}

nonisolated enum AvatarKitCanonicalSprites {
    static let eyeNames: [String] = [
        "neutral_open",
        "soft_open",
        "happy_squint",
        "smiling_closed",
        "wide_surprised",
        "fear_wide",
        "sad_upturned",
        "worried_pinched",
        "angry_glare",
        "annoyed_half_lidded",
        "sleepy_half_lidded",
        "suspicious_side_eye",
        "look_left",
        "look_right",
        "look_down",
        "blink_closed",
    ]

    static let mouthNames: [String] = [
        "neutral_closed",
        "neutral_parted",
        "small_smile",
        "big_smile",
        "open_laugh",
        "smirk",
        "frown",
        "deep_frown",
        "pout",
        "grimace",
        "clenched_teeth",
        "small_o",
        "gape",
        "uneasy_parted",
        "sneer",
        "wobble",
    ]

    static let neutralEyeName = "neutral_open"
    static let neutralMouthName = "neutral_closed"
    static let atlasColumns = 4
    static let atlasRows = 4

    static func eyeSprites() -> [AvatarAtlasSprite] {
        namedSprites(names: eyeNames, prefix: "eyes")
    }

    static func mouthSprites() -> [AvatarAtlasSprite] {
        namedSprites(names: mouthNames, prefix: "mouth")
    }

    private static func namedSprites(names: [String], prefix: String) -> [AvatarAtlasSprite] {
        let columns = atlasColumns
        let rows = atlasRows
        precondition(names.count == columns * rows, "Expected \(columns * rows) sprite names for \(prefix)")
        return names.enumerated().map { index, name in
            AvatarAtlasSprite(
                frame: index,
                row: index / columns,
                column: index % columns,
                name: name
            )
        }
    }
}

nonisolated enum AvatarKitGenerationPrompt {
    static let characterBriefPlaceholder = "[USER CHARACTER PROMPT]"
    static let debugBackgroundHex = "#FF00FF"

    private static let masterTemplate = """
    Create a modular expressive avatar kit for a game character based on this character brief:

    \(characterBriefPlaceholder)

    Generate THREE separate images in the exact same art style and character design:

    1. BASE HEAD
    2. EYE SPRITE ATLAS (4x4 grid, 16 sprites)
    3. MOUTH SPRITE ATLAS (4x4 grid, 16 sprites)

    GENERAL REQUIREMENTS
    - The character must be front-facing, centered, and symmetrical enough to work as a reusable avatar.
    - Keep the art style consistent across all three outputs.
    - Make the design clean, readable, and game-ready.
    - The head should be suitable for overlay-based expression swapping.
    - Keep proportions, line weight, rendering style, colors, and lighting identical across all outputs.
    - Use a flat or mostly flat presentation with minimal perspective distortion.
    - Output a PNG with real alpha transparency. Background pixels must have alpha 0.
    - Do not paint a checkerboard, gray-and-white grid, transparency preview pattern, or any faux-transparency backdrop.
    - Do not bake any visible background into the image — only transparent pixels behind the artwork.
    - If true transparency is impossible, use flat chroma-key magenta only: RGB(255, 0, 255) / #FF00FF exactly (never checkerboard).
    - Do not add extra props, hands, body pose changes, or background scenery.
    - Absolutely no text, labels, captions, filenames, identifiers, watermarks, or sprite names anywhere in any image.

    BASE HEAD REQUIREMENTS
    - Show only the base head for the character.
    - Include the head shape, hair, ears if relevant, neck if needed, and any permanent facial features that should always remain visible.
    - Do NOT include swappable eye expressions or swappable mouth expressions baked into the base.
    - The base head should leave clean, consistent placement areas for the eye and mouth overlays.
    - If needed, include subtle neutral eye whites / sockets / mouth placement guides, but keep them minimal so the eye and mouth sprites can cleanly overlay.
    - Preserve all non-changing character traits from the brief.

    EYE ATLAS REQUIREMENTS
    - Create a single 4x4 sprite sheet containing 16 distinct eye expressions.
    - Every eye sprite must be aligned to the same position and scale so they can be swapped directly on the base head.
    - Each cell must contain only the drawn eye artwork on a transparent background — never text, labels, captions, numbers, or identifiers.
    - Keep all eyes consistent in size, angle, and placement.
    - Make the eye sprites expressive but readable at game resolution.
    - Arrange 16 distinct expressions left-to-right, top-to-bottom in this order:
      Row 1: neutral open, soft relaxed open, happy squint, smiling closed
      Row 2: wide surprised, fearful wide, sad upturned, worried pinched
      Row 3: angry glare, annoyed half-lidded, sleepy half-lidded, suspicious sideways glance
      Row 4: looking left, looking right, looking down, fully closed blink

    MOUTH ATLAS REQUIREMENTS
    - Create a single 4x4 sprite sheet containing 16 distinct mouth expressions.
    - Every mouth sprite must be aligned to the same position and scale so they can be swapped directly on the base head.
    - Each cell must contain only the drawn mouth artwork on a transparent background — never text, labels, captions, numbers, or identifiers.
    - Keep all mouths consistent in size, angle, and placement.
    - Make the mouth sprites expressive but readable at game resolution.
    - Arrange 16 distinct expressions left-to-right, top-to-bottom in this order:
      Row 1: neutral closed, neutral parted, small smile, big smile
      Row 2: open laugh, smirk, frown, deep frown
      Row 3: pout, grimace, clenched teeth, small O shape
      Row 4: wide gape, uneasy parted, sneer, wobble

    TECHNICAL / LAYOUT GOALS
    - Make the sprite atlases cleanly gridded and evenly spaced.
    - Ensure each sprite occupies its own cell with consistent margins.
    - Avoid cropping.
    - Keep the design optimized for a visual novel / dialogue portrait / expressive game avatar pipeline.
    - Prioritize clarity, consistency, and modularity over painterly complexity.

    IMPORTANT
    - These are modular parts for an expression system, so consistency is critical.
    - The base head, eyes, and mouths must clearly belong to the same character.
    - The eye and mouth atlases should be designed specifically to overlay onto the base head.
    """

    static func normalizedBrief(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AvatarKitGenerationError.emptyCharacterBrief
        }
        return trimmed
    }

    static func prompt(for kind: AvatarKitAssetKind, characterBrief: String) throws -> String {
        let brief = try normalizedBrief(characterBrief)
        let shared = masterTemplate.replacingOccurrences(of: characterBriefPlaceholder, with: brief)
        return """
        \(shared)

        OUTPUT FOR THIS REQUEST
        \(kind.generateOnlyLine)
        """
    }

    static func allPrompts(characterBrief: String) throws -> [AvatarKitAssetKind: String] {
        var prompts: [AvatarKitAssetKind: String] = [:]
        for kind in AvatarKitAssetKind.allCases {
            prompts[kind] = try prompt(for: kind, characterBrief: characterBrief)
        }
        return prompts
    }

    static func removeCheckerboardBackgroundPrompt(for kind: AvatarKitAssetKind) -> String {
        """
        The attached image was generated with a fake checkerboard transparency background baked into the pixels instead of real alpha transparency.

        Remove the checkerboard background completely. Output a PNG with genuine alpha transparency (alpha 0 behind the artwork).

        Requirements:
        - Do not repaint, recenter, or alter the character artwork, sprite layout, grid structure, or proportions.
        - Do not replace the checkerboard with another visible background, solid color, or faux-transparency pattern.
        - Preserve the exact same image content; only remove the checkerboard backdrop.
        - Absolutely no text, labels, captions, filenames, identifiers, watermarks, or sprite names anywhere in the image.

        OUTPUT FOR THIS REQUEST
        \(kind.generateOnlyLine)
        """
    }
}

#endif
