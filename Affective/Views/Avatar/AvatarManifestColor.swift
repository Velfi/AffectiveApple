//
//  AvatarManifestColor.swift
//  Affective
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Color {
    var avatarHexString: String? {
        #if os(macOS)
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        let alpha = Int(round(rgb.alphaComponent * 255))
        if alpha < 255 {
            return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
        #else
        return nil
        #endif
    }

    static func avatarColor(fromHex hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        let scanner = Scanner(string: String(digits))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }

        switch digits.count {
        case 6:
            let red = Double((value & 0xFF0000) >> 16) / 255
            let green = Double((value & 0x00FF00) >> 8) / 255
            let blue = Double(value & 0x0000FF) / 255
            return Color(red: red, green: green, blue: blue)
        case 8:
            let red = Double((value & 0xFF000000) >> 24) / 255
            let green = Double((value & 0x00FF0000) >> 16) / 255
            let blue = Double((value & 0x0000FF00) >> 8) / 255
            let alpha = Double(value & 0x000000FF) / 255
            return Color(red: red, green: green, blue: blue, opacity: alpha)
        default:
            return nil
        }
    }
}
