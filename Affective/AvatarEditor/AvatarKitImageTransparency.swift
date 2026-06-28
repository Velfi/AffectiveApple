#if os(macOS)
//
//  Detects real alpha transparency in generated avatar kit images.
//  Affective
//

import CoreGraphics
import Foundation

nonisolated enum AvatarKitImageTransparency {
    static let transparentAlphaThreshold: UInt8 = 16
    static let minimumTransparentPixelCount = 64

    static func hasTransparentPixels(at url: URL) -> Bool {
        guard let image = try? AvatarKitChromaKey.decodeImage(from: url) else {
            return false
        }
        return hasTransparentPixels(in: image)
    }

    static func hasTransparentPixels(in image: CGImage) -> Bool {
        guard let pixels = try? AvatarKitChromaKey.pixelBuffer(from: image) else {
            return false
        }

        var transparentCount = 0
        for offset in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let alpha = pixels.bytes[offset + 3]
            if alpha <= transparentAlphaThreshold {
                transparentCount += 1
                if transparentCount >= minimumTransparentPixelCount {
                    return true
                }
            }
        }
        return false
    }
}

#endif
