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

#if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
final class CoreMotionSensorHub: @unchecked Sendable {
    nonisolated static let shared = CoreMotionSensorHub()

    private let manager = CMMotionManager()

    private init() {}

    nonisolated var isAccelerometerAvailable: Bool {
        manager.isAccelerometerAvailable
    }

    var isAccelerometerActive: Bool {
        manager.isAccelerometerActive
    }

    func startAccelerometerUpdates(handler: @escaping CMAccelerometerHandler) {
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 0.05
        manager.startAccelerometerUpdates(to: .main, withHandler: handler)
    }

    nonisolated func stopAccelerometerUpdates() {
        manager.stopAccelerometerUpdates()
    }

    func observeOrientation() async throws -> OrientationObservation {
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
        return OrientationQueryProvider.classify(
            x: motion.gravity.x,
            y: motion.gravity.y,
            z: motion.gravity.z
        )
    }
}
#endif

nonisolated struct OrientationObservation: Equatable {
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

nonisolated struct MotionGestureObservation: Equatable {
    let gesture: String
    let confidence: Double
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let summary: String

    var eventArguments: [String: JSONValue] {
        [
            "gesture": .string(gesture),
            "confidence": .number(confidence),
            "acceleration": .object([
                "x": .number(accelerationX),
                "y": .number(accelerationY),
                "z": .number(accelerationZ),
            ]),
            "summary": .string(summary),
        ]
    }
}

final class MotionGestureMonitor {
    private let onGesture: @MainActor (MotionGestureObservation) -> Void
    private var lastGestureAt: [String: Date] = [:]
    nonisolated(unsafe) private static var cachedAvailability: Bool?

    init(onGesture: @escaping @MainActor (MotionGestureObservation) -> Void) {
        self.onGesture = onGesture
    }

    func start() {
        #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        CoreMotionSensorHub.shared.startAccelerometerUpdates { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            guard let observation = Self.classify(
                x: acceleration.x,
                y: acceleration.y,
                z: acceleration.z
            ) else { return }
            guard self.shouldEmit(observation.gesture) else { return }
            let onGesture = self.onGesture
            Task { @MainActor in
                onGesture(observation)
            }
        }
        #endif
    }

    nonisolated func stop() {
        #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        CoreMotionSensorHub.shared.stopAccelerometerUpdates()
        #endif
    }

    nonisolated static func isAvailable() -> Bool {
        if let cachedAvailability {
            return cachedAvailability
        }
        #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        let available = CoreMotionSensorHub.shared.isAccelerometerAvailable
        #else
        let available = false
        #endif
        cachedAvailability = available
        return available
    }

    static func classify(x: Double, y: Double, z: Double) -> MotionGestureObservation? {
        let magnitude = sqrt((x * x) + (y * y) + (z * z))
        if magnitude >= 2.7 {
            return observation(
                gesture: "shake",
                confidence: min((magnitude - 1.0) / 2.4, 1.0),
                x: x,
                y: y,
                z: z,
                summary: "The device was shaken."
            )
        }
        if z <= -1.65 {
            return observation(
                gesture: "lift",
                confidence: min((abs(z) - 1.0) / 1.2, 1.0),
                x: x,
                y: y,
                z: z,
                summary: "The device was lifted quickly."
            )
        }
        if z >= 1.65 {
            return observation(
                gesture: "drop",
                confidence: min((z - 1.0) / 1.2, 1.0),
                x: x,
                y: y,
                z: z,
                summary: "The device moved downward quickly."
            )
        }
        if abs(x) >= 1.35, abs(x) > abs(y) {
            return observation(
                gesture: x > 0 ? "tilt_right" : "tilt_left",
                confidence: min((abs(x) - 0.9) / 0.8, 1.0),
                x: x,
                y: y,
                z: z,
                summary: x > 0 ? "The device was flicked to the right." : "The device was flicked to the left."
            )
        }
        if abs(y) >= 1.35 {
            return observation(
                gesture: y > 0 ? "tilt_backward" : "tilt_forward",
                confidence: min((abs(y) - 0.9) / 0.8, 1.0),
                x: x,
                y: y,
                z: z,
                summary: y > 0 ? "The device was flicked backward." : "The device was flicked forward."
            )
        }
        return nil
    }

    private func shouldEmit(_ gesture: String) -> Bool {
        let now = Date()
        defer { lastGestureAt[gesture] = now }
        guard let previous = lastGestureAt[gesture] else { return true }
        return now.timeIntervalSince(previous) >= 1.2
    }

    private static func observation(
        gesture: String,
        confidence: Double,
        x: Double,
        y: Double,
        z: Double,
        summary: String
    ) -> MotionGestureObservation {
        MotionGestureObservation(
            gesture: gesture,
            confidence: rounded(confidence),
            accelerationX: rounded(x),
            accelerationY: rounded(y),
            accelerationZ: rounded(z),
            summary: summary
        )
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
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
        return try await CoreMotionSensorHub.shared.observeOrientation()
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
