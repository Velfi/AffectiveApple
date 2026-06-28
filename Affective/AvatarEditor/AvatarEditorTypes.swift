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
    case generate
    case layout
    case atlases
    case expressions
    case clip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generate: "Generate"
        case .layout: "Layout"
        case .atlases: "Atlases"
        case .expressions: "Expressions"
        case .clip: "Clip"
        }
    }

    var systemImage: String {
        switch self {
        case .generate: "sparkles"
        case .layout: "square.on.square"
        case .atlases: "rectangle.grid.3x2"
        case .expressions: "face.smiling"
        case .clip: "crop"
        }
    }

    var sidebarWidth: Double {
        switch self {
        case .expressions:
            560
        case .generate:
            420
        case .layout, .atlases, .clip:
            380
        }
    }
}

enum ClipAspectMode: Equatable {
    case free
    case locked(width: Double, height: Double)

    var ratio: Double? {
        switch self {
        case .free:
            return nil
        case .locked(let width, let height):
            guard width > 0, height > 0 else { return nil }
            return width / height
        }
    }

    var label: String {
        switch self {
        case .free:
            "Free"
        case .locked(let width, let height):
            "\(Int(width)):\(Int(height))"
        }
    }
}

typealias AvatarAtlasSprite = BrainAvatarManifest.AtlasSprite

nonisolated struct SpriteAtlasDetection {
    let columns: Int
    let rows: Int
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double

    var frames: Int {
        columns * rows
    }

    static func detect(imageSize: CGSize, columns: Int, rows: Int) -> SpriteAtlasDetection? {
        let width = max(Int(imageSize.width), 1)
        let height = max(Int(imageSize.height), 1)
        guard columns > 0, rows > 0,
              width.isMultiple(of: columns),
              height.isMultiple(of: rows) else {
            return nil
        }
        let frameWidth = width / columns
        let frameHeight = height / rows
        return SpriteAtlasDetection(
            columns: columns,
            rows: rows,
            frameX: 0,
            frameY: 0,
            frameWidth: Double(frameWidth),
            frameHeight: Double(frameHeight)
        )
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
        let maxGrid = maxGridDimension(width: width, height: height)

        for columns in 1...maxGrid {
            guard width.isMultiple(of: columns) else { continue }
            for rows in 1...maxGrid {
                guard height.isMultiple(of: rows), columns * rows > 1 else { continue }
                let frameWidth = width / columns
                let frameHeight = height / rows
                let ratioScore = abs(log(Double(frameWidth) / Double(frameHeight)))
                let shapeScore = columns >= rows ? 0 : 0.35
                let score = ratioScore + shapeScore
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

    static func maxGridDimension(width: Int, height: Int) -> Int {
        let minFrame = 16
        let fromWidth = max(width / minFrame, 1)
        let fromHeight = max(height / minFrame, 1)
        return min(max(fromWidth, fromHeight), 32)
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
            false
        }

        var defaultsToAnimatedAtlas: Bool {
            false
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
    var x: Double = 256
    var y: Double = 256
    var width: Double = 512
    var height: Double = 512
    var anchor: BrainAvatarManifest.LayerAnchor = .center
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
    var backgroundColor: Color?
    var isBackgroundTransparent = false

    var title: String { kind.title }
    var systemImage: String { kind.systemImage }
    var supportsAtlas: Bool { kind.supportsAtlas }
    var supportsAnimationToggle: Bool { kind.supportsAnimationToggle }

    var effectiveFrameCount: Int {
        max(columns * rows, 1)
    }

    func topLeftOrigin() -> (x: Double, y: Double) {
        (x - width / 2, y - height / 2)
    }

    mutating func syncAtlasGrid() {
        frames = effectiveFrameCount
        selectedFrame = min(max(selectedFrame, 0), max(frames - 1, 0))
    }

    var hasRenderableContent: Bool {
        if relativePath != nil {
            return true
        }
        if kind == .background {
            return backgroundColor != nil || isBackgroundTransparent
        }
        return false
    }

    var manifestLayer: BrainAvatarManifest.Layer? {
        guard isEnabled else { return nil }

        if kind == .background, relativePath == nil {
            guard backgroundColor != nil || isBackgroundTransparent else { return nil }
            return BrainAvatarManifest.Layer(
                id: id,
                name: title,
                image: nil,
                atlas: nil,
                x: x,
                y: y,
                width: width,
                height: height,
                z: kind.z,
                color: isBackgroundTransparent ? nil : backgroundColor?.avatarHexString,
                anchor: .center
            )
        }

        guard let relativePath else { return nil }
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
            frames: usesAtlas ? effectiveFrameCount : nil,
            frame: usesAtlas && !isAnimatedAtlas ? clampedSelectedFrame : nil,
            fps: usesAtlas && isAnimatedAtlas ? max(fps, 1) : nil,
            opacity: nil,
            anchor: .center
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
        width = layer.width
        height = layer.height

        switch layer.resolvedAnchor {
        case .topLeading:
            x = layer.x + layer.width / 2
            y = layer.y + layer.height / 2
        case .center:
            x = layer.x
            y = layer.y
        }
        anchor = .center

        if kind == .background {
            if let colorHex = layer.color {
                backgroundColor = Color.avatarColor(fromHex: colorHex)
                isBackgroundTransparent = false
            } else if layer.image == nil {
                isBackgroundTransparent = true
                backgroundColor = nil
            }
        }

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
        syncAtlasGrid()
        selectedFrame = layer.frame ?? 0
        fps = layer.fps ?? 8
    }

    var clampedSelectedFrame: Int {
        min(max(selectedFrame, 0), max(frames - 1, 0))
    }
}

#endif
