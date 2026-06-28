#if os(macOS)
//
//  Avatar expression sprite naming template for LLM copy/paste.
//  Affective
//

import Foundation

enum AvatarExpressionLLMTemplateError: LocalizedError {
    case emptyClipboard
    case invalidJSON(String)
    case missingEyeFrame(Int)
    case missingMouthFrame(Int)
    case emptySpriteName(String)
    case duplicateEyeName(String)
    case duplicateMouthName(String)
    case unknownNeutralEye(String)
    case unknownNeutralMouth(String)

    var errorDescription: String? {
        switch self {
        case .emptyClipboard:
            "Clipboard is empty."
        case .invalidJSON(let detail):
            "Could not parse LLM template JSON: \(detail)"
        case .missingEyeFrame(let frame):
            "Template is missing eye sprite frame \(frame)."
        case .missingMouthFrame(let frame):
            "Template is missing mouth sprite frame \(frame)."
        case .emptySpriteName(let kind):
            "Template has an empty \(kind) sprite name."
        case .duplicateEyeName(let name):
            "Template repeats eye sprite name \"\(name)\"."
        case .duplicateMouthName(let name):
            "Template repeats mouth sprite name \"\(name)\"."
        case .unknownNeutralEye(let name):
            "neutralPair.eyes \"\(name)\" is not in eyeSprites."
        case .unknownNeutralMouth(let name):
            "neutralPair.mouth \"\(name)\" is not in mouthSprites."
        }
    }
}

struct AvatarExpressionLLMTemplate: Codable, Equatable {
    struct NeutralPair: Codable, Equatable {
        var eyes: String
        var mouth: String
        var blinkFrames: String
        var blinkFPS: Double
    }

    struct SpriteEntry: Codable, Equatable {
        let frame: Int
        let row: Int
        let column: Int
        var name: String
    }

    let instructions: String
    var neutralPair: NeutralPair
    var eyeSprites: [SpriteEntry]
    var mouthSprites: [SpriteEntry]

    static let defaultInstructions =
        "Fill every \"name\" with a short snake_case sprite id (letters, numbers, underscores). " +
        "Eye and mouth names are independent. " +
        "neutralPair.eyes and neutralPair.mouth must match names from the tables below. " +
        "Keep frame, row, and column unchanged."

    static func makeTemplate(
        eyeSprites: [AvatarAtlasSprite],
        mouthSprites: [AvatarAtlasSprite],
        neutralEyeName: String,
        neutralMouthName: String,
        neutralBlinkFramesText: String,
        neutralBlinkFPS: Double,
        blankNames: Bool
    ) -> AvatarExpressionLLMTemplate {
        AvatarExpressionLLMTemplate(
            instructions: defaultInstructions,
            neutralPair: .init(
                eyes: blankNames ? "" : neutralEyeName,
                mouth: blankNames ? "" : neutralMouthName,
                blinkFrames: neutralBlinkFramesText,
                blinkFPS: neutralBlinkFPS
            ),
            eyeSprites: eyeSprites.map {
                .init(
                    frame: $0.frame,
                    row: $0.row,
                    column: $0.column,
                    name: blankNames ? "" : $0.name
                )
            },
            mouthSprites: mouthSprites.map {
                .init(
                    frame: $0.frame,
                    row: $0.row,
                    column: $0.column,
                    name: blankNames ? "" : $0.name
                )
            }
        )
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AvatarExpressionLLMTemplateError.invalidJSON("UTF-8 encoding failed.")
        }
        return text
    }

    static func decode(from text: String) throws -> AvatarExpressionLLMTemplate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AvatarExpressionLLMTemplateError.emptyClipboard
        }
        do {
            return try JSONDecoder().decode(AvatarExpressionLLMTemplate.self, from: Data(trimmed.utf8))
        } catch {
            throw AvatarExpressionLLMTemplateError.invalidJSON(error.localizedDescription)
        }
    }

    func applying(
        to currentEyeSprites: [AvatarAtlasSprite],
        currentMouthSprites: [AvatarAtlasSprite]
    ) throws -> (
        eyeSprites: [AvatarAtlasSprite],
        mouthSprites: [AvatarAtlasSprite],
        neutralEyeName: String,
        neutralMouthName: String,
        neutralBlinkFramesText: String,
        neutralBlinkFPS: Double
    ) {
        var updatedEyes = currentEyeSprites
        var updatedMouths = currentMouthSprites

        let eyeNames = try Self.namesByFrame(from: eyeSprites, kind: "eye")
        let mouthNames = try Self.namesByFrame(from: mouthSprites, kind: "mouth")

        for index in updatedEyes.indices {
            let frame = updatedEyes[index].frame
            guard let name = eyeNames[frame] else {
                throw AvatarExpressionLLMTemplateError.missingEyeFrame(frame)
            }
            updatedEyes[index].name = name
        }

        for index in updatedMouths.indices {
            let frame = updatedMouths[index].frame
            guard let name = mouthNames[frame] else {
                throw AvatarExpressionLLMTemplateError.missingMouthFrame(frame)
            }
            updatedMouths[index].name = name
        }

        let neutralEye = neutralPair.eyes.trimmingCharacters(in: .whitespacesAndNewlines)
        let neutralMouth = neutralPair.mouth.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !neutralEye.isEmpty else {
            throw AvatarExpressionLLMTemplateError.emptySpriteName("neutralPair.eyes")
        }
        guard !neutralMouth.isEmpty else {
            throw AvatarExpressionLLMTemplateError.emptySpriteName("neutralPair.mouth")
        }
        guard updatedEyes.contains(where: { $0.name == neutralEye }) else {
            throw AvatarExpressionLLMTemplateError.unknownNeutralEye(neutralEye)
        }
        guard updatedMouths.contains(where: { $0.name == neutralMouth }) else {
            throw AvatarExpressionLLMTemplateError.unknownNeutralMouth(neutralMouth)
        }

        return (
            updatedEyes,
            updatedMouths,
            neutralEye,
            neutralMouth,
            neutralPair.blinkFrames,
            neutralPair.blinkFPS
        )
    }

    private static func namesByFrame(from sprites: [SpriteEntry], kind: String) throws -> [Int: String] {
        var byFrame: [Int: String] = [:]
        for sprite in sprites {
            let name = sprite.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw AvatarExpressionLLMTemplateError.emptySpriteName("\(kind) frame \(sprite.frame)")
            }
            if byFrame.values.contains(name) {
                if kind == "eye" {
                    throw AvatarExpressionLLMTemplateError.duplicateEyeName(name)
                }
                throw AvatarExpressionLLMTemplateError.duplicateMouthName(name)
            }
            byFrame[sprite.frame] = name
        }
        return byFrame
    }
}

#endif
