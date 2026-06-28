#if os(macOS)
//
//  Removes debug-magenta backgrounds from generated avatar kit images.
//  Affective
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AvatarKitChromaKey {
    static let keyRed: UInt8 = 255
    static let keyGreen: UInt8 = 0
    static let keyBlue: UInt8 = 255
    static let hardTolerance: UInt8 = 48
    static let softTolerance: UInt8 = 40

    private static let rgbaBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue

    static func removeDebugBackground(from sourceURL: URL, to destinationURL: URL) throws {
        let cgImage = try decodeImage(from: sourceURL)
        let keyed = try keyedImage(from: cgImage)
        try writePNGImage(keyed, to: destinationURL)

        guard !containsDebugMagenta(in: keyed) else {
            throw AvatarKitGenerationError.chromaKeyFailed(
                "Magenta background remains in \(destinationURL.lastPathComponent) after keying."
            )
        }
    }

    static func decodeImage(from url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AvatarKitGenerationError.chromaKeyFailed(
                "Could not decode \(url.lastPathComponent)."
            )
        }
        return try rgbaImage(from: image, label: url.lastPathComponent)
    }

    static func keyedImageIfNeeded(from url: URL) throws -> CGImage {
        let image = try decodeImage(from: url)
        guard containsDebugMagenta(in: image) else { return image }
        return try keyedImage(from: image)
    }

    static func containsDebugMagenta(in image: CGImage) -> Bool {
        guard let pixels = try? makePixelBuffer(from: image) else { return false }
        let sampleCount = min(64, pixels.width * pixels.height)
        var magentaSamples = 0
        var checked = 0

        for index in 0..<sampleCount {
            let x = (index * 17) % pixels.width
            let y = (index * 23) % pixels.height
            let offset = (y * pixels.bytesPerRow) + (x * 4)
            let rgba = unpremultipliedRGBA(
                red: pixels.bytes[offset],
                green: pixels.bytes[offset + 1],
                blue: pixels.bytes[offset + 2],
                alpha: pixels.bytes[offset + 3]
            )
            checked += 1
            if rgba.alpha > 16, isDebugMagenta(red: rgba.red, green: rgba.green, blue: rgba.blue) {
                magentaSamples += 1
            }
        }

        return checked > 0 && Double(magentaSamples) / Double(checked) >= 0.18
    }

    static func keyedImage(from image: CGImage) throws -> CGImage {
        var pixels = try makePixelBuffer(from: image)

        for offset in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let rgba = unpremultipliedRGBA(
                red: pixels.bytes[offset],
                green: pixels.bytes[offset + 1],
                blue: pixels.bytes[offset + 2],
                alpha: pixels.bytes[offset + 3]
            )
            let keyedAlpha = keyedAlpha(
                forRed: rgba.red,
                green: rgba.green,
                blue: rgba.blue,
                sourceAlpha: rgba.alpha
            )
            if keyedAlpha == 0 {
                pixels.bytes[offset] = 0
                pixels.bytes[offset + 1] = 0
                pixels.bytes[offset + 2] = 0
                pixels.bytes[offset + 3] = 0
            } else if keyedAlpha != rgba.alpha {
                let scale = Double(keyedAlpha) / 255.0
                pixels.bytes[offset] = UInt8(min(255, Int((Double(rgba.red) * scale).rounded())))
                pixels.bytes[offset + 1] = UInt8(min(255, Int((Double(rgba.green) * scale).rounded())))
                pixels.bytes[offset + 2] = UInt8(min(255, Int((Double(rgba.blue) * scale).rounded())))
                pixels.bytes[offset + 3] = keyedAlpha
            } else {
                pixels.bytes[offset] = rgba.red
                pixels.bytes[offset + 1] = rgba.green
                pixels.bytes[offset + 2] = rgba.blue
                pixels.bytes[offset + 3] = rgba.alpha
            }
        }

        return try cgImage(from: pixels)
    }

    static func keyedAlpha(forRed red: UInt8, green: UInt8, blue: UInt8, sourceAlpha: UInt8) -> UInt8 {
        if sourceAlpha == 0 {
            return 0
        }
        if isDebugMagenta(red: red, green: green, blue: blue) {
            let distance = keyDistance(red: red, green: green, blue: blue)
            if distance <= Int(hardTolerance) {
                return 0
            }
            if distance <= Int(hardTolerance) + Int(softTolerance) {
                let fade = Double(distance - Int(hardTolerance)) / Double(softTolerance)
                return UInt8(min(255, Int((Double(sourceAlpha) * fade).rounded())))
            }
        }
        return sourceAlpha
    }

    static func isDebugMagenta(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let redValue = Int(red)
        let greenValue = Int(green)
        let blueValue = Int(blue)
        let dominant = min(redValue, blueValue)
        guard dominant >= 90 else { return false }
        guard greenValue <= dominant - 35 else { return false }
        return (redValue - greenValue) >= 45 && (blueValue - greenValue) >= 45
    }

    static func keyDistance(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        max(
            abs(Int(red) - Int(keyRed)),
            abs(Int(green) - Int(keyGreen)),
            abs(Int(blue) - Int(keyBlue))
        )
    }

    struct PixelBuffer {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var bytesPerRow: Int
    }

    static func pixelBuffer(from image: CGImage) throws -> PixelBuffer {
        try makePixelBuffer(from: image)
    }

    static func writePNG(_ image: CGImage, to destinationURL: URL) throws {
        try writePNGImage(image, to: destinationURL)
    }

    private static func rgbaImage(from image: CGImage, label: String) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw AvatarKitGenerationError.chromaKeyFailed("Invalid image dimensions for \(label).")
        }

        let pixels = try makePixelBuffer(from: image)
        return try cgImage(from: pixels)
    }

    private static func makePixelBuffer(from image: CGImage) throws -> PixelBuffer {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: rgbaBitmapInfo
        ) else {
            throw AvatarKitGenerationError.chromaKeyFailed("Could not create bitmap context.")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelBuffer(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func cgImage(from pixels: PixelBuffer) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels.bytes) as CFData),
              let image = CGImage(
                width: pixels.width,
                height: pixels.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: rgbaBitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw AvatarKitGenerationError.chromaKeyFailed("Could not build RGBA image.")
        }
        return image
    }

    private static func writePNGImage(_ image: CGImage, to destinationURL: URL) throws {
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AvatarKitGenerationError.chromaKeyFailed(
                "Could not create PNG encoder for \(destinationURL.lastPathComponent)."
            )
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AvatarKitGenerationError.chromaKeyFailed(
                "Could not write PNG to \(destinationURL.lastPathComponent)."
            )
        }

        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (outputData as Data).write(to: destinationURL, options: .atomic)
    }

    private static func unpremultipliedRGBA(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard alpha > 0, alpha < 255 else {
            return (red, green, blue, alpha)
        }
        let scale = 255.0 / Double(alpha)
        return (
            UInt8(min(255, Int((Double(red) * scale).rounded()))),
            UInt8(min(255, Int((Double(green) * scale).rounded()))),
            UInt8(min(255, Int((Double(blue) * scale).rounded()))),
            alpha
        )
    }
}

extension CGImage {
    func copyWithAlphaIfNeeded() -> CGImage? {
        if alphaInfo != .none, alphaInfo != .noneSkipFirst, alphaInfo != .noneSkipLast {
            return self
        }
        return try? AvatarKitChromaKey.keyedImage(from: self)
    }
}

#endif
