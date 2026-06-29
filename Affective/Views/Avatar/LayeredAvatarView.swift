//
//  Split from ContentView.swift
//  Affective
//

import SwiftUI
import os
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif

struct LayeredAvatarView: View {
    let manifest: BrainAvatarManifest
    var expressionID: String? = nil
    var eyeSprite: String? = nil
    var mouthSprite: String? = nil
    var ignoresClip: Bool = false
    var contentAlignment: Alignment = .center
    var assetURLForPath: ((String) -> URL)? = nil

    func assetURL(for path: String) -> URL {
        assetURLForPath?(path) ?? manifest.url(for: path)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = renderFrame
            let scale = scale(in: proxy.size)
            let contentWidth = safeDimension(frame.width * scale)
            let contentHeight = safeDimension(frame.height * scale)
            ZStack(alignment: .topLeading) {
                ForEach(manifest.layers) { layer in
                    if let layerFrame = safeLayerFrame(for: layer, in: frame, scale: scale) {
                        AvatarLayerView(
                            layer: layer,
                            expressionID: expressionID,
                            eyeSprite: eyeSprite,
                            assetURL: assetURL,
                            atlasPlayback: manifest.atlasPlayback(
                                for: layer,
                                expressionID: expressionID,
                                eyeSprite: eyeSprite,
                                mouthSprite: mouthSprite
                            ),
                            usesRandomBlink: shouldRandomBlink(for: layer)
                        )
                        .frame(width: layerFrame.size.width, height: layerFrame.size.height)
                        .offset(x: layerFrame.minX, y: layerFrame.minY)
                        .opacity(layer.opacity ?? 1)
                    }
                }
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
        }
    }

    var renderFrame: BrainAvatarManifest.ClipFrame {
        if ignoresClip {
            return .init(
                width: max(manifest.canvas.width.isFinite ? manifest.canvas.width : 1, 1),
                height: max(manifest.canvas.height.isFinite ? manifest.canvas.height : 1, 1)
            )
        }
        return manifest.effectiveClip
    }

    func scale(in size: CGSize) -> Double {
        let frame = renderFrame
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return 0
        }
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            avatarRenderLogger.error("Invalid render frame width=\(frame.width, privacy: .public) height=\(frame.height, privacy: .public)")
            return 0
        }
        let scale = min(size.width / frame.width, size.height / frame.height)
        if !scale.isFinite || scale <= 0 {
            avatarRenderLogger.error("Invalid render scale viewWidth=\(size.width, privacy: .public) viewHeight=\(size.height, privacy: .public) frameWidth=\(frame.width, privacy: .public) frameHeight=\(frame.height, privacy: .public)")
            return 0
        }
        return scale
    }

    func safeLayerFrame(for layer: BrainAvatarManifest.Layer, in frame: BrainAvatarManifest.ClipFrame, scale: Double) -> CGRect? {
        guard
            scale.isFinite,
            scale > 0,
            layer.width.isFinite,
            layer.height.isFinite,
            layer.width > 0,
            layer.height > 0
        else {
            avatarRenderLogger.error("Skipping invalid avatar layer id=\(layer.id, privacy: .public) width=\(layer.width, privacy: .public) height=\(layer.height, privacy: .public) scale=\(scale, privacy: .public)")
            return nil
        }

        let topLeft = layer.topLeftOrigin()
        let rect = CGRect(
            x: (topLeft.x - frame.x) * scale,
            y: (topLeft.y - frame.y) * scale,
            width: layer.width * scale,
            height: layer.height * scale
        )
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            avatarRenderLogger.error("Skipping non-finite avatar layer frame id=\(layer.id, privacy: .public)")
            return nil
        }
        return rect
    }

    func shouldRandomBlink(for layer: BrainAvatarManifest.Layer) -> Bool {
        guard layer.id == manifest.blinkTargetLayerID(expressionID: expressionID) else { return false }
        guard manifest.resolvedBlinkPlayback(expressionID: expressionID)?.isAnimated == true else { return false }
        if layer.id == "eyes",
           let eyeSprite,
           let neutral = manifest.neutralEyeSpriteName(),
           eyeSprite != neutral {
            return false
        }
        return true
    }
}

struct AvatarLayerView: View {
    let layer: BrainAvatarManifest.Layer
    let expressionID: String?
    let eyeSprite: String?
    let assetURL: (String) -> URL
    let atlasPlayback: BrainAvatarManifest.AtlasPlayback
    let usesRandomBlink: Bool

