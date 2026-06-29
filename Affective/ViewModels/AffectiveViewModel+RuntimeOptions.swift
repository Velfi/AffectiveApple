//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation
import Combine

extension AffectiveViewModel {
    var biometricPolicy: BiometricDataPolicy {
        BiometricDataPolicy.load(for: brain)
    }

    var biometricTemplateSummaries: [BiometricTemplateSummary] {
        BiometricTemplateSummary.load(from: brain)
    }

    func deleteAllBiometricData() {
        Task {
            guard !isToolRunning else {
                statusText = "Core call already running"
                return
            }

            isToolRunning = true
            defer { isToolRunning = false }

            await brainCore.disconnect()
            isBrainConnected = false
            stopBoredomSense()

            do {
                let library = BrainLibrary()
                try library.deleteBiometricData(for: brain)
                statusText = "Deleted biometric data"
                appendEventLog(kind: .sent, title: "delete biometric data", body: "Deleted face templates and biometric metadata.")
            } catch {
                statusText = "Could not delete biometric data"
                appendEventLog(kind: .error, title: "delete biometric data failed", body: error.localizedDescription)
            }
        }
    }

    func disableRecognitionAndDeleteBiometricData() {
        Task {
            guard !isToolRunning else {
                statusText = "Core call already running"
                return
            }

            isToolRunning = true
            defer { isToolRunning = false }

            await brainCore.disconnect()
            isBrainConnected = false
            stopBoredomSense()

            do {
                let library = BrainLibrary()
                try library.disableRecognitionAndDeleteBiometricData(for: brain)
                optionGroups = Self.loadOptionGroups(storedValues: Self.storedValuesForLaunch(brain: brain), brain: brain)
                statusText = "Recognition disabled and biometric data deleted"
                appendEventLog(kind: .sent, title: "disable biometric recognition", body: "Disabled recognition and deleted biometric data.")
            } catch {
                statusText = "Could not disable recognition"
                appendEventLog(kind: .error, title: "disable biometric recognition failed", body: error.localizedDescription)
            }
        }
    }

    var motionGestureOptionEnabled: Bool {
        runtimeOptionStringValue(for: Self.motionGestureEnabledOptionKey) == "on"
    }

    func testCredential(_ key: ProviderCredentialKey, candidate: String) async {
        credentialTestResults[key] = .testing
        appendEventLog(kind: .sent, title: "test \(key.displayName) key", body: "<redacted>")

        do {
            let credential = try credentialToTest(key: key, candidate: candidate)
            try await ProviderCredentialTester.test(key: key, credential: credential)
            credentialTestResults[key] = .valid
            statusText = "\(key.displayName) key works"
            appendEventLog(kind: .result, title: "test \(key.displayName) key", body: "Credential accepted.")
        } catch {
            credentialTestResults[key] = .invalid(error.localizedDescription)
            statusText = "\(key.displayName) key failed"
            appendEventLog(kind: .error, title: "test \(key.displayName) key failed", body: error.localizedDescription)
        }
    }

