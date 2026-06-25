//
//  Split from BrainLibrary.swift
//  Affective
//

import Foundation

struct BrainAvatarManifest: Codable, Equatable {
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
        let frames: [Int]?
        let fps: Double?

        init(frame: Int? = nil, frames: [Int]? = nil, fps: Double? = nil) {
            self.frame = frame
            self.frames = frames
            self.fps = fps
        }
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
            opacity: Double? = nil
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
    let defaultExpression: String?
    let expressions: [Expression]
    let rootURL: URL

    enum CodingKeys: String, CodingKey {
        case canvas
        case clip
        case layers
        case defaultExpression
        case expressions
    }

    init(
        canvas: Canvas,
        clip: ClipFrame? = nil,
        layers: [Layer],
        defaultExpression: String? = nil,
        expressions: [Expression] = [],
        rootURL: URL
    ) {
        self.canvas = canvas
        self.clip = clip
        self.layers = layers.sorted { $0.z < $1.z }
        self.defaultExpression = defaultExpression
        self.expressions = expressions
        self.rootURL = rootURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvas = try container.decode(Canvas.self, forKey: .canvas)
        clip = try container.decodeIfPresent(ClipFrame.self, forKey: .clip)
        layers = try container.decode([Layer].self, forKey: .layers).sorted { $0.z < $1.z }
        defaultExpression = try container.decodeIfPresent(String.self, forKey: .defaultExpression)
        expressions = try container.decodeIfPresent([Expression].self, forKey: .expressions) ?? []
        rootURL = URL(fileURLWithPath: "/")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvas, forKey: .canvas)
        try container.encodeIfPresent(clip, forKey: .clip)
        try container.encode(layers.sorted { $0.z < $1.z }, forKey: .layers)
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
            let defaultExpression: String?
            let expressions: [Expression]?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        return BrainAvatarManifest(
            canvas: payload.canvas,
            clip: payload.clip,
            layers: payload.layers,
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
            x: max(0, clip.x.isFinite ? clip.x : 0),
            y: max(0, clip.y.isFinite ? clip.y : 0),
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

    func atlasPlayback(for layer: Layer, expressionID: String? = nil) -> AtlasPlayback {
        if let override = expression(id: expressionID)?.layers[layer.id] {
            if let frames = override.frames, !frames.isEmpty {
                return AtlasPlayback(frame: nil, frames: frames, fps: override.fps ?? layer.fps ?? 12)
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
