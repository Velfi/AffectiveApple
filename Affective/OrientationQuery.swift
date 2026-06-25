//
//  OrientationQuery.swift
//  Affective
//

import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

enum HostOrientationPermissionStatus: String, Equatable {
    case available
    case promptRequired = "prompt_required"
    case denied
    case unavailable
}

struct OrientationPermissionPrompt: Identifiable, Equatable {
    let id = UUID()
    let requestID: String?
    let reason: String
}

struct OrientationObservation: Equatable {
    let posture: String
    let confidence: Double
    let gravityX: Double?
    let gravityY: Double?
    let gravityZ: Double?
    let summary: String

    var eventArguments: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "posture": .string(posture),
            "confidence": .number(confidence),
            "summary": .string(summary),
        ]
        if let gravityX, let gravityY, let gravityZ {
            values["gravity"] = .object([
                "x": .number(gravityX),
                "y": .number(gravityY),
                "z": .number(gravityZ),
            ])
        }
        return values
    }
}

enum OrientationQueryError: LocalizedError {
    case unavailable
    case sampleTimedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Device orientation sensing is unavailable on this host."
        case .sampleTimedOut:
            "Affective could not read device orientation in time."
        }
    }
}

struct OrientationQueryProvider {
    func observe() async throws -> OrientationObservation {
        #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else {
            throw OrientationQueryError.unavailable
        }
        manager.deviceMotionUpdateInterval = 0.05
        manager.startDeviceMotionUpdates()
        defer { manager.stopDeviceMotionUpdates() }

        try await Task.sleep(nanoseconds: 250_000_000)
        guard let motion = manager.deviceMotion else {
            throw OrientationQueryError.sampleTimedOut
        }
        return Self.classify(
            x: motion.gravity.x,
            y: motion.gravity.y,
            z: motion.gravity.z
        )
        #else
        throw OrientationQueryError.unavailable
        #endif
    }

    static func classify(x: Double, y: Double, z: Double) -> OrientationObservation {
        let roundedX = roundedGravity(x)
        let roundedY = roundedGravity(y)
        let roundedZ = roundedGravity(z)
        let absX = abs(x)
        let absY = abs(y)
        let absZ = abs(z)
        let dominant = max(absX, absY, absZ)
        let confidence = min(max(dominant, 0), 1)

        let posture: String
        let summary: String
        if absZ >= 0.78 {
            if z < 0 {
                posture = "face_up"
                summary = "The device is lying face up."
            } else {
                posture = "face_down"
                summary = "The device is lying face down."
            }
        } else if absY >= 0.72 {
            posture = "upright"
            summary = y < 0 ? "The device is upright." : "The device is upside down."
        } else if absX >= 0.72 {
            if x > 0 {
                posture = "landscape_left"
                summary = "The device is rotated landscape left."
            } else {
                posture = "landscape_right"
                summary = "The device is rotated landscape right."
            }
        } else if dominant >= 0.45 {
            posture = "tilted"
            summary = "The device is tilted between stable orientations."
        } else {
            posture = "unknown"
            summary = "The device orientation is unclear."
        }

        return OrientationObservation(
            posture: posture,
            confidence: roundedConfidence(confidence),
            gravityX: roundedX,
            gravityY: roundedY,
            gravityZ: roundedZ,
            summary: summary
        )
    }

    private static func roundedGravity(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func roundedConfidence(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