    func credentialToTest(key: ProviderCredentialKey, candidate: String) throws -> String {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCandidate.isEmpty {
            return trimmedCandidate
        }
        guard let storedCredential = try Self.credentialStore.credential(for: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !storedCredential.isEmpty else {
            throw CredentialTestError.missingCredential(key.displayName)
        }
        return storedCredential
    }

    func callCoreTouch(name: String, title: String) async {
        let metadata = toolMetadata(name: name, mirrorToChat: false)
        recordRecentStimulus(
            kind: name,
            summary: "User sent \(title).",
            metadata: metadata
        )
        await callCoreStimulus(
            title: title,
            sentBody: "event_type=\(name)",
            inProgressStatus: "Calling \(title)",
            completeStatus: "\(title) complete",
            failedStatus: "\(title) failed",
            emptyDisplayText: "\(title) complete",
            metadata: metadata
        ) {
            switch name {
            case "short_touch":
                return try await brainCore.shortTouch()
            case "long_touch":
                return try await brainCore.longTouch()
            default:
                throw BrainCoreError.unavailable("Unsupported touch event \(name).")
            }
        }
    }

    func callCorePokeSequence(_ pulses: [PokePulse]) async {
        guard !pulses.isEmpty else { return }
        let title = "poke_sequence"
        let metadata = pokeMetadata(pulses: pulses, mirrorToChat: false)
        await callCoreStimulus(
            title: title,
            sentBody: metadata["rhythm"] ?? "poke",
            inProgressStatus: "Sending poke",
            completeStatus: "Poke sent",
            failedStatus: "Poke failed",
            emptyDisplayText: "Poke received",
            metadata: metadata
        ) {
            try await brainCore.pokeSequence(pulses)
        }
    }

    func sendPushedMotionGestureObservation(_ observation: MotionGestureObservation) async {
        let metadata = motionGestureMetadata(observation)
        await callCoreStimulus(
            title: "pushed_motion_gesture",
            sentBody: observation.summary,
            inProgressStatus: "Sending motion gesture",
            completeStatus: "Motion gesture sent",
            failedStatus: "Motion gesture failed",
            emptyDisplayText: observation.summary,
            metadata: metadata
        ) {
            try await brainCore.pushedMotionGestureObservation(observation, presentation: .internalOnly)
        }
    }

    func callCoreStimulus(
        title: String,
        sentBody: String,
        inProgressStatus: String,
        completeStatus: String,
        failedStatus: String,
        emptyDisplayText: String,
        metadata: [String: String],
        send: () async throws -> BrainToolResponse
    ) async {
        guard !isToolRunning else {
            statusText = "Core call already running"
            return
        }

        isToolRunning = true
        defer { isToolRunning = false }

        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else {
                throw BrainCoreError.unavailable("The core is not connected.")
            }

            statusText = inProgressStatus
            appendEventLog(kind: .sent, title: title, body: sentBody, metadata: metadata)
            let response = try await send()
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayText = responseText.isEmpty
                ? emptyDisplayText
                : response.text
            let eventResult = await applyCoreEvents(response.events, mirrorChatMessages: true, speak: response.shouldSpeak)
            statusText = completeStatus
            appendEventLog(kind: .result, title: title, body: displayText, metadata: response.metadata.merging(metadata) { current, _ in current })
            _ = eventResult
            refreshMailboxItems()
        } catch {
            isBrainConnected = false
            statusText = failedStatus
            appendEventLog(kind: .error, title: "\(title) failed", body: error.localizedDescription, metadata: metadata)
        }
    }

