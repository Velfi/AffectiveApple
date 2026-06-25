#if os(macOS)
//
//  Split from AvatarEditorView.swift
//  Affective
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AvatarEditorSection: String, CaseIterable, Identifiable {
    case layout
    case atlases
    case expressions
    case clip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: "Layout"
        case .atlases: "Atlases"
        case .expressions: "Expressions"
        case .clip: "Clip"
        }
    }

    var systemImage: String {
        switch self {
        case .layout: "square.on.square"
        case .atlases: "rectangle.grid.3x2"
        case .expressions: "face.smiling"
        case .clip: "crop"
        }
    }

    var sidebarWidth: Double {
        switch self {
        case .expressions:
            620
        case .layout, .atlases, .clip:
            380
        }
    }
}

struct AvatarExpressionPreset: Identifiable, Equatable {
    let id: String
    var name: String
    var eyesFrame: Int
    var mouthFrame: Int
    var blinkFramesText: String
    var blinkFPS: Double

    var blinkFrames: [Int] {
        blinkFramesText
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 >= 0 }
    }

    mutating func apply(_ expression: BrainAvatarManifest.Expression) {
        name = expression.name
        if let eyes = expression.layers[AvatarSlot.Kind.eyes.rawValue]?.frame {
            eyesFrame = eyes
        }
        if let mouth = expression.layers[AvatarSlot.Kind.mouth.rawValue]?.frame {
            mouthFrame = mouth
        }
        if let blink = expression.layers[AvatarSlot.Kind.blink.rawValue] {
            if let frames = blink.frames, !frames.isEmpty {
                blinkFramesText = frames.map(String.init).joined(separator: ",")
            }
            if let fps = blink.fps {
                blinkFPS = fps
            }
        }
    }

    static func defaults(neutralEyes: Int, neutralMouth: Int, blinkFPS: Double) -> [AvatarExpressionPreset] {
        [
            .init(id: "neutral", name: "Neutral", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "happy", name: "Happy", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "thinking", name: "Thinking", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "surprised", name: "Surprised", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "concerned", name: "Concerned", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "laughing", name: "Laughing", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "speaking", name: "Speaking", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
            .init(id: "sleepy", name: "Sleepy", eyesFrame: neutralEyes, mouthFrame: neutralMouth, blinkFramesText: "0,1,2,1", blinkFPS: blinkFPS),
        ]
    }
}

struct SpriteAtlasDetection {
    let columns: Int
    let rows: Int
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double

    var frames: Int {
        columns * rows
    }

    static func detect(imageSize: CGSize, kind: AvatarSlot.Kind, current: AvatarSlot) -> SpriteAtlasDetection {
        let width = max(Int(imageSize.width), 1)
        let height = max(Int(imageSize.height), 1)
        if let constrained = constrainedDetection(width: width, height: height, current: current) {
            return constrained
        }

        var best = SpriteAtlasDetection(
            columns: 1,
            rows: 1,
            frameX: 0,
            frameY: 0,
            frameWidth: Double(width),
            frameHeight: Double(height)
        )
        var bestScore = Double.greatestFiniteMagnitude

        for columns in 1...8 {
            guard width.isMultiple(of: columns) else { continue }
            for rows in 1...8 {
                guard height.isMultiple(of: rows), columns * rows > 1 else { continue }
                let frameWidth = width / columns
                let frameHeight = height / rows
                let ratioScore = abs(log(Double(frameWidth) / Double(frameHeight)))
                let countScore = preferredCountScore(columns * rows, kind: kind)
                let shapeScore = columns >= rows ? 0 : 0.35
                let score = ratioScore + countScore + shapeScore
                if score < bestScore {
                    bestScore = score
                    best = SpriteAtlasDetection(
                        columns: columns,
                        rows: rows,
                        frameX: 0,
                        frameY: 0,
                        frameWidth: Double(frameWidth),
                        frameHeight: Double(frameHeight)
                    )
                }
            }
        }

        return best
    }

    static func constrainedDetection(width: Int, height: Int, current: AvatarSlot) -> SpriteAtlasDetection? {
        if current.columns > 1 || current.rows > 1 {
            let columns = max(current.columns, 1)
            let rows = max(current.rows, 1)

            let manualFrameWidth = max(Int(current.frameWidth.rounded()), 1)
            let manualFrameHeight = max(Int(current.frameHeight.rounded()), 1)
            let frameWidth = manualFrameWidth * columns <= width
                ? manualFrameWidth
                : (width.isMultiple(of: columns) ? width / columns : 0)
            let frameHeight = manualFrameHeight * rows <= height
                ? manualFrameHeight
                : (height.isMultiple(of: rows) ? height / rows : 0)

            guard frameWidth > 0, frameHeight > 0 else {
                return nil
            }
            let frameX = centeredOffset(imageSize: width, frameSize: frameWidth, count: columns, currentOffset: current.frameX)
            let frameY = centeredOffset(imageSize: height, frameSize: frameHeight, count: rows, currentOffset: current.frameY)
            return SpriteAtlasDetection(
                columns: columns,
                rows: rows,
                frameX: Double(frameX),
                frameY: Double(frameY),
                frameWidth: Double(frameWidth),
                frameHeight: Double(frameHeight)
            )
        }

        let frameWidth = max(Int(current.frameWidth.rounded()), 1)
        let frameHeight = max(Int(current.frameHeight.rounded()), 1)
        guard
            frameWidth < width || frameHeight < height,
            frameWidth < width || frameHeight < height
        else {
            return nil
        }

        let columns = max(current.columns, width / frameWidth)
        let rows = max(current.rows, height / frameHeight)
        guard columns * rows > 1 else {
            return nil
        }
        let frameX = centeredOffset(imageSize: width, frameSize: frameWidth, count: columns, currentOffset: current.frameX)
        let frameY = centeredOffset(imageSize: height, frameSize: frameHeight, count: rows, currentOffset: current.frameY)
        return SpriteAtlasDetection(
            columns: columns,
            rows: rows,
            frameX: Double(frameX),
            frameY: Double(frameY),
            frameWidth: Double(frameWidth),
            frameHeight: Double(frameHeight)
        )
    }

