//
//  Live avatar facial expression state driven by core events.
//

import Foundation

struct QueuedFacialExpression {
    let eyes: String?
    let mouth: String?
    let durationSeconds: Double
}

extension AffectiveViewModel {
    var supportsAvatarFacialExpressions: Bool {
        guard let manifest = brain.avatarManifest else { return false }
        return manifest.layers.contains { $0.id == "eyes" && $0.atlas != nil }
            && manifest.layers.contains { $0.id == "mouth" && $0.atlas != nil }
    }

    func resetAvatarFacialExpression() {
        facialExpressionRevertTask?.cancel()
        facialExpressionRevertTask = nil
        queuedFacialExpressions.removeAll()
        applyingQueuedFacialExpression = false
        applyNeutralFacialExpressionSprites()
    }

    func applyNeutralFacialExpressionSprites() {
        guard let manifest = brain.avatarManifest else {
            avatarEyeSprite = nil
            avatarMouthSprite = nil
            return
        }
        avatarEyeSprite = manifest.neutralEyeSpriteName()
        avatarMouthSprite = manifest.neutralMouthSpriteName()
    }

    func handleAvatarDidUpdate(for brainID: String) {
        guard brain.id == brainID else { return }
        let library = BrainLibrary()
        library.refresh()
        guard let updated = library.brains.first(where: { $0.id == brainID }) else { return }
        reloadBrain(updated)
        guard isBrainConnected else { return }
        Task {
            do {
                _ = try await brainCore.refreshFacialExpressionCatalog()
            } catch {
                statusText = "Avatar saved, but expression catalog refresh failed: \(error.localizedDescription)"
            }
        }
    }

    func applyFacialExpressionFromEvent(_ event: BrainEvent) {
        guard supportsAvatarFacialExpressions else { return }

        let trimmedEyes = event.eyes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMouth = event.mouth?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEyes?.isEmpty == false || trimmedMouth?.isEmpty == false else { return }

        let durationSeconds = max(Double(event.facialExpressionDurationMS ?? 3_000) / 1_000.0, 0.1)
        queuedFacialExpressions.append(.init(
            eyes: trimmedEyes,
            mouth: trimmedMouth,
            durationSeconds: durationSeconds
        ))
        startNextQueuedFacialExpressionIfNeeded()
    }

    func startNextQueuedFacialExpressionIfNeeded() {
        guard !applyingQueuedFacialExpression else { return }
        guard !queuedFacialExpressions.isEmpty else { return }
        applyingQueuedFacialExpression = true
        let expression = queuedFacialExpressions.removeFirst()
        if let eyes = expression.eyes, !eyes.isEmpty {
            avatarEyeSprite = eyes
        }
        if let mouth = expression.mouth, !mouth.isEmpty {
            avatarMouthSprite = mouth
        }
        facialExpressionRevertTask?.cancel()
        facialExpressionRevertTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(expression.durationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.applyNeutralFacialExpressionSprites()
            self.applyingQueuedFacialExpression = false
            self.startNextQueuedFacialExpressionIfNeeded()
        }
    }
}

extension BrainEvent {
    var facialExpressionDurationMS: Int? {
        if let durationMS { return durationMS }
        guard case .capabilityRequest(let value) = payload,
              case .object(let arguments) = value.arguments
        else { return nil }
        if case .number(let value) = arguments["duration_ms"] {
            return Int(value)
        }
        if case .number(let value) = arguments["durationMS"] {
            return Int(value)
        }
        return nil
    }
}
