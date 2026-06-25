#if os(macOS)
//
//  Split from AvatarEditorView.swift
//  Affective
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension NSImage {
    var pixelSize: CGSize? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    func croppedEditorAvatarFrame(index: Int, frameX: Int, frameY: Int, frameWidth: Int, frameHeight: Int) -> NSImage? {
        guard
            let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
            let origin = BrainAvatarManifest.atlasFrameOrigin(
                index: index,
                frameX: frameX,
                frameY: frameY,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                imageWidth: cgImage.width
            )
        else {
            return nil
        }

        let sourceRect = CGRect(
            x: max(origin.x, 0),
            y: max(origin.y, 0),
            width: min(frameWidth, cgImage.width - max(origin.x, 0)),
            height: min(frameHeight, cgImage.height - max(origin.y, 0))
        )
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            return nil
        }
        guard let cropped = cgImage.cropping(to: sourceRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: frameHeight))
    }
}
#endif
