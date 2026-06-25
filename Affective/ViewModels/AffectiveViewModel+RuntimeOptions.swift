//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation
import Combine

extension AffectiveViewModel {
    func testCredential(_ key: ProviderCredentialKey, candidate: String) async {
        credentialTestResults[key] = .testing
        appendCommand(kind: .sent, title: "test \(key.displayName) key", body: "<redacted>")

        do {
            let credential = try credentialToTest(key: key, candidate: candidate)
            try await ProviderCredentialTester.test(key: key, credential: credential)
            credentialTestResults[key] = .valid
            statusText = "\(key.displayName) key works"
            appendCommand(kind: .result, title: "test \(key.displayName) key", body: "Credential accepted.")
        } catch {
            credentialTestResults[key] = .invalid(error.localizedDescription)
            statusText = "\(key.displayName) key failed"
            appendCommand(kind: .error, title: "test \(key.displayName) key failed", body: error.localizedDescription)
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

    func callCoreTool(name: String, title: String, arguments: [String: JSONValue], mirrorToChat: Bool) async {
        guard !isToolRunning else {
            statusText = "Core call already running"
            return
        }

        isToolRunning = true
        defer { isToolRunning = false }

        do {
            if Self.cameraPermissionRequiredToolNames.contains(name) {
                guard await ensureCameraPermissionForCaptureCommand(title: title) else {
                    appendCommand(
                        kind: .error,
                        title: "\(title) disabled",
                        body: "Camera permission is denied or unavailable.",
                        metadata: toolMetadata(name: name, mirrorToChat: mirrorToChat)
                    )
                    if mirrorToChat {
                        chatEntries.append(.init(
                            kind: .error,
                            title: "Camera disabled",
                            body: "Camera permission is denied or unavailable.",
                            metadata: ["tool": title]
                        ))
                    }
                    return
                }
            }

            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else {
                throw BrainCoreError.unavailable("The core is not connected.")
            }

            statusText = "Calling \(title)"
            appendCommand(kind: .sent, title: title, body: argumentSummary(arguments), metadata: toolMetadata(name: name, mirrorToChat: mirrorToChat))
            let response = try await brainCore.callTool(name, arguments: arguments)
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayText = isFrontendCaptureDiagnosticText(responseText)
                ? "\(title) requested a camera sense."
                : (responseText.isEmpty ? "\(title) complete" : response.text)
            let eventResult = await applyCoreEvents(response.events, mirrorChatMessages: mirrorToChat, speak: response.shouldSpeak)
            statusText = "\(title) complete"
            appendCommand(kind: .result, title: title, body: displayText, metadata: response.metadata.merging(toolMetadata(name: name, mirrorToChat: mirrorToChat)) { current, _ in current })
            appendMigrationFallbackWarningIfNeeded(response.metadata, title: title)
            if mirrorToChat
                && !eventResult.didAppendBrainChat
                && !isFrontendCaptureDiagnosticText(responseText) {
                appendCommand(
                    kind: .state,
                    title: "chat mirror",
                    body: "\(title) result mirrored into Chat.",
                    metadata: toolMetadata(name: name, mirrorToChat: mirrorToChat)
                )
                chatEntries.append(.init(kind: .brain, title: title, body: displayText, metadata: response.metadata.merging(["brain": brain.id]) { current, _ in current }))
            }
            if response.shouldSpeak
                && !eventResult.didRequestSpeech
                && !isFrontendCaptureDiagnosticText(responseText) {
                await speakBrainResponseAndWait(displayText)
            }
            refreshDreamReports()
        } catch {
            isBrainConnected = false
            statusText = "\(title) failed"
            appendCommand(kind: .error, title: "\(title) failed", body: error.localizedDescription, metadata: toolMetadata(name: name, mirrorToChat: mirrorToChat))
            if mirrorToChat {
                appendCommand(
                    kind: .state,
                    title: "chat mirror",
                    body: "\(title) error mirrored into Chat.",
                    metadata: toolMetadata(name: name, mirrorToChat: mirrorToChat)
                )
                chatEntries.append(.init(kind: .error, title: "Affective core", body: error.localizedDescription, metadata: ["tool": title]))
            }
        }
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
            noChatEventBody: "\(title) completed without a chat event.",
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
            noChatEventBody: "Poke completed without a chat event.",
            metadata: metadata
        ) {
            try await brainCore.pokeSequence(pulses)
        }
    }

    func callCoreStimulus(
        title: String,
        sentBody: String,
        inProgressStatus: String,
        completeStatus: String,
        failedStatus: String,
        emptyDisplayText: String,
        noChatEventBody: String,
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
            appendCommand(kind: .sent, title: title, body: sentBody, metadata: metadata)
            let response = try await send()
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayText = responseText.isEmpty || isFrontendCaptureDiagnosticText(responseText)
                ? emptyDisplayText
                : response.text
            let eventResult = await applyCoreEvents(response.events, mirrorChatMessages: true, speak: response.shouldSpeak)
            statusText = completeStatus
            appendCommand(kind: .result, title: title, body: displayText, metadata: response.metadata.merging(metadata) { current, _ in current })
            appendMigrationFallbackWarningIfNeeded(response.metadata, title: title)
            if !eventResult.didAppendBrainChat && !responseText.isEmpty {
                appendCommand(kind: .state, title: "stimulus result", body: noChatEventBody, metadata: metadata)
            }
            refreshDreamReports()
        } catch {
            isBrainConnected = false
            statusText = failedStatus
            appendCommand(kind: .error, title: "\(title) failed", body: error.localizedDescription, metadata: metadata)
        }
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
        _ events: [BrainHostEvent],
        mirrorChatMessages: Bool,
        speak: Bool,
        handleHostRequests: Bool = true
    ) async -> (didAppendBrainChat: Bool, didRequestSpeech: Bool, didApplyActivityStatus: Bool) {
        var didAppendBrainChat = false
        var speechText: String?
        var didApplyActivityStatus = false

        for event in normalizedCoreEvents(events) {
            let metadata = coreEventMetadata(event)
            switch event.type {
            case "send_enabled_changed":
                if let enabled = event.enabled {
                    canSend = enabled
                    statusText = enabled ? "Ready" : (brainVoiceEnabled ? "Affective is speaking" : "Affective is thinking")
                }
            case "state_changed":
                appendCommand(
                    kind: .state,
                    title: event.state ?? event.title ?? "core state",
                    body: event.text ?? event.body ?? "",
                    metadata: metadata
                )
            case "activity_status_changed":
                let summary = event.text ?? event.body ?? event.state ?? ""
                if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    statusText = summary
                    didApplyActivityStatus = true
                }
                appendCommand(
                    kind: .state,
                    title: event.title ?? event.state ?? "activity status",
                    body: summary,
                    metadata: metadata
                )
            case "command_log":
                appendCommand(
                    kind: logKind(for: event.kind),
                    title: event.title ?? event.kind ?? "core",
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
            case "chat_message", "media_message", "image_generated", "audio_generated":
                guard mirrorChatMessages else { continue }
                guard eventPresentation(for: event).mirrorsToChat else { continue }
                let role = event.role ?? event.kind ?? "brain"
                guard role == "brain" else { continue }
                let body = event.text ?? event.body ?? event.caption ?? mediaFallbackBody(for: event)
                let hasMedia = event.path != nil || event.url != nil
                guard hasMedia || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                chatEntries.append(.init(
                    kind: .brain,
                    title: chatSenderTitle(for: event.title),
                    body: body,
                    metadata: metadata
                ))
                recordConversationTurn(role: "brain", text: body, source: event.type, metadata: metadata)
                didAppendBrainChat = true
            case "speech_requested":
                if eventPresentation(for: event).mirrorsToChat,
                   let text = event.text,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speechText = text
                }
            case "facial_expression_requested":
                appendFacialExpressionAsideIfNeeded(for: event, metadata: metadata, mirrorChatMessages: mirrorChatMessages)
                appendCommand(
                    kind: .state,
                    title: "facial expression",
                    body: [event.eyes, event.mouth].compactMap { $0 }.joined(separator: " / "),
                    metadata: metadata
                )
            case "sense_requested":
                appendCommand(
                    kind: .state,
                    title: event.title ?? event.type,
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
                if handleHostRequests {
                    let responsePresentation = observationResponsePresentation(for: event)
                    await fulfillSenseRequest(
                        event,
                        observationResponsePresentation: mirrorChatMessages
                            ? responsePresentation
                            : .internalOnly
                    )
                }
            case "memory_changed", "debug_trace":
                appendCommand(
                    kind: .state,
                    title: event.title ?? event.type,
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
            default:
                appendCommand(
                    kind: .state,
                    title: event.title ?? event.type,
                    body: event.body ?? event.text ?? "",
                    metadata: metadata
                )
            }
        }

        if speak, let speechText {
            await speakBrainResponseAndWait(speechText)
            return (didAppendBrainChat, true, didApplyActivityStatus)
        }
        return (didAppendBrainChat, false, didApplyActivityStatus)
    }

    func normalizedCoreEvents(_ events: [BrainHostEvent]) -> [BrainHostEvent] {
        let mappedEvents = events.compactMap { event -> BrainHostEvent? in
            if isFrontendCaptureDiagnosticEvent(event) {
                return nil
            }
            if event.type == "capture_requested" {
                return cameraSenseRequestEvent(from: event)
            }
            return event
        }

        guard
            !mappedEvents.contains(where: { $0.type == "sense_requested" && $0.sense == "camera" }),
            let diagnostic = events.first(where: isFrontendCaptureDiagnosticEvent)
        else {
            return mappedEvents
        }

        return mappedEvents + [cameraSenseRequestEvent(from: diagnostic)]
    }

    func cameraSenseRequestEvent(from event: BrainHostEvent) -> BrainHostEvent {
        BrainHostEvent(
            type: "sense_requested",
            requestID: event.requestID ?? UUID().uuidString,
            role: nil,
            text: "frontend camera sense requested",
            state: nil,
            enabled: nil,
            kind: nil,
            title: "camera sense",
            body: "frontend camera sense requested",
            sense: "camera",
            eyes: nil,
            mouth: nil,
            durationMS: nil,
            mediaKind: nil,
            path: nil,
            url: nil,
            mimeType: nil,
            caption: nil,
            rawRef: nil,
            originalBytes: nil,
            responsePresentation: BrainEventPresentation.chat.rawValue,
            awaitResponse: true,
            timeoutMS: 10_000
        )
    }

    func observationResponsePresentation(for event: BrainHostEvent) -> BrainEventPresentation {
        if let presentation = event.responsePresentation.flatMap(BrainEventPresentation.init(rawValue:)) {
            return presentation
        }
        return legacyObservationResponsePresentation
    }

    func eventPresentation(for event: BrainHostEvent) -> BrainEventPresentation {
        event.presentation.flatMap(BrainEventPresentation.init(rawValue:)) ?? .chat
    }

    var legacyObservationResponsePresentation: BrainEventPresentation {
        guard let currentHostPipelineAction else { return .chat }
        switch currentHostPipelineAction {
        case .typedText, .imageText, .interrupt:
            return .internalOnly
        case .coreTool(_, _, _, let mirrorToChat):
            return mirrorToChat ? .chat : .internalOnly
        case .coreTouch, .pokeSequence:
            return .chat
        case .refreshBrainState:
            return .internalOnly
        }
    }

    func fulfillSenseRequest(_ event: BrainHostEvent, observationResponsePresentation: BrainEventPresentation) async {
        switch event.sense {
        case "camera":
            await fulfillCameraSenseRequest(event, observationResponsePresentation: observationResponsePresentation)
        case "orientation":
            await fulfillOrientationRequest(event, observationResponsePresentation: observationResponsePresentation)
        default:
            break
        }
    }

    func isFrontendCaptureDiagnosticEvent(_ event: BrainHostEvent) -> Bool {
        guard event.type == "chat_message"
            || event.type == "speech_requested"
            || event.type == "command_log"
        else {
            return false
        }
        return [event.text, event.body]
            .compactMap { $0 }
            .contains(where: isFrontendCaptureDiagnosticText)
    }

    func isFrontendCaptureDiagnosticText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "Something went wrong while I tried that: FrontendCaptureRequested."
            || trimmed == "Something went wrong while I tried that: FrontendCaptureRequested. That is a hard error, and I do not want to pretend it worked. Tell me if I should try again, change course, or drop it."
    }