    static func pausedForHostSenseLabel(metadata: [String: String]) -> String {
        let sense = metadata["awaited_host_sense"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let purpose = metadata["awaited_host_purpose"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutSuffix = hostSenseTimeoutSuffix(metadata: metadata)
        if !sense.isEmpty, !purpose.isEmpty {
            return "paused for host sense: \(sense)/\(purpose)\(timeoutSuffix)"
        }
        if !sense.isEmpty {
            return "paused for host sense: \(sense)\(timeoutSuffix)"
        }
        return "paused for host sense\(timeoutSuffix)"
    }

    static func awaitingHostSenseStatusText(metadata: [String: String]) -> String {
        let sense = metadata["awaited_host_sense"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let purpose = metadata["awaited_host_purpose"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutSuffix = hostSenseTimeoutSuffix(metadata: metadata)
        if !sense.isEmpty, !purpose.isEmpty {
            return "Waiting for \(sense) (\(purpose))\(timeoutSuffix)"
        }
        if !sense.isEmpty {
            return "Waiting for \(sense)\(timeoutSuffix)"
        }
        return "Waiting for host sense\(timeoutSuffix)"
    }

    private static func hostSenseTimeoutSuffix(metadata: [String: String]) -> String {
        guard let raw = metadata["awaited_host_timeout_ms"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let timeoutMS = Int(raw),
              timeoutMS > 0
        else { return "" }
        return " (\(timeoutMS)ms)"
    }

    func conversationDisplaySummary(responseText: String, metadata: [String: String]) -> String {
        let spoken = metadata["spoken_text_present"] ?? "unknown"
        let brainSummary = metadata["brain_summary_present"] ?? "unknown"
        let userSummary = metadata["user_summary_present"] ?? "unknown"
        let length = metadata["display_text_length"] ?? "\(responseText.count)"
        return [
            "display_text_empty=\(responseText.isEmpty)",
            "display_text_length=\(length)",
            "spoken_text_present=\(spoken)",
            "user_summary_present=\(userSummary)",
            "brain_summary_present=\(brainSummary)",
        ].joined(separator: "\n")
    }

    func applyCoreEvents(
        _ events: [BrainEvent],
        mirrorChatMessages: Bool,
        speak: Bool,
        handleHostRequests: Bool = true
    ) async -> (
        didAppendBrainChat: Bool,
        didRequestSpeech: Bool,
        didApplyActivityStatus: Bool,
        didRecordBrainTurn: Bool,
        resolvedBrainText: String?
    ) {
        var didAppendBrainChat = false
        var speechText: String?
        var resolvedBrainText: String?
        var didApplyActivityStatus = false
        var didRecordBrainTurn = false
        var didEmitSocialSignal = false
        let coreEvents = normalizedCoreEvents(events)

        for event in coreEvents {
            let metadata = coreEventMetadata(event)
            if shouldPlayBotActionClick(for: event) {
                notificationSounds.playBotActionClick()
            }
            switch event.type {
            case "control":
                if event.state == "send_enabled", let enabled = event.enabled {
                    canSend = enabled
                    statusText = enabled ? "Ready" : (brainVoiceEnabled ? "Affective is speaking" : "Affective is thinking")
                }
            case "developer_log":
                let title = event.title ?? "developer_log"
                appendEventLog(
                    kind: logKind(for: event.kind, title: title),
                    title: title,
                    body: event.text ?? event.body ?? "",
                    metadata: metadata
                )
            case "mise_en_scene":
                if case .miseEnScene(let payload) = event.payload {
                    applyMiseEnScene(name: payload.name, themeColor: payload.themeColor)
                }
            case "thought", "appraisal", "need_state", "attention_state", "intention", "memory_result", "memory_mutation":
                appendEventLog(
                    kind: logKind(for: event.kind),
                    title: event.title ?? event.state ?? "core state",
                    body: event.text ?? event.body ?? "",
                    metadata: metadata
                )
                if event.type == "attention_state" && event.presentation == .status {
                    let summary = event.text ?? event.body ?? event.state ?? ""
                    if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        statusText = summary
                        didApplyActivityStatus = true
                    }
                }
            case "expression":
                if expressionIsPublic(event), isSelfEventRole(event.role ?? "self") {
                    switch expressionModality(for: event) {
                    case "face", "facial_expression":
                        applyFacialExpressionFromEvent(event)
                        logFacialExpressionEvent(event, metadata: metadata)
                    case "emote":
                        logEmoteEvent(event, metadata: metadata)
                    default:
                        break
                    }
                }
                if expressionIsPublic(event),
                   isSelfEventRole(event.role ?? "self"),
                   expressionModality(for: event) == "emote" {
                    let body = emoteBody(from: event)
                    guard !body.isEmpty else { continue }
                    chatEntries.append(.init(
                        kind: .emote,
                        title: chatSenderTitle(for: event.title),
                        body: body,
                        metadata: metadata
                    ))
                    recordConversationTurn(role: "self", text: "*\(body)*", source: event.type, metadata: metadata)
                    didAppendBrainChat = true
                    didRecordBrainTurn = true
                    didEmitSocialSignal = true
                    continue
                }
                guard mirrorChatMessages else { continue }
                guard expressionIsPublic(event) else { continue }
                let role = event.role ?? "self"
                guard isSelfEventRole(role) else { continue }
                switch expressionModality(for: event) {
                case "text", "image", "audio", "media":
                    let body = event.text ?? event.body ?? event.caption ?? ""
                    let hasMedia = event.path != nil || event.url != nil
                    guard hasMedia || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    resolvedBrainText = body
                    chatEntries.append(.init(
                        kind: .brain,
                        title: chatSenderTitle(for: event.title),
                        body: body,
                        metadata: metadata
                    ))
                    recordConversationTurn(role: "self", text: body, source: event.type, metadata: metadata)
                    didAppendBrainChat = true
                    didRecordBrainTurn = true
                    didEmitSocialSignal = true
                case "face", "facial_expression":
                    if !facialExpressionSummary(for: event).isEmpty {
                        didEmitSocialSignal = true
                    }
                default:
                    appendEventLog(
                        kind: .state,
                        title: event.title ?? "expression",
                        body: event.text ?? event.body ?? event.caption ?? "",
                        metadata: metadata
                    )
                }
            case "capability_request":
                if event.capability == "speak",
                   let text = event.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speechText = text
                    if eventPresentation(for: event).mirrorsToChat {
                        resolvedBrainText = text
                        didEmitSocialSignal = true
                    }
                }
                if isFacialExpressionCapability(event.capability),
                   eventPresentation(for: event).mirrorsToChat,
                   !facialExpressionSummary(for: event).isEmpty {
                    didEmitSocialSignal = true
                }
                if isFacialExpressionCapability(event.capability) {
                    applyFacialExpressionFromEvent(event)
                    logFacialExpressionEvent(event, metadata: metadata)
                } else if event.capability == "sense_catalog" {
                    appendEventLog(
                        kind: .state,
                        title: event.title ?? "sense catalog",
                        body: event.body ?? event.text ?? "sense catalog requested",
                        metadata: metadata
                    )
                    if handleHostRequests {
                        await sendSenseCatalog(requestID: event.requestID)
                    }
                } else if event.capability == "sense_status" {
                    appendEventLog(
                        kind: .state,
                        title: event.title ?? "sense status",
                        body: event.body ?? event.text ?? "sense status requested",
                        metadata: metadata
                    )
                    if handleHostRequests {
                        await sendSenseStatus(for: event.sense ?? event.senseID, requestID: event.requestID)
                    }
                }
            case "sense_request":
                appendEventLog(
                    kind: .state,
                    title: event.title ?? event.type,
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
                if handleHostRequests {
                    let observationPresentation: BrainEventPresentation = mirrorChatMessages ? .chat : .internalOnly
                    enqueueHostPipelineAction(.pullSenseRequest(event, observationPresentation))
                }
            default:
                appendEventLog(
                    kind: .state,
                    title: event.title ?? event.type,
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
            }
        }

        if speak, let speechText {
            if !didRecordBrainTurn {
                recordConversationTurn(role: "self", text: speechText, source: "capability_request", metadata: [:])
                didRecordBrainTurn = true
            }
            if BrainSpeechNotificationPolicy.shouldNotify(isForeground: appIsForeground, text: speechText) {
                let posted = await brainSpeechNotifications.postIfAuthorized(
                    brainID: brain.id,
                    brainName: brain.displayName,
                    text: speechText
                )
                if !posted {
                    let status = await brainSpeechNotifications.authorizationStatus()
                    appendEventLog(
                        kind: .state,
                        title: "brain speech notification",
                        body: "not delivered",
                        metadata: [
                            "brain": brain.id,
                            "authorization": status.rawValue,
                        ]
                    )
                }
                if didEmitSocialSignal {
                    markAwaitingSocialResponse()
                }
                return (didAppendBrainChat, false, didApplyActivityStatus, didRecordBrainTurn, resolvedBrainText)
            }
            await speakBrainResponseAndWait(speechText)
            return (didAppendBrainChat, true, didApplyActivityStatus, didRecordBrainTurn, resolvedBrainText)
        }
        if let speechText, !didRecordBrainTurn {
            recordConversationTurn(role: "self", text: speechText, source: "capability_request", metadata: [:])
            didRecordBrainTurn = true
        }
        if didEmitSocialSignal {
            markAwaitingSocialResponse()
        }
        return (didAppendBrainChat, false, didApplyActivityStatus, didRecordBrainTurn, resolvedBrainText)
    }

    func shouldPlayBotActionClick(for event: BrainEvent) -> Bool {
        guard event.source == .brain else { return false }
        if event.enabled != nil { return false }
        guard event.type == "control" else { return false }
        let marker = [
            event.title,
            event.status,
            event.text,
            event.body,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let marker else { return false }
        if marker == "Brain" { return false }
        if marker == "send_enabled" { return false }
        // Host control events for executed skills use snake_case action ids.
        return marker.range(of: #"^[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
    }

    func normalizedCoreEvents(_ events: [BrainEvent]) -> [BrainEvent] {
        events
    }

    func cameraSenseRequestEvent(from event: BrainEvent) -> BrainEvent {
        BrainEvent.hostEvent(
            payload: .senseRequest(BrainSenseRequestPayload(
                senseID: "camera",
                direction: .pull,
                timeoutMS: 10_000,
                responsePresentation: .chat
            )),
            target: .host,
            visibility: .diagnostic,
            presentation: .chat,
            traceID: event.traceID,
            parentID: event.id,
            turnID: event.turnID,
            loopID: event.loopID
        )
    }

    func observationResponsePresentation(for event: BrainEvent) -> BrainEventPresentation {
        if let presentation = event.responsePresentation.flatMap(BrainEventPresentation.init(rawValue:)) {
            return presentation
        }
        guard let currentHostPipelineAction else { return .chat }
        switch currentHostPipelineAction {
        case .typedText, .imageText, .interrupt:
            return .internalOnly
        case .pullSenseRequest(_, let presentation):
            return presentation
        case .coreTouch, .pokeSequence:
            return .chat
        case .pushedMotionGesture, .boredomStimulus:
            return .internalOnly
        case .refreshBrainState, .collectMailbox, .mailboxMarkRead:
            return .internalOnly
        }
    }

    func eventPresentation(for event: BrainEvent) -> BrainEventPresentation {
        event.presentation
    }

    func expressionIsPublic(_ event: BrainEvent) -> Bool {
        event.visibility == .public
    }

    func expressionModality(for event: BrainEvent) -> String {
        event.modality?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? event.mediaKind ?? "text"
    }

    func fulfillSenseRequest(_ event: BrainEvent, observationResponsePresentation: BrainEventPresentation) async {
        let requestID = pullSenseRequestID(for: event)
        switch event.sense {
        case "camera":
            await awaitPullSenseFulfillment(event: event, sense: "camera", requestID: requestID) {
                await self.fulfillCameraSenseRequest(
                    event,
                    requestID: requestID,
                    observationResponsePresentation: observationResponsePresentation
                )
            }
        case "orientation":
            await awaitPullSenseFulfillment(event: event, sense: "orientation", requestID: requestID) {
                await self.fulfillOrientationRequest(
                    event,
                    requestID: requestID,
                    observationResponsePresentation: observationResponsePresentation
                )
            }
        default:
            await sendPullSenseStatus(
                sense: event.sense ?? event.senseID ?? "unknown",
                status: .unsupported,
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "Unsupported pull sense requested by brain.",
                availability: "unavailable",
                permissionState: "unavailable",
                terminal: true
            )
        }
    }

    var avatarDisplaysExpressions: Bool {
        supportsAvatarFacialExpressions
    }

    func facialExpressionSummary(for event: BrainEvent) -> String {
        [event.eyes, event.mouth]
            .compactMap { $0 }
            .compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " / ")
    }

    func isFacialExpressionCapability(_ capability: String?) -> Bool {
        switch capability {
        case "show_expression", "facial_expression", "facial_expression_output":
            return true
        default:
            return false
        }
    }

    func logFacialExpressionEvent(_ event: BrainEvent, metadata: [String: String]) {
        let summary = facialExpressionSummary(for: event)
        guard !summary.isEmpty else { return }
        appendEventLog(
            kind: .state,
            title: "facial expression",
            body: summary,
            metadata: metadata
        )
    }

    func logEmoteEvent(_ event: BrainEvent, metadata: [String: String]) {
        let body = emoteBody(from: event)
        guard !body.isEmpty else { return }
        appendEventLog(
            kind: .state,
            title: "emote",
            body: body,
            metadata: metadata
        )
    }

    func emoteBody(from event: BrainEvent) -> String {
        let raw = event.text ?? event.body ?? ""
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.hasPrefix("*"),
              trimmed.hasSuffix("*") else {
            return trimmed
        }
        trimmed.removeFirst()
        trimmed.removeLast()
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func coreEventMetadata(_ event: BrainEvent) -> [String: String] {
        var metadata = [
            "source": "core_event",
            "event_type": event.type,
            "event_id": event.id,
        ]
        if let requestID = event.requestID { metadata["request_id"] = requestID }
        if let turnID = event.turnID { metadata["turn_id"] = turnID }
        if let expressionID = event.expressionID { metadata["expression_id"] = expressionID }
        if let modality = event.modality { metadata["modality"] = modality }
        metadata["visibility"] = event.visibility.rawValue
        if let role = event.role { metadata["role"] = role }
        if let kind = event.kind { metadata["kind"] = kind }
        if let sense = event.sense { metadata["sense"] = sense }
        if let senseID = event.senseID { metadata["sense_id"] = senseID }
        if let senseDirection = event.senseDirection { metadata["sense_direction"] = senseDirection }
        if let capability = event.capability { metadata["capability"] = capability }
        if let status = event.status { metadata["status"] = status }
        if let reason = event.reason { metadata["reason"] = reason }
        if let availability = event.availability { metadata["availability"] = availability }
        if let permissionState = event.permissionState { metadata["permission"] = permissionState }
        if let statusReason = event.statusReason { metadata["unavailable_reason"] = statusReason }
        if let observedAt = event.observedAt { metadata["observed_at"] = observedAt }
        if let terminal = event.terminal { metadata["terminal"] = String(terminal) }
        if let awaitResponse = event.awaitResponse { metadata["await_response"] = String(awaitResponse) }
        if let timeoutMS = event.timeoutMS { metadata["timeout_ms"] = "\(timeoutMS)" }
        if let enabled = event.enabled { metadata["enabled"] = String(enabled) }
        if let eyes = event.eyes { metadata["eyes"] = eyes }
        if let mouth = event.mouth { metadata["mouth"] = mouth }
        if let durationMS = event.durationMS { metadata["duration_ms"] = "\(durationMS)" }
        if let mediaKind = event.mediaKind { metadata["media_kind"] = mediaKind }
        if let path = event.path {
            metadata["path"] = path
            if event.mediaKind == "image" {
                metadata["image_path"] = path
            } else if event.mediaKind == "audio" {
                metadata["audio_path"] = path
            }
        }
        if let url = event.url {
            metadata["url"] = url
            if event.mediaKind == "image" {
                metadata["image_url"] = url
            } else if event.mediaKind == "audio" {
                metadata["audio_url"] = url
            }
        }
        if let mimeType = event.mimeType { metadata["mime_type"] = mimeType }
        if let caption = event.caption { metadata["caption"] = caption }
        metadata["presentation"] = event.presentation.rawValue
        if let responsePresentation = event.responsePresentation { metadata["response_presentation"] = responsePresentation }
        return metadata
    }

    func isSelfEventRole(_ rawRole: String) -> Bool {
        let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return role == "self" || role == "brain" || role == "bot" || role == "assistant" || role == "agent"
    }

    var brainSenderName: String {
        brainPresentationName ?? "A brain"
    }

    func applyMiseEnScene(name: String, themeColor: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        brainPresentationName = trimmedName
        AppTheme.applyMiseEnScene(name: trimmedName, themeColor: themeColor)
        appendEventLog(
            kind: .state,
            title: "mise en scene",
            body: themeColor.map { "\(trimmedName) · \($0)" } ?? trimmedName,
            metadata: [
                "event_type": "mise_en_scene",
                "brain_name": trimmedName,
                "theme_color": themeColor ?? "",
            ]
        )
    }

    func chatSenderTitle(for _: String?) -> String {
        brainSenderName
    }

    func logKind(for coreKind: String?, title: String? = nil) -> LogKind {
        if let title, title.hasPrefix("turn.") {
            return .process
        }
        guard let coreKind else { return .state }
        if coreKind == "process" { return .process }
        return LogKind(rawValue: coreKind) ?? .state
    }

    func toolMetadata(name: String, mirrorToChat: Bool) -> [String: String] {
        [
            "brain": brain.id,
            "admin_type": "core_tool",
            "tool": name,
            "mirror_to_chat": String(mirrorToChat),
        ]
    }

    func ignoredStimulusMetadata(response: BrainToolResponse, stimulusMetadata: [String: String]) -> [String: String] {
        var metadata = response.metadata.merging(stimulusMetadata) { current, _ in current }
        let existingReason = metadata["ignored_because"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingReason?.isEmpty == false {
            metadata["ignored_because"] = existingReason
        } else {
            metadata.removeValue(forKey: "ignored_because")
        }
        return metadata
    }

    func appendEventLog(kind: LogKind, title: String, body: String, metadata: [String: String] = [:]) {
        var entryMetadata = metadata
        entryMetadata["stream"] = "events"
        eventEntries.append(.init(kind: kind, title: title, body: body, metadata: entryMetadata))
    }

    func filtered(entries: [LogEntry], query: String, kind: LogKind?) -> [LogEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let kind, entry.kind != kind {
                return false
            }
            guard !trimmedQuery.isEmpty else {
                return true
            }
            let searchable = [
                entry.kind.rawValue,
                entry.title,
                entry.body,
                entry.metadata.map { "\($0.key):\($0.value)" }.joined(separator: " "),
            ].joined(separator: " ")
            return searchable.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func runtimeOptionIntValue(for key: String) -> Int? {
        guard let value = runtimeOptionStringValue(for: key) else {
            return nil
        }
        return Int(value)
    }

    func runtimeOptionStringValue(for key: String) -> String? {
        guard let value = optionGroups
            .flatMap(\.options)
            .first(where: { $0.key == key })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func setRuntimeOptionValue(_ key: String, value: String, commit: Bool) {
        var groups = optionGroups
        for groupIndex in groups.indices {
            guard let optionIndex = groups[groupIndex].options.firstIndex(where: { $0.key == key }) else {
                continue
            }
            groups[groupIndex].options[optionIndex].value = value
            if commit {
                groups[groupIndex].options[optionIndex].committedValue = value
            }
            optionGroups = groups
            return
        }
    }

    func parsedTags(_ rawValue: String) -> [String] {
        rawValue
            .split { character in
                character == "," || character == " " || character == "\n" || character == "\t"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func argumentSummary(_ arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        let object = JSONValue.object(arguments)
        guard let data = try? object.encodedData(),
              let text = String(data: data, encoding: .utf8) else {
            return "\(arguments.keys.sorted().joined(separator: ", "))"
        }
        return text
    }

    static func loadOptionGroups() -> [RuntimeOptionGroup] {
        loadOptionGroups(storedValues: storedValuesForLaunch(brain: nil), brain: nil)
    }

    static func loadOptionGroups(storedValues: [String: String], brain: BrainDescriptor?) -> [RuntimeOptionGroup] {
        var groups = RuntimeOptionGroup.defaults
        refreshHostRuntimeOptions(in: &groups)
        if let brain {
            for groupIndex in groups.indices {
                for optionIndex in groups[groupIndex].options.indices {
                    switch groups[groupIndex].options[optionIndex].key {
                    case "brain_id":
                        groups[groupIndex].options[optionIndex].value = brain.id
                        groups[groupIndex].options[optionIndex].committedValue = brain.id
                    case "face_embeddings_dir":
                        groups[groupIndex].options[optionIndex].value = brain.faceEmbeddingsURL.path
                        groups[groupIndex].options[optionIndex].committedValue = brain.faceEmbeddingsURL.path
                    default:
                        break
                    }
                }
            }
        }

        let configuredCredentials = keychainCredentialKeys()
        for groupIndex in groups.indices {
            for optionIndex in groups[groupIndex].options.indices {
                var option = groups[groupIndex].options[optionIndex]
                guard !option.isReadOnly else { continue }
                if option.isSecret {
                    option.hasStoredSecret = configuredCredentials.contains(option.key)
                    option.value = ""
                    option.committedValue = ""
                    groups[groupIndex].options[optionIndex] = option
                } else if let storedValue = storedValues[option.key] {
                    let resolvedValue = option.key == "autonomy_mode"
                        ? Self.normalizeAutonomyMode(storedValue)
                        : storedValue
                    option.value = resolvedValue
                    option.committedValue = resolvedValue
                    if case .select(let choices) = option.kind,
                       !choices.contains(where: { $0.value == resolvedValue }) {
                        option.kind = .select(([RuntimeOptionChoice(value: resolvedValue, label: resolvedValue)] + choices).uniqued())
                    }
                    groups[groupIndex].options[optionIndex] = option
                }
            }
        }

        return groups
    }

    static func refreshHostRuntimeOptions(in groups: inout [RuntimeOptionGroup]) {
        for groupIndex in groups.indices {
            for optionIndex in groups[groupIndex].options.indices
            where groups[groupIndex].options[optionIndex].key == cameraDeviceIDOptionKey {
                groups[groupIndex].options[optionIndex].kind = .select(cameraDeviceOptionChoices())
            }
        }
    }

    static func storedValuesForLaunch(brain: BrainDescriptor?) -> [String: String] {
        return (try? loadStoredOptionValues(brain: brain)) ?? [:]
    }

    static func loadStoredOptionValues(brain: BrainDescriptor?) throws -> [String: String] {
        let url = runtimeOptionsURL(brain: brain)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [:] }

        return dictionary.reduce(into: [String: String]()) { values, entry in
            if secretOptionKeys.contains(entry.key) {
                return
            }
            if let string = entry.value as? String {
                values[entry.key] = string
            } else if BiometricPolicyKeys.booleanOptionKeys.contains(entry.key),
                      let number = entry.value as? NSNumber {
                values[entry.key] = number.boolValue ? "on" : "off"
            } else if let number = entry.value as? NSNumber {
                values[entry.key] = number.stringValue
            }
        }
    }

    func saveOptions() throws {
        let url = Self.runtimeOptionsURL(brain: brain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var storedValues = try Self.loadRuntimeOptionsObject(brain: brain)
        Self.removeStoredSecrets(from: &storedValues)
        for option in optionGroups.flatMap(\.options) where !option.isReadOnly {
            if let credentialKey = ProviderCredentialKey(rawValue: option.key) {
                guard option.isDirty else {
                    storedValues.removeValue(forKey: option.key)
                    continue
                }
                let credential = option.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if option.shouldDeleteSecret {
                    try Self.credentialStore.deleteCredential(for: credentialKey)
                } else if !credential.isEmpty {
                    try Self.credentialStore.saveCredential(credential, for: credentialKey)
                }
                storedValues.removeValue(forKey: option.key)
            } else if option.key == "autonomy_mode" {
                storedValues[option.key] = Self.normalizeAutonomyMode(option.value)
            } else {
                storedValues[option.key] = option.jsonValue
            }
        }
        if (storedValues[BiometricPolicyKeys.exportIncluded] as? Bool) == true {
            storedValues[BiometricPolicyKeys.exportConfirmationRequired] = true
        }
        if storedValues["autonomy_mode"] == nil {
            storedValues["autonomy_mode"] = normalizedAutonomyMode
        }

        let data = try JSONSerialization.data(withJSONObject: storedValues, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func saveAutonomyMode() throws {
        let url = Self.runtimeOptionsURL(brain: brain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var storedValues = try Self.loadRuntimeOptionsObject(brain: brain)
        storedValues["autonomy_mode"] = normalizedAutonomyMode
        Self.removeStoredSecrets(from: &storedValues)

        let data = try JSONSerialization.data(withJSONObject: storedValues, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func saveRuntimeOption(key: String, value: Any) throws {
        let url = Self.runtimeOptionsURL(brain: brain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var storedValues = try Self.loadRuntimeOptionsObject(brain: brain)
        storedValues[key] = value
        Self.removeStoredSecrets(from: &storedValues)

        let data = try JSONSerialization.data(withJSONObject: storedValues, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func loadRuntimeOptionsObject(brain: BrainDescriptor?) throws -> [String: Any] {
        let url = runtimeOptionsURL(brain: brain)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [:] }
        return sanitizeDeprecatedRuntimeOptions(dictionary)
    }

    static func removeStoredSecrets(from storedValues: inout [String: Any]) {
        for key in ProviderCredentialKey.allCases {
            storedValues.removeValue(forKey: key.rawValue)
        }
    }

    static func keychainCredentialValues() -> [String: String] {
        ProviderCredentialKey.allCases.reduce(into: [String: String]()) { values, key in
            guard let credential = try? credentialStore.credential(for: key),
                  !credential.isEmpty else {
                return
            }
            values[key.rawValue] = credential
        }
    }

    static func keychainCredentialKeys() -> Set<String> {
        Set(keychainCredentialValues().keys)
    }

    func pokeMetadata(pulses: [PokePulse], mirrorToChat: Bool) -> [String: String] {
        let rhythm = pulses
            .map { pulse in
                "\(Int(pulse.pressMilliseconds.rounded()))ms"
            }
            .joined(separator: " / ")
        let pauses = pulses
            .map { pulse in
                "\(Int(pulse.pauseBeforeMilliseconds.rounded()))ms"
            }
            .joined(separator: " / ")
        return [
            "tool": "poke_sequence",
            "event_type": "poke_sequence",
            "pulse_count": "\(pulses.count)",
            "rhythm": rhythm,
            "pauses_before": pauses,
            "mirror_to_chat": String(mirrorToChat),
        ]
    }

    func motionGestureMetadata(_ observation: MotionGestureObservation) -> [String: String] {
        [
            "tool": "sense_observation",
            "event_type": "motion_gesture",
            "capability": "motion_gesture",
            "sense_direction": "push",
            "source": "host_accelerometer",
            "gesture": observation.gesture,
            "confidence": "\(observation.confidence)",
            "acceleration": "x=\(observation.accelerationX) y=\(observation.accelerationY) z=\(observation.accelerationZ)",
            "mirror_to_chat": "false",
        ]
    }

    static func runtimeOptionsURL(brain: BrainDescriptor?) -> URL {
        if let brain {
            return brain.runtimeOptionsURL
        }
        return BrainLibrary.brainsRootURL
            .appendingPathComponent("default", isDirectory: true)
            .appendingPathComponent("runtime_options.json")
    }

}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

let deprecatedRuntimeOptionKeys: Set<String> = [
    "brain_id",
    "activation_mode",
    "camera_mode",
    "seed_path",
]

func sanitizeDeprecatedRuntimeOptions(_ storedValues: [String: Any]) -> [String: Any] {
    storedValues.reduce(into: [String: Any]()) { values, entry in
        guard !deprecatedRuntimeOptionKeys.contains(entry.key) else {
            return
        }
        values[entry.key] = entry.value
    }
}