    static func centeredOffset(imageSize: Int, frameSize: Int, count: Int, currentOffset: Double) -> Int {
        let current = max(Int(currentOffset.rounded()), 0)
        if current > 0 {
            return current
        }
        return max((imageSize - frameSize * count) / 2, 0)
    }

    static func preferredCountScore(_ count: Int, kind: AvatarSlot.Kind) -> Double {
        switch kind {
        case .eyes, .mouth:
            if count == 12 { return -0.8 }
            if count == 8 || count == 16 { return -0.2 }
            return Double(abs(count - 12)) * 0.08
        case .blink:
            if count == 4 || count == 8 { return -0.5 }
            return Double(abs(count - 6)) * 0.08
        case .background, .head, .hair:
            return 0
        }
    }
}

struct AvatarSlot: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case background
        case head
        case eyes
        case mouth
        case blink
        case hair

        var title: String {
            switch self {
            case .background: "Background"
            case .head: "Base Head"
            case .eyes: "Eyes"
            case .mouth: "Mouth"
            case .blink: "Blink Atlas"
            case .hair: "Hair"
            }
        }

        var systemImage: String {
            switch self {
            case .background: "rectangle.fill"
            case .head: "person.crop.circle"
            case .eyes: "eye"
            case .mouth: "mouth"
            case .blink: "eye.trianglebadge.exclamationmark"
            case .hair: "person.crop.circle.badge"
            }
        }

        var z: Int {
            switch self {
            case .background: 0
            case .head: 10
            case .eyes: 20
            case .blink: 21
            case .mouth: 30
            case .hair: 40
            }
        }

        var supportsAtlas: Bool {
            switch self {
            case .eyes, .mouth, .blink:
                true
            case .background, .head, .hair:
                false
            }
        }

        var defaultsToAtlas: Bool {
            self == .blink
        }

        var defaultsToAnimatedAtlas: Bool {
            self == .blink
        }

        var supportsAnimationToggle: Bool {
            self == .blink
        }

        func assetFileName(for url: URL) -> String {
            let fileExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            return "\(rawValue).\(fileExtension)"
        }
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var isEnabled = true
    var relativePath: String?
    var sourceURL: URL?
    var x: Double = 0
    var y: Double = 0
    var width: Double = 512
    var height: Double = 512
    var usesAtlas: Bool
    var isAnimatedAtlas: Bool
    var columns = 1
    var rows = 1
    var frameX: Double = 0
    var frameY: Double = 0
    var frameWidth: Double = 512
    var frameHeight: Double = 512
    var frames = 1
    var selectedFrame = 0
    var fps: Double = 8

    var title: String { kind.title }
    var systemImage: String { kind.systemImage }
    var supportsAtlas: Bool { kind.supportsAtlas }
    var supportsAnimationToggle: Bool { kind.supportsAnimationToggle }

    var manifestLayer: BrainAvatarManifest.Layer? {
        guard isEnabled, let relativePath else { return nil }
        return BrainAvatarManifest.Layer(
            id: id,
            name: title,
            image: usesAtlas ? nil : relativePath,
            atlas: usesAtlas ? relativePath : nil,
            x: x,
            y: y,
            width: width,
            height: height,
            z: kind.z,
            frameX: usesAtlas ? frameX : nil,
            frameY: usesAtlas ? frameY : nil,
            frameWidth: usesAtlas ? frameWidth : nil,
            frameHeight: usesAtlas ? frameHeight : nil,
            frames: usesAtlas ? max(frames, 1) : nil,
            frame: usesAtlas && !isAnimatedAtlas ? clampedSelectedFrame : nil,
            fps: usesAtlas && isAnimatedAtlas ? max(fps, 1) : nil,
            opacity: nil
        )
    }

    init(kind: Kind) {
        self.kind = kind
        usesAtlas = kind.defaultsToAtlas
        isAnimatedAtlas = kind.defaultsToAnimatedAtlas
    }

    mutating func apply(_ layer: BrainAvatarManifest.Layer, rootURL: URL? = nil) {
        isEnabled = true
        relativePath = layer.image ?? layer.atlas
        sourceURL = nil
        usesAtlas = layer.atlas != nil
        isAnimatedAtlas = layer.atlas != nil && layer.fps != nil && layer.frame == nil
        x = layer.x
        y = layer.y
        width = layer.width
        height = layer.height
        frameX = layer.frameX ?? 0
        frameY = layer.frameY ?? 0
        frameWidth = layer.frameWidth ?? layer.width
        frameHeight = layer.frameHeight ?? layer.height
        frames = layer.frames ?? 1
        let atlasWidth = layer.atlas
            .flatMap { atlasPath in rootURL.map { $0.appendingPathComponent(atlasPath) } }
            .flatMap { NSImage(contentsOf: $0)?.pixelSize?.width }
        let inferredWidth = atlasWidth ?? layer.width
        let inferredColumns = Int(((inferredWidth - max(frameX, 0)) / max(frameWidth, 1)).rounded(.down))
        columns = max(inferredColumns, 1)
        rows = max(Int(ceil(Double(max(frames, 1)) / Double(columns))), 1)
        selectedFrame = layer.frame ?? 0
        fps = layer.fps ?? 8
    }

    var clampedSelectedFrame: Int {
        min(max(selectedFrame, 0), max(frames - 1, 0))
    }
}

#endif