    var body: some View {
        if layer.atlas != nil {
            if usesRandomBlink {
                RandomBlinkAvatarLayerView(layer: layer, playback: atlasPlayback, assetURL: assetURL)
            } else if atlasPlayback.isAnimated {
                TimelineView(.animation) { timeline in
                    atlasFrame(index: atlasPlayback.frameIndex(at: timeline.date))
                }
            } else {
                atlasFrame(index: atlasPlayback.frameIndex(at: .now))
            }
        } else if let colorHex = layer.color, layer.image == nil,
                  let fillColor = Color.avatarColor(fromHex: colorHex) {
            Rectangle()
                .fill(fillColor)
        } else {
            imageLayer
        }
    }

    @ViewBuilder
    var imageLayer: some View {
        #if os(macOS)
        if let imagePath = layer.image,
           let image = AvatarAssetImageLoader.loadImage(from: assetURL(imagePath), layerID: layer.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        }
        #elseif canImport(UIKit)
        if let imagePath = layer.image,
           let image = AvatarAssetImageLoader.loadImage(from: assetURL(imagePath), layerID: layer.id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        }
        #endif
    }

    @ViewBuilder
    func atlasFrame(index: Int) -> some View {
        if let frameImage = AvatarAtlasFrameCache.frameImage(
            atlasURL: assetURL(layer.atlas ?? ""),
            layerID: layer.id,
            frameIndex: index,
            frameX: safeInt(layer.frameX),
            frameY: safeInt(layer.frameY),
            frameWidth: safeInt(layer.frameWidth ?? layer.width),
            frameHeight: safeInt(layer.frameHeight ?? layer.height)
        ) {
            #if os(macOS)
            Image(nsImage: frameImage)
                .resizable()
                .scaledToFill()
                .clipped()
            #elseif canImport(UIKit)
            Image(uiImage: frameImage)
                .resizable()
                .scaledToFill()
                .clipped()
            #endif
        }
    }

}

struct RandomBlinkAvatarLayerView: View {
    let layer: BrainAvatarManifest.Layer
    let playback: BrainAvatarManifest.AtlasPlayback
    let assetURL: (String) -> URL
    @State private var blinkStartDate: Date?
    @State private var nextBlinkDate = Date(timeIntervalSinceNow: Double.random(in: 2.4...7.0))

    var body: some View {
        TimelineView(.animation) { timeline in
            atlasFrame(index: displayedFrameIndex(at: timeline.date))
                .onChange(of: timeline.date) { _, date in
                    advanceBlinkSchedule(at: date)
                }
        }
    }

    func displayedFrameIndex(at date: Date) -> Int {
        let frames = playback.frames?.isEmpty == false ? playback.frames! : [0]
        let fps = max(playback.fps ?? 12, 1)

        if let blinkStartDate {
            let frameOffset = Int(date.timeIntervalSince(blinkStartDate) * Double(fps))
            if frameOffset < frames.count {
                return max(frames[frameOffset], 0)
            }
            return max(frames.first ?? 0, 0)
        }

        return max(frames.first ?? 0, 0)
    }

    func advanceBlinkSchedule(at date: Date) {
        let frames = playback.frames?.isEmpty == false ? playback.frames! : [0]
        let fps = max(playback.fps ?? 12, 1)

        if let blinkStartDate {
            let frameOffset = Int(date.timeIntervalSince(blinkStartDate) * Double(fps))
            if frameOffset >= frames.count {
                self.blinkStartDate = nil
                self.nextBlinkDate = Date(timeIntervalSinceNow: Double.random(in: 2.4...7.0))
            }
            return
        }

        if date >= nextBlinkDate {
            blinkStartDate = date
        }
    }

    @ViewBuilder
    func atlasFrame(index: Int) -> some View {
        if let frameImage = AvatarAtlasFrameCache.frameImage(
            atlasURL: assetURL(layer.atlas ?? ""),
            layerID: layer.id,
            frameIndex: index,
            frameX: safeInt(layer.frameX),
            frameY: safeInt(layer.frameY),
            frameWidth: safeInt(layer.frameWidth ?? layer.width),
            frameHeight: safeInt(layer.frameHeight ?? layer.height)
        ) {
            #if os(macOS)
            Image(nsImage: frameImage)
                .resizable()
                .scaledToFill()
                .clipped()
            #elseif canImport(UIKit)
            Image(uiImage: frameImage)
                .resizable()
                .scaledToFill()
                .clipped()
            #endif
        }
    }
}

