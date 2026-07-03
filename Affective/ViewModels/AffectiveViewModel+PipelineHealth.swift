//
//  AffectiveViewModel+PipelineHealth.swift
//  Affective
//

import Foundation

extension AffectiveViewModel {
    var showsHostPipelineDeadlockOverlay: Bool {
        guard let hostPipelineDeadlock else { return false }
        return hostPipelineDeadlockDismissedID != hostPipelineDeadlock.id
    }

    func dismissHostPipelineDeadlockOverlay() {
        guard let hostPipelineDeadlock else { return }
        hostPipelineDeadlockDismissedID = hostPipelineDeadlock.id
    }

    func startHostPipelineHealthMonitor() {
        stopHostPipelineHealthMonitor()
        hostPipelineHealthGeneration += 1
        let generation = hostPipelineHealthGeneration
        lastHostPipelineProgressAt = Date()
        hostPipelineHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.hostPipelineHealthGeneration == generation else { return }
                self.evaluateHostPipelineHealth()
            }
        }
    }

    func stopHostPipelineHealthMonitor() {
        hostPipelineHealthGeneration += 1
        hostPipelineHealthTask?.cancel()
        hostPipelineHealthTask = nil
        clearHostPipelineDeadlockState()
    }

    func clearHostPipelineDeadlockState() {
        coreAwaitingHostSenseMarker = nil
        hostPipelineActionStartedAt = nil
        pullSenseFulfillmentStartedAt = nil
        lastReportedDeadlockKind = nil
        hostPipelineDeadlock = nil
        hostPipelineDeadlockDismissedID = nil
    }

    func noteHostPipelineProgress(at date: Date = Date()) {
        lastHostPipelineProgressAt = date
    }

    func noteCoreAwaitingHostSense(metadata: [String: String], at date: Date = Date()) {
        noteHostPipelineProgress(at: date)
        coreAwaitingHostSenseMarker = CoreAwaitingHostSenseMarker(
            since: date,
            sense: Self.trimmedMetadataValue(metadata["awaited_host_sense"]),
            purpose: Self.trimmedMetadataValue(metadata["awaited_host_purpose"]),
            timeoutMS: Self.metadataIntValue(metadata["awaited_host_timeout_ms"]),
            requestID: Self.trimmedMetadataValue(metadata["request_id"])
        )
    }

    func noteCoreHostSenseWaitCleared() {
        coreAwaitingHostSenseMarker = nil
        noteHostPipelineProgress()
    }

    func noteCoreHostSenseWaitClearedAfterObservation(sense: String) {
        guard let marker = coreAwaitingHostSenseMarker else { return }
        guard marker.sense == nil || marker.sense == sense else { return }
        noteCoreHostSenseWaitCleared()
    }

    func ensureAwaitingHostSenseFulfillmentIfNeeded() {
        guard let marker = coreAwaitingHostSenseMarker,
              let sense = marker.sense?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sense.isEmpty else {
            return
        }
        let input = hostPipelineHealthInput()
        guard !HostPipelineHealthEvaluator.hostIsWorkingOnSense(sense, input: input) else {
            return
        }

        reopenAwaitedPullSenseRequestForRecovery(marker.requestID)
        let event = synthesizedPullSenseRequestEvent(
            sense: sense,
            requestID: marker.requestID,
            timeoutMS: marker.timeoutMS
        )
        let presentation = pullSenseObservationPresentation(
            for: event,
            mirrorChatMessages: false
        )
        appendEventLog(
            kind: .state,
            title: "host sense recovery",
            body: "Scheduled async pull sense fulfillment for awaited \(sense).",
            metadata: [
                "awaited_host_sense": sense,
                "request_id": marker.requestID ?? event.id,
            ]
        )
        scheduleAsyncPullSenseFulfillment(
            event: event,
            observationResponsePresentation: presentation
        )
    }

    func reopenAwaitedPullSenseRequestForRecovery(_ requestID: String?) {
        guard let requestID = requestID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestID.isEmpty else {
            return
        }
        closedPullSenseRequestIDs.remove(requestID)
        terminalPullSenseRequestIDs.remove(requestID)
    }

    func synthesizedPullSenseRequestEvent(
        sense: String,
        requestID: String?,
        timeoutMS: Int?
    ) -> BrainEvent {
        let resolvedRequestID = requestID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventID = (resolvedRequestID?.isEmpty == false) ? resolvedRequestID! : UUID().uuidString
        return BrainEvent(
            id: eventID,
            traceID: "host-recovery-\(eventID)",
            parentID: nil,
            turnID: nil,
            loopID: nil,
            occurredAt: BrainEvent.iso8601Now(),
            source: .brain,
            target: .host,
            visibility: .diagnostic,
            presentation: .internalOnly,
            payload: .senseRequest(BrainSenseRequestPayload(
                senseID: sense,
                direction: .pull,
                timeoutMS: timeoutMS ?? PullSenseHostTimeout.defaultMS,
                responsePresentation: .internalOnly
            ))
        )
    }

    func noteHostPipelineActionStarted(_ action: HostPipelineAction, at date: Date = Date()) {
        hostPipelineActionStartedAt = date
        noteHostPipelineProgress(at: date)
    }

    func noteHostPipelineActionFinished() {
        hostPipelineActionStartedAt = nil
        noteHostPipelineProgress()
    }

    func notePullSenseFulfillmentStarted(at date: Date = Date()) {
        if pullSenseFulfillmentStartedAt == nil {
            pullSenseFulfillmentStartedAt = date
        }
        noteHostPipelineProgress(at: date)
    }

    func notePullSenseFulfillmentFinished() {
        if activePullSenseFulfillmentCount == 0 {
            pullSenseFulfillmentStartedAt = nil
        }
        noteHostPipelineProgress()
    }

    func noteBrainResponseMetadata(_ metadata: [String: String]) {
        if metadata["awaiting_host_sense"] == "true" {
            noteCoreAwaitingHostSense(metadata: metadata)
        } else {
            noteCoreHostSenseWaitCleared()
        }
    }

    func evaluateHostPipelineHealth(now: Date = Date()) {
        ensureAwaitingHostSenseFulfillmentIfNeeded()
        let input = hostPipelineHealthInput(now: now)
        guard let deadlock = HostPipelineHealthEvaluator.evaluate(input) else {
            if hostPipelineDeadlock != nil {
                hostPipelineDeadlock = nil
                lastReportedDeadlockKind = nil
            }
            return
        }

        let shouldPublish = hostPipelineDeadlock?.kind != deadlock.kind
            || hostPipelineDeadlock?.title != deadlock.title
        if shouldPublish {
            hostPipelineDeadlock = deadlock
            if lastReportedDeadlockKind != deadlock.kind {
                lastReportedDeadlockKind = deadlock.kind
                appendEventLog(
                    kind: .error,
                    title: "host pipeline deadlock",
                    body: deadlock.detail,
                    metadata: deadlock.diagnostics.merging(["kind": deadlock.kind.rawValue]) { current, _ in current }
                )
            }
        }
    }

    func hostPipelineHealthInput(now: Date = Date()) -> HostPipelineHealthInput {
        HostPipelineHealthInput(
            now: now,
            isBrainConnected: isBrainConnected,
            coreAwaitingHostSense: coreAwaitingHostSenseMarker,
            isHostPipelineRunning: isHostPipelineRunning,
            hostPipelineActionStartedAt: hostPipelineActionStartedAt,
            hostPipelineActionKind: currentHostPipelineAction?.healthKind,
            hostPipelineHold: hostPipelineHold,
            queuedConversationActionCount: hostPipelineQueue.filter(\.isConversation).count,
            lastHostPipelineProgressAt: lastHostPipelineProgressAt,
            activePullSenseFulfillmentCount: activePullSenseFulfillmentCount,
            pullSenseFulfillmentStartedAt: pullSenseFulfillmentStartedAt,
            pendingCameraRequestID: pendingCameraRequestID,
            pendingOrientationRequestID: pendingOrientationRequestID,
            hasPullSenseInQueue: hostPipelineQueue.contains { action in
                if case .pullSenseRequest = action { return true }
                return false
            },
            isToolRunning: isToolRunning
        )
    }

    private static func trimmedMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func metadataIntValue(_ value: String?) -> Int? {
        guard let trimmed = trimmedMetadataValue(value) else { return nil }
        return Int(trimmed)
    }
}

extension HostPipelineAction {
    var isConversation: Bool {
        switch self {
        case .typedText, .imageText, .interrupt:
            return true
        default:
            return false
        }
    }

    var healthKind: String {
        switch self {
        case .interrupt:
            return "experience:interrupt"
        case .typedText:
            return "experience:counterpart_speech"
        case .imageText:
            return "image_text"
        case .pullSenseRequest(let event, _):
            return "pull_sense:\(event.sense ?? event.senseID ?? "unknown")"
        case .coreTouch(let name, _):
            return name
        case .pokeSequence:
            return "experience:poke_sequence"
        case .pushedMotionGesture(let observation):
            return "pushed_motion_gesture:\(observation.gesture)"
        case .boredomStimulus:
            return "experience:host_boredom"
        case .refreshBrainState:
            return "refresh_brain_state"
        case .collectMailbox:
            return "collect_mailbox"
        case .mailboxMarkRead:
            return "mailbox_mark_read"
        }
    }
}
