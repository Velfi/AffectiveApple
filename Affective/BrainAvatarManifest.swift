//
//  Split from BrainLibrary.swift
//  Affective
//

import Foundation

nonisolated struct BrainAvatarManifest: Codable, Equatable {
    struct Canvas: Codable, Equatable {
        let width: Double
        let height: Double
    }

    struct ClipFrame: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    struct Expression: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let layers: [String: LayerOverride]

        init(id: String, name: String, layers: [String: LayerOverride] = [:]) {
            self.id = id
            self.name = name
            self.layers = layers
        }
    }

    struct LayerOverride: Codable, Equatable {
        let frame: Int?
        let sprite: String?
        let frames: [Int]?
        let fps: Double?

        init(frame: Int? = nil, sprite: String? = nil, frames: [Int]? = nil, fps: Double? = nil) {
            self.frame = frame
            self.sprite = sprite
            self.frames = frames
            self.fps = fps
        }
    }

    struct AtlasSprite: Codable, Equatable, Identifiable {
        let frame: Int
        let row: Int
        let column: Int
        var name: String

        var id: Int { frame }
    }

    struct AtlasPlayback: Equatable {
        let frame: Int?
        let frames: [Int]?
        let fps: Double?

        var isAnimated: Bool {
            (frames?.isEmpty == false) && fps != nil
        }

        func frameIndex(at date: Date) -> Int {
            guard let frames, !frames.isEmpty, let fps else {
                return max(frame ?? 0, 0)
            }
            let index = Int(date.timeIntervalSinceReferenceDate * max(fps, 1)) % frames.count
            return max(frames[index], 0)
        }
    }

    struct AtlasFrameOrigin: Equatable {
        let x: Int
        let y: Int
    }

    enum LayerAnchor: String, Codable, Equatable {
        case topLeading
        case center
    }

    struct Layer: Codable, Identifiable, Equatable {
        var id: String
        let name: String?
        let image: String?
        let atlas: String?
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let z: Int
        let frameX: Double?
        let frameY: Double?
        let frameWidth: Double?
        let frameHeight: Double?
        let frames: Int?
        let frame: Int?
        let fps: Double?
        let opacity: Double?
        let color: String?
        let anchor: LayerAnchor?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case image
            case atlas
            case x
            case y
            case width
            case height
            case z
            case frameX
            case frameY
            case frameWidth
            case frameHeight
            case frames
            case frame
            case fps
            case opacity
            case color
            case anchor
        }

        init(
            id: String,
            name: String? = nil,
            image: String? = nil,
            atlas: String? = nil,
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            z: Int,
            frameX: Double? = nil,
            frameY: Double? = nil,
            frameWidth: Double? = nil,
            frameHeight: Double? = nil,
            frames: Int? = nil,
            frame: Int? = nil,
            fps: Double? = nil,
            opacity: Double? = nil,
            color: String? = nil,
            anchor: LayerAnchor? = nil
        ) {
            self.id = id
            self.name = name
            self.image = image
            self.atlas = atlas
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.z = z
            self.frameX = frameX
            self.frameY = frameY
            self.frameWidth = frameWidth
            self.frameHeight = frameHeight
            self.frames = frames
            self.frame = frame
            self.fps = fps
            self.opacity = opacity
            self.color = color
            self.anchor = anchor
        }

        var resolvedAnchor: LayerAnchor {
            anchor ?? .topLeading
        }

        func topLeftOrigin() -> (x: Double, y: Double) {
            switch resolvedAnchor {
            case .topLeading:
                (x, y)
            case .center:
                (x - width / 2, y - height / 2)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            image = try container.decodeIfPresent(String.self, forKey: .image)
            atlas = try container.decodeIfPresent(String.self, forKey: .atlas)
            x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
            y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
            width = try container.decode(Double.self, forKey: .width)
            height = try container.decode(Double.self, forKey: .height)
            z = try container.decodeIfPresent(Int.self, forKey: .z) ?? 0
            frameX = try container.decodeIfPresent(Double.self, forKey: .frameX)
            frameY = try container.decodeIfPresent(Double.self, forKey: .frameY)
            frameWidth = try container.decodeIfPresent(Double.self, forKey: .frameWidth)
            frameHeight = try container.decodeIfPresent(Double.self, forKey: .frameHeight)
            frames = try container.decodeIfPresent(Int.self, forKey: .frames)
            frame = try container.decodeIfPresent(Int.self, forKey: .frame)
            fps = try container.decodeIfPresent(Double.self, forKey: .fps)
            opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
            color = try container.decodeIfPresent(String.self, forKey: .color)
            anchor = try container.decodeIfPresent(LayerAnchor.self, forKey: .anchor)
            id = try container.decodeIfPresent(String.self, forKey: .id)
                ?? name
                ?? image
                ?? atlas
                ?? UUID().uuidString
        }
    }

    let canvas: Canvas
    let clip: ClipFrame?
    let layers: [Layer]
    let eyeSprites: [AtlasSprite]
    let mouthSprites: [AtlasSprite]
    let defaultExpression: String?
    let expressions: [Expression]
    let rootURL: URL

    enum CodingKeys: String, CodingKey {
        case canvas
        case clip
        case layers
        case eyeSprites
        case mouthSprites
        case defaultExpression
        case expressions
    }

    init(
        canvas: Canvas,
        clip: ClipFrame? = nil,
        layers: [Layer],
        eyeSprites: [AtlasSprite] = [],
        mouthSprites: [AtlasSprite] = [],
        defaultExpression: String? = nil,
        expressions: [Expression] = [],
        rootURL: URL
    ) {
        self.canvas = canvas
        self.clip = clip
        self.layers = layers.sorted { $0.z < $1.z }
        self.eyeSprites = eyeSprites
        self.mouthSprites = mouthSprites
        self.defaultExpression = defaultExpression
        self.expressions = expressions
        self.rootURL = rootURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvas = try container.decode(Canvas.self, forKey: .canvas)
        clip = try container.decodeIfPresent(ClipFrame.self, forKey: .clip)
        layers = try container.decode([Layer].self, forKey: .layers).sorted { $0.z < $1.z }
        eyeSprites = try container.decodeIfPresent([AtlasSprite].self, forKey: .eyeSprites) ?? []
        mouthSprites = try container.decodeIfPresent([AtlasSprite].self, forKey: .mouthSprites) ?? []
        defaultExpression = try container.decodeIfPresent(String.self, forKey: .defaultExpression)
        expressions = try container.decodeIfPresent([Expression].self, forKey: .expressions) ?? []
        rootURL = URL(fileURLWithPath: "/")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvas, forKey: .canvas)
        try container.encodeIfPresent(clip, forKey: .clip)
        try container.encode(layers.sorted { $0.z < $1.z }, forKey: .layers)
        if !eyeSprites.isEmpty {
            try container.encode(eyeSprites, forKey: .eyeSprites)
        }
        if !mouthSprites.isEmpty {
            try container.encode(mouthSprites, forKey: .mouthSprites)
        }
        try container.encodeIfPresent(defaultExpression, forKey: .defaultExpression)
        if !expressions.isEmpty {
            try container.encode(expressions, forKey: .expressions)
        }
    }

    static func load(from url: URL, relativeTo rootURL: URL) throws -> BrainAvatarManifest {
        struct Payload: Decodable {
            let canvas: Canvas
            let clip: ClipFrame?
            let layers: [Layer]
            let eyeSprites: [AtlasSprite]?
            let mouthSprites: [AtlasSprite]?
            let defaultExpression: String?
            let expressions: [Expression]?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        return BrainAvatarManifest(
            canvas: payload.canvas,
            clip: payload.clip,
            layers: payload.layers,
            eyeSprites: payload.eyeSprites ?? [],
            mouthSprites: payload.mouthSprites ?? [],
            defaultExpression: payload.defaultExpression,
            expressions: payload.expressions ?? [],
            rootURL: rootURL
        )
    }

    var effectiveClip: ClipFrame {
        let canvasWidth = max(canvas.width.isFinite ? canvas.width : 1, 1)
        let canvasHeight = max(canvas.height.isFinite ? canvas.height : 1, 1)
        guard let clip else {
            return ClipFrame(width: canvasWidth, height: canvasHeight)
        }
        return ClipFrame(
            x: clip.x.isFinite ? clip.x : 0,
            y: clip.y.isFinite ? clip.y : 0,
            width: max(1, clip.width.isFinite ? clip.width : canvasWidth),
            height: max(1, clip.height.isFinite ? clip.height : canvasHeight)
        )
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func url(for path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    func expression(id expressionID: String?) -> Expression? {
        if let expressionID, let expression = expressions.first(where: { $0.id == expressionID }) {
            return expression
        }
        if let defaultExpression, let expression = expressions.first(where: { $0.id == defaultExpression }) {
            return expression
        }
        return expressions.first
    }

    func eyeFrame(named name: String) -> Int? {
        eyeSprites.first(where: { $0.name == name })?.frame
    }

    func mouthFrame(named name: String) -> Int? {
        mouthSprites.first(where: { $0.name == name })?.frame
    }

    var availableEyeSpriteNames: [String] {
        eyeSprites.map(\.name)
    }

    var availableMouthSpriteNames: [String] {
        mouthSprites.map(\.name)
    }

    static func syncedSprites(
        existing: [AtlasSprite],
        columns: Int,
        rows: Int,
        prefix: String
    ) -> [AtlasSprite] {
        let safeColumns = max(columns, 1)
        let safeRows = max(rows, 1)
        let frameCount = safeColumns * safeRows
        let byFrame = Dictionary(uniqueKeysWithValues: existing.map { ($0.frame, $0) })
        return (0..<frameCount).map { frame in
            let row = frame / safeColumns
            let column = frame % safeColumns
            if let sprite = byFrame[frame] {
                return AtlasSprite(frame: frame, row: row, column: column, name: sprite.name)
            }
            return AtlasSprite(frame: frame, row: row, column: column, name: "\(prefix)_\(frame)")
        }
    }

    func blinkExpressionID() -> String? {
        if expression(id: "neutral") != nil {
            return "neutral"
        }
        if let defaultExpression, expression(id: defaultExpression) != nil {
            return defaultExpression
        }
        return expressions.first?.id
    }

    func hasSeparateBlinkLayer() -> Bool {
        layers.contains { $0.id == "blink" && $0.atlas != nil }
    }

    func blinkTargetLayerID(expressionID: String? = nil) -> String? {
        if hasSeparateBlinkLayer() {
            return "blink"
        }
        if resolvedEyeBlinkPlayback(expressionID: expressionID ?? blinkExpressionID()) != nil {
            return "eyes"
        }
        return nil
    }

    func resolvedEyeBlinkPlayback(expressionID: String?) -> AtlasPlayback? {
        guard !hasSeparateBlinkLayer(), let expression = expression(id: expressionID) else { return nil }

        if let override = expression.layers["eyes"],
           let frames = override.frames,
           !frames.isEmpty,
           let fps = override.fps {
            return AtlasPlayback(frame: nil, frames: frames, fps: fps)
        }

        if let override = expression.layers["blink"],
           let frames = override.frames,
           !frames.isEmpty {
            return AtlasPlayback(frame: nil, frames: frames, fps: override.fps ?? 12)
        }

        return nil
    }

    func resolvedBlinkLayerPlayback(expressionID: String?) -> AtlasPlayback? {
        guard hasSeparateBlinkLayer(), let expression = expression(id: expressionID) else { return nil }

        if let override = expression.layers["blink"],
           let frames = override.frames,
           !frames.isEmpty {
            let blinkLayer = layers.first(where: { $0.id == "blink" })
            return AtlasPlayback(
                frame: nil,
                frames: frames,
                fps: override.fps ?? blinkLayer?.fps ?? 12
            )
        }

        if let blinkLayer = layers.first(where: { $0.id == "blink" }),
           blinkLayer.frame == nil,
           let fps = blinkLayer.fps,
           let frameCount = blinkLayer.frames,
           frameCount > 1 {
            return AtlasPlayback(frame: nil, frames: Array(0..<frameCount), fps: fps)
        }

        return nil
    }

    func resolvedBlinkPlayback(expressionID: String?) -> AtlasPlayback? {
        if hasSeparateBlinkLayer() {
            return resolvedBlinkLayerPlayback(expressionID: expressionID)
        }
        return resolvedEyeBlinkPlayback(expressionID: expressionID)
    }

    func shouldApplyEyeSpriteOverride(_ eyeSprite: String?) -> Bool {
        guard let eyeSprite, !eyeSprite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let neutral = neutralEyeSpriteName() else { return true }
        if eyeSprite != neutral {
            return true
        }
        return resolvedEyeBlinkPlayback(expressionID: blinkExpressionID()) == nil
    }

    func neutralEyeSpriteName() -> String? {
        if let expression = expression(id: "neutral"),
           let sprite = expression.layers["eyes"]?.sprite {
            return sprite
        }
        if let expression = expression(id: "neutral"),
           let frame = expression.layers["eyes"]?.frame,
           let sprite = eyeSprites.first(where: { $0.frame == frame }) {
            return sprite.name
        }
        return eyeSprites.first?.name
    }

    func neutralMouthSpriteName() -> String? {
        if let expression = expression(id: "neutral"),
           let sprite = expression.layers["mouth"]?.sprite {
            return sprite
        }
        if let expression = expression(id: "neutral"),
           let frame = expression.layers["mouth"]?.frame,
           let sprite = mouthSprites.first(where: { $0.frame == frame }) {
            return sprite.name
        }
        return mouthSprites.first?.name
    }

    func atlasColumns(for layer: Layer) -> Int {
        let frameWidth = max(Int((layer.frameWidth ?? layer.width).rounded()), 1)
        let frameX = max(Int((layer.frameX ?? 0).rounded()), 0)
        return max(Int(((layer.width - Double(frameX)) / Double(frameWidth)).rounded(.down)), 1)
    }

    func resolvedEyeFrame(matching brainName: String) -> Int? {
        let name = brainName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let frame = eyeFrame(named: name) {
            return frame
        }
        if let grid = LegacyFacialSprites.eyeGrid[name],
           let sprite = eyeSprites.first(where: { $0.column == grid.column && $0.row == grid.row }) {
            return sprite.frame
        }
        guard let grid = LegacyFacialSprites.eyeGrid[name],
              let layer = layers.first(where: { $0.id == "eyes" })
        else { return nil }
        return grid.row * atlasColumns(for: layer) + grid.column
    }

    func resolvedMouthFrame(matching brainName: String) -> Int? {
        let name = brainName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let frame = mouthFrame(named: name) {
            return frame
        }
        if let grid = LegacyFacialSprites.mouthGrid[name],
           let sprite = mouthSprites.first(where: { $0.column == grid.column && $0.row == grid.row }) {
            return sprite.frame
        }
        guard let grid = LegacyFacialSprites.mouthGrid[name],
              let layer = layers.first(where: { $0.id == "mouth" })
        else { return nil }
        return grid.row * atlasColumns(for: layer) + grid.column
    }

    func atlasPlayback(
        for layer: Layer,
        expressionID: String? = nil,
        eyeSprite: String? = nil,
        mouthSprite: String? = nil
    ) -> AtlasPlayback {
        if layer.id == "eyes", shouldApplyEyeSpriteOverride(eyeSprite), let eyeSprite,
           let frame = resolvedEyeFrame(matching: eyeSprite) {
            return AtlasPlayback(frame: frame, frames: nil, fps: nil)
        }
        if layer.id == "eyes",
           let eyeBlink = resolvedEyeBlinkPlayback(expressionID: expressionID) {
            return eyeBlink
        }
        if layer.id == "blink",
           let blinkPlayback = resolvedBlinkLayerPlayback(expressionID: expressionID) {
            return blinkPlayback
        }
        if layer.id == "mouth", let mouthSprite, let frame = resolvedMouthFrame(matching: mouthSprite) {
            return AtlasPlayback(frame: frame, frames: nil, fps: nil)
        }

        if let override = expression(id: expressionID)?.layers[layer.id] {
            if let frames = override.frames, !frames.isEmpty {
                return AtlasPlayback(frame: nil, frames: frames, fps: override.fps ?? layer.fps ?? 12)
            }
            if let sprite = override.sprite {
                let resolvedFrame: Int? = switch layer.id {
                case "eyes": eyeFrame(named: sprite)
                case "mouth": mouthFrame(named: sprite)
                default: nil
                }
                if let resolvedFrame {
                    return AtlasPlayback(frame: resolvedFrame, frames: nil, fps: nil)
                }
            }
            if let frame = override.frame {
                return AtlasPlayback(frame: frame, frames: nil, fps: nil)
            }
        }

        if layer.frame == nil, let fps = layer.fps, let frameCount = layer.frames, frameCount > 1 {
            return AtlasPlayback(frame: nil, frames: Array(0..<frameCount), fps: fps)
        }
        return AtlasPlayback(frame: layer.frame ?? 0, frames: nil, fps: nil)
    }

    static func atlasFrameOrigin(
        index: Int,
        frameX: Int = 0,
        frameY: Int = 0,
        frameWidth: Int,
        frameHeight: Int,
        imageWidth: Int
    ) -> AtlasFrameOrigin? {
        guard frameWidth > 0, frameHeight > 0, imageWidth > 0 else {
            return nil
        }
        let usableWidth = max(imageWidth - max(frameX, 0), frameWidth)
        let columns = max(usableWidth / frameWidth, 1)
        return AtlasFrameOrigin(
            x: max(frameX, 0) + max(index, 0) % columns * frameWidth,
            y: max(frameY, 0) + max(index, 0) / columns * frameHeight
        )
    }
}