@MainActor
enum AvatarAtlasFrameCache {
    #if canImport(UIKit)
    typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    typealias PlatformImage = NSImage
    #endif

    private struct AtlasKey: Hashable {
        let url: URL
        let layerID: String
    }

    private struct FrameKey: Hashable {
        let atlas: AtlasKey
        let frameIndex: Int
        let frameX: Int
        let frameY: Int
        let frameWidth: Int
        let frameHeight: Int
    }

    private static var atlasImages: [AtlasKey: PlatformImage] = [:]
    private static var frameImages: [FrameKey: PlatformImage] = [:]

    static func frameImage(
        atlasURL: URL,
        layerID: String,
        frameIndex: Int,
        frameX: Int,
        frameY: Int,
        frameWidth: Int,
        frameHeight: Int
    ) -> PlatformImage? {
        let atlasKey = AtlasKey(url: atlasURL, layerID: layerID)
        let frameKey = FrameKey(
            atlas: atlasKey,
            frameIndex: frameIndex,
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )

        if let cached = frameImages[frameKey] {
            return cached
        }

        guard let atlas = loadAtlasImage(atlasURL: atlasURL, layerID: layerID) else {
            return nil
        }

        guard let cropped = atlas.croppedAvatarFrame(
            index: frameIndex,
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ) else {
            return nil
        }

        frameImages[frameKey] = cropped
        return cropped
    }

    static func loadAtlasImage(atlasURL: URL, layerID: String) -> PlatformImage? {
        let key = AtlasKey(url: atlasURL, layerID: layerID)
        if let cached = atlasImages[key] {
            return cached
        }
        guard let image = AvatarAssetImageLoader.loadImage(from: atlasURL, layerID: layerID) else {
            return nil
        }
        atlasImages[key] = image
        return image
    }
}

enum AvatarAssetImageLoader {
    #if os(macOS)
    static func loadImage(from url: URL, layerID: String) -> NSImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            avatarRenderLogger.error("Missing avatar asset layer=\(layerID, privacy: .public) path=\(url.path, privacy: .public)")
            return nil
        }

        do {
            let cgImage = try AvatarKitChromaKey.keyedImageIfNeeded(from: url)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            avatarRenderLogger.error("Could not decode avatar asset layer=\(layerID, privacy: .public) path=\(url.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
    #elseif canImport(UIKit)
    static func loadImage(from url: URL, layerID: String) -> UIImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            avatarRenderLogger.error("Missing avatar asset layer=\(layerID, privacy: .public) path=\(url.path, privacy: .public)")
            return nil
        }

        guard let image = UIImage(contentsOfFile: url.path) else {
            avatarRenderLogger.error("Could not decode avatar asset layer=\(layerID, privacy: .public) path=\(url.path, privacy: .public)")
            return nil
        }
        return image
    }
    #endif
}

private let avatarRenderLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "avatar-render")

private func safeDimension(_ value: Double) -> Double {
    value.isFinite && value > 0 ? value : 1
}

private func safeInt(_ value: Double?) -> Int {
    guard let value, value.isFinite else { return 0 }
    return Int(value.rounded())
}

#if os(macOS)
extension NSImage {
    func croppedAvatarFrame(index: Int, frameX: Int, frameY: Int, frameWidth: Int, frameHeight: Int) -> NSImage? {
        guard
            let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil)?
                .copyWithAlphaIfNeeded(),
            frameWidth > 0,
            frameHeight > 0
        else {
            return nil
        }

        guard let origin = BrainAvatarManifest.atlasFrameOrigin(
            index: index,
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            imageWidth: cgImage.width
        ) else {
            return nil
        }
        let sourceRect = CGRect(x: origin.x, y: origin.y, width: frameWidth, height: frameHeight)

        guard let cropped = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: frameHeight))
    }
}
#endif

#if canImport(UIKit)
extension UIImage {
    func croppedAvatarFrame(index: Int, frameX: Int, frameY: Int, frameWidth: Int, frameHeight: Int) -> UIImage? {
        guard
            let cgImage,
            frameWidth > 0,
            frameHeight > 0
        else {
            return nil
        }

        guard let origin = BrainAvatarManifest.atlasFrameOrigin(
            index: index,
            frameX: frameX,
            frameY: frameY,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            imageWidth: cgImage.width
        ) else {
            return nil
        }
        let sourceRect = CGRect(x: origin.x, y: origin.y, width: frameWidth, height: frameHeight)

        guard let cropped = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
#endif