    func appendFacialExpressionAsideIfNeeded(
        for event: BrainHostEvent,
        metadata: [String: String],
        mirrorChatMessages: Bool
    ) {
        guard mirrorChatMessages, !avatarDisplaysExpressions else { return }
        let summary = facialExpressionSummary(for: event)
        guard !summary.isEmpty else { return }
        var asideMetadata = metadata
        asideMetadata["presentation"] = "chat_aside"
        chatEntries.append(.init(
            kind: .brain,
            title: "Aside",
            body: "(\(summary))",
            metadata: asideMetadata
        ))
    }

    var avatarDisplaysExpressions: Bool {
        brain.avatarManifest?.expressions.isEmpty == false
    }

    func facialExpressionSummary(for event: BrainHostEvent) -> String {
        [event.eyes, event.mouth]
            .compactMap { $0 }
            .compactMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " / ")
    }

    func coreEventMetadata(_ event: BrainHostEvent) -> [String: String] {
        var metadata = [
            "source": "core_event",
            "event_type": event.type,
        ]
        if let role = event.role { metadata["role"] = role }
        if let kind = event.kind { metadata["kind"] = kind }
        if let sense = event.sense { metadata["sense"] = sense }
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
        if let presentation = event.presentation { metadata["presentation"] = presentation }
        if let responsePresentation = event.responsePresentation { metadata["response_presentation"] = responsePresentation }
        return metadata
    }

    func mediaFallbackBody(for event: BrainHostEvent) -> String {
        switch event.mediaKind {
        case "image":
            return "Sent a picture."
        case "audio":
            return "Sent audio."
        default:
            return "Sent an attachment."
        }
    }

    var brainSenderName: String {
        if let factName = factDatabaseBrainName() {
            return factName
        }
        return "A brain"
    }

    func chatSenderTitle(for _: String?) -> String {
        brainSenderName
    }

    private func factDatabaseBrainName() -> String? {
        guard
            let dataJSON = try? CognitiveStoreReader.readCognitiveJSON(from: brain.memoryDatabaseURL),
            let data = dataJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return Self.explicitBrainIdentityName(in: object)
    }

    private static func explicitBrainIdentityName(in object: [String: Any]) -> String? {
        let directNameKeys = ["brain_name", "self_name"]
        for key in directNameKeys {
            if let name = cleanIdentityName(object[key] as? String) {
                return name
            }
        }

        let objectKeys = ["self", "brain", "agent", "identity", "profile"]
        for key in objectKeys {
            if let nested = object[key] as? [String: Any],
               let name = identityName(from: nested, requiresSelfMarker: false) {
                return name
            }
        }

        if let subjects = object["subjects"] as? [[String: Any]] {
            for subject in subjects {
                if let name = identityName(from: subject, requiresSelfMarker: true) {
                    return name
                }
            }
        }

        return nil
    }

    private static func identityName(
        from object: [String: Any],
        requiresSelfMarker: Bool
    ) -> String? {
        if requiresSelfMarker, !hasBrainSelfMarker(object) {
            return nil
        }
        for key in ["display_name", "name", "preferred_name"] {
            if let name = cleanIdentityName(object[key] as? String) {
                return name
            }
        }
        return nil
    }

    private static func hasBrainSelfMarker(_ object: [String: Any]) -> Bool {
        let markerKeys = ["subject_id", "relationship_status", "kind", "type", "entity", "role"]
        return markerKeys.contains { key in
            guard let value = object[key] as? String else { return false }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["self", "brain", "agent", "assistant"].contains(normalized)
                || normalized.hasPrefix("self_")
                || normalized.hasPrefix("brain_")
        }
    }

    private static func cleanIdentityName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func logKind(for coreKind: String?) -> LogKind {
        guard let coreKind else { return .state }
        return LogKind(rawValue: coreKind) ?? .state
    }

    func toolMetadata(name: String, mirrorToChat: Bool) -> [String: String] {
        [
            "brain": brain.id,
            "tool": name,
            "mirror_to_chat": String(mirrorToChat),
        ]
    }

    func appendMigrationFallbackWarningIfNeeded(_ metadata: [String: String], title: String) {
        guard let fallback = metadata["migration_fallback"] else { return }
        appendCommand(
            kind: .state,
            title: "migration fallback",
            body: "\(title) used \(fallback).",
            metadata: metadata
        )
    }

    func appendCommand(kind: LogKind, title: String, body: String, metadata: [String: String] = [:]) {
        var entryMetadata = metadata
        entryMetadata["stream"] = "commands"
        commandEntries.append(.init(kind: kind, title: title, body: body, metadata: entryMetadata))
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
                    option.value = storedValue
                    option.committedValue = storedValue
                    if case .select(let choices) = option.kind,
                       !choices.contains(where: { $0.value == storedValue }) {
                        option.kind = .select(([RuntimeOptionChoice(value: storedValue, label: storedValue)] + choices).uniqued())
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
        try? migrateLegacyPlaintextCredentials(brain: brain)
        return (try? loadStoredOptionValues(brain: brain)) ?? legacyStoredOptionValues()
    }

    static func legacyStoredOptionValues() -> [String: String] {
        let storedValues = UserDefaults.standard.dictionary(forKey: legacyStoredOptionsKey) as? [String: String] ?? [:]
        return storedValues.filter { !secretOptionKeys.contains($0.key) }
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
            } else if let number = entry.value as? NSNumber {
                values[entry.key] = number.stringValue
            }
        }
    }

    func saveOptions() throws {
        let url = Self.runtimeOptionsURL(brain: brain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var storedValues = try Self.loadRuntimeOptionsObject(brain: brain)
        storedValues["autonomy_mode"] = autonomyMode
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
            } else {
                storedValues[option.key] = option.jsonValue
            }
        }

        let data = try JSONSerialization.data(withJSONObject: storedValues, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func saveAutonomyMode() throws {
        let url = Self.runtimeOptionsURL(brain: brain)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var storedValues = try Self.loadRuntimeOptionsObject(brain: brain)
        storedValues["autonomy_mode"] = autonomyMode
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

    static func migrateLegacyPlaintextCredentials(brain: BrainDescriptor?) throws {
        let url = runtimeOptionsURL(brain: brain)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        var storedValues = try loadRuntimeOptionsObject(brain: brain)
        var didMigrate = false
        for key in ProviderCredentialKey.allCases {
            guard let credential = storedValues[key.rawValue] as? String else { continue }
            if let existingCredential = try credentialStore.credential(for: key),
               !existingCredential.isEmpty {
                storedValues.removeValue(forKey: key.rawValue)
                didMigrate = true
                continue
            }

            let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCredential.isEmpty {
                try credentialStore.saveCredential(trimmedCredential, for: key)
            }
            storedValues.removeValue(forKey: key.rawValue)
            didMigrate = true
        }

        guard didMigrate else { return }
        let data = try JSONSerialization.data(withJSONObject: storedValues, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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

    static func runtimeOptionsURL(brain: BrainDescriptor?) -> URL {
        if let brain {
            return brain.runtimeOptionsURL
        }
        return BrainLibrary.brainsRootURL
            .appendingPathComponent("default", isDirectory: true)
            .appendingPathComponent("runtime_options.json")
    }

    static let cameraPermissionRequiredToolNames: Set<String> = [
        "take_picture",
        "compare_images",
        "recognize",
    ]
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
