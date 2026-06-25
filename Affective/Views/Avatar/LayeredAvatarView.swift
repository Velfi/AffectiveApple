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
    var ignoresClip: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let frame = renderFrame
            let scale = scale(in: proxy.size)
            let contentWidth = safeDimension(frame.width * scale)
            let contentHeight = safeDimension(frame.height * scale)
            ZStack(alignment: .topLeading) {
                ForEach(manifest.layers) { layer in
                    if let layerFrame = safeLayerFrame(for: layer, in: frame, scale: scale) {
                        AvatarLayerView(manifest: manifest, layer: layer, expressionID: expressionID)
                            .frame(width: layerFrame.size.width, height: layerFrame.size.height)
                            .position(x: layerFrame.midX, y: layerFrame.midY)
                            .opacity(layer.opacity ?? 1)
                    }
                }
            }
            .frame(width: contentWidth, height: contentHeight)
            .clipped()
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
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
            layer.x.isFinite,
            layer.y.isFinite,
            layer.width.isFinite,
            layer.height.isFinite,
            layer.width > 0,
            layer.height > 0
        else {
            avatarRenderLogger.error("Skipping invalid avatar layer id=\(layer.id, privacy: .public) x=\(layer.x, privacy: .public) y=\(layer.y, privacy: .public) width=\(layer.width, privacy: .public) height=\(layer.height, privacy: .public) scale=\(scale, privacy: .public)")
            return nil
        }

        let rect = CGRect(
            x: (layer.x - frame.x) * scale,
            y: (layer.y - frame.y) * scale,
            width: layer.width * scale,
            height: layer.height * scale
        )
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else {
            avatarRenderLogger.error("Skipping non-finite avatar layer frame id=\(layer.id, privacy: .public)")
            return nil
        }
        return rect
    }
}

struct AvatarLayerView: View {
    let manifest: BrainAvatarManifest
    let layer: BrainAvatarManifest.Layer
    let expressionID: String?

    var body: some View {
        if layer.atlas != nil {
            let playback = manifest.atlasPlayback(for: layer, expressionID: expressionID)
            if playback.isAnimated && layer.id == "blink" {
                RandomBlinkAvatarLayerView(manifest: manifest, layer: layer, playback: playback)
            } else if playback.isAnimated {
                TimelineView(.animation) { timeline in
                    atlasFrame(index: playback.frameIndex(at: timeline.date))
                }
            } else {
                atlasFrame(index: playback.frameIndex(at: .now))
            }
        } else {
            imageLayer
        }
    }

    @ViewBuilder
    var imageLayer: some View {
        #if os(macOS)
        if let imagePath = layer.image,
           let image = NSImage(contentsOf: manifest.url(for: imagePath)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
        #elseif canImport(UIKit)
        if let imagePath = layer.image,
           let image = UIImage(contentsOfFile: manifest.url(for: imagePath).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
        #endif
    }

    @ViewBuilder
    func atlasFrame(index: Int) -> some View {
        #if os(macOS)
        if let atlasPath = layer.atlas,
           let image = NSImage(contentsOf: manifest.url(for: atlasPath)),
           let frameImage = image.croppedAvatarFrame(
                index: index,
                frameX: safeInt(layer.frameX),
                frameY: safeInt(layer.frameY),
                frameWidth: safeInt(layer.frameWidth ?? layer.width),
                frameHeight: safeInt(layer.frameHeight ?? layer.height)
           ) {
            Image(nsImage: frameImage)
                .resizable()
                .scaledToFill()
        }
        #elseif canImport(UIKit)
        if let atlasPath = layer.atlas,
           let image = UIImage(contentsOfFile: manifest.url(for: atlasPath).path),
           let frameImage = image.croppedAvatarFrame(
                index: index,
                frameX: safeInt(layer.frameX),
                frameY: safeInt(layer.frameY),
                frameWidth: safeInt(layer.frameWidth ?? layer.width),
                frameHeight: safeInt(layer.frameHeight ?? layer.height)
           ) {
            Image(uiImage: frameImage)
                .resizable()
                .scaledToFill()
        }
        #endif
    }

}

struct RandomBlinkAvatarLayerView: View {
    let manifest: BrainAvatarManifest
    let layer: BrainAvatarManifest.Layer
    let playback: BrainAvatarManifest.AtlasPlayback
    @State private var blinkStartDate: Date?
    @State private var nextBlinkDate = Date(timeIntervalSinceNow: Double.random(in: 2.4...7.0))

    var body: some View {
        TimelineView(.animation) { timeline in
            atlasFrame(index: frameIndex(at: timeline.date))
        }
    }

    func frameIndex(at date: Date) -> Int {
        let frames = playback.frames?.isEmpty == false ? playback.frames! : [0]
        let fps = max(playback.fps ?? 12, 1)

        if let blinkStartDate {
            let frameOffset = Int(date.timeIntervalSince(blinkStartDate) * fps)
            if frameOffset < frames.count {
                return max(frames[frameOffset], 0)
            }

            DispatchQueue.main.async {
                self.blinkStartDate = nil
                self.nextBlinkDate = Date(timeIntervalSinceNow: Double.random(in: 2.4...7.0))
            }
            return max(frames.first ?? 0, 0)
        }

        if date >= nextBlinkDate {
            DispatchQueue.main.async {
                self.blinkStartDate = date
            }
        }
        return max(frames.first ?? 0, 0)
    }

    @ViewBuilder
    func atlasFrame(index: Int) -> some View {
        #if os(macOS)
        if let atlasPath = layer.atlas,
           let image = NSImage(contentsOf: manifest.url(for: atlasPath)),
           let frameImage = image.croppedAvatarFrame(
                index: index,
                frameX: safeInt(layer.frameX),
                frameY: safeInt(layer.frameY),
                frameWidth: safeInt(layer.frameWidth ?? layer.width),
                frameHeight: safeInt(layer.frameHeight ?? layer.height)
           ) {
            Image(nsImage: frameImage)
                .resizable()
                .scaledToFill()
        }
        #elseif canImport(UIKit)
        if let atlasPath = layer.atlas,
           let image = UIImage(contentsOfFile: manifest.url(for: atlasPath).path),
           let frameImage = image.croppedAvatarFrame(
                index: index,
                frameX: safeInt(layer.frameX),
                frameY: safeInt(layer.frameY),
                frameWidth: safeInt(layer.frameWidth ?? layer.width),
                frameHeight: safeInt(layer.frameHeight ?? layer.height)
           ) {
            Image(uiImage: frameImage)
                .resizable()
                .scaledToFill()
        }
        #endif
    }
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
            let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
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
