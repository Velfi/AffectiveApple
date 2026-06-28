//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation
import Combine

extension AffectiveViewModel {
    func enqueueHostPipelineAction(_ action: HostPipelineAction) {
        recordHostStimulus()
        hostPipelineQueue.append(action)
        canSend = false
        noteQueuedChatResponses(action.presentsChatResponse ? 1 : 0)
        if !isHostPipelineRunning {
            Task {
                await drainHostPipeline()
            }
        } else if hostPipelineHold != .none {
            statusText = hostPipelineHold.statusText
        } else {
            statusText = "Queued"
        }
    }

    func enqueuePriorityHostPipelineActions(_ actions: [HostPipelineAction]) {
        guard !actions.isEmpty else { return }
        recordHostStimulus()
        hostPipelineQueue.insert(contentsOf: actions, at: 0)
        canSend = false
        noteQueuedChatResponses(actions.filter(\.presentsChatResponse).count)
        if !isHostPipelineRunning {
            Task {
                await drainHostPipeline()
            }
        } else if hostPipelineHold != .none {
            statusText = hostPipelineHold.statusText
        } else {
            statusText = "Queued interrupt"
        }
    }

    func drainHostPipeline() async {
        guard !isHostPipelineRunning else { return }
        isHostPipelineRunning = true
        defer {
            isHostPipelineRunning = false
            if hostPipelineQueue.isEmpty, hostPipelineHold == .none {
                canSend = !isBrainUnavailableForConversation
                if statusText == "Queued" || statusText.hasPrefix("Waiting for") {
                    statusText = isBrainUnavailableForConversation ? brainModeStatusText : "Ready"
                }
            }
        }

        while !hostPipelineQueue.isEmpty {
            let action = hostPipelineQueue.removeFirst()
            do {
                currentHostPipelineAction = action
                currentHostPipelineActionIsAwaitingChatResponse = action.presentsChatResponse
                defer {
                    fulfillCurrentChatResponseIfNeeded()
                    currentHostPipelineAction = nil
                    currentHostPipelineActionIsAwaitingChatResponse = false
                }
                await performHostPipelineAction(action)
            }
        }
    }

    func performHostPipelineAction(_ action: HostPipelineAction) async {
        switch action {
        case .interrupt(let userText, let reason, let interruptedAction, let canceledQueuedActionCount):
            await sendInterruptToBrain(
                userText: userText,
                reason: reason,
                interruptedAction: interruptedAction,
                canceledQueuedActionCount: canceledQueuedActionCount
            )
        case .typedText(let text, let stimulusContext):
            await sendTextToBrain(text, source: .typedText, stimulusContext: stimulusContext, speakResponse: brainVoiceEnabled)
        case .imageText(let prompt, let attachment, let mediaPayload, let stimulusContext):
            await sendMediaUploadedEvent(payload: mediaPayload)
            await sendTextToBrain(prompt, source: .typedText, attachments: [attachment], stimulusContext: stimulusContext, speakResponse: brainVoiceEnabled)
        case .coreTouch(let name, let title):
            await callCoreTouch(name: name, title: title)
        case .pokeSequence(let pulses):
            await callCorePokeSequence(pulses)
        case .pushedMotionGesture(let observation):
            await sendPushedMotionGestureObservation(observation)
        case .boredomStimulus(let text, let stimulusContext):
            await sendTextToBrain(
                text,
                source: .typedText,
                stimulusContext: stimulusContext,
                mirrorChatMessages: false,
                speakResponse: false
            )
        case .refreshBrainState:
            await performRefreshBrainState()
        }
    }

    func setHostPipelineHold(_ hold: HostPipelineHold) {
        hostPipelineHold = hold
        statusText = hold.statusText
    }

    func connectToBrain() async {
        guard !isBrainConnected, !isBrainConnectionInFlight else { return }
        isBrainConnectionInFlight = true
        defer {
            isBrainConnectionInFlight = false
        }

        statusText = "Opening Zig core"
        appendEventLog(kind: .sent, title: "initialize", body: "brain-core")

        do {
            let envelope = try await brainCore.connect()
            isBrainConnected = true
            statusText = "Zig core ready"
            appendEventLog(kind: .state, title: "core", body: "Brain core is ready.")
            if !SystemBrainSpeechNotificationService.didRequestAuthorizationThisLaunch {
                SystemBrainSpeechNotificationService.didRequestAuthorizationThisLaunch = true
                brainSpeechNotifications.registerDelegateIfNeeded()
                let notificationStatus = await brainSpeechNotifications.requestAuthorizationIfNeeded()
                appendEventLog(
                    kind: .state,
                    title: "notification permission",
                    body: notificationStatus.rawValue
                )
            }
            _ = await applyCoreEvents(envelope.events, mirrorChatMessages: false, speak: false, handleHostRequests: false)
            refreshBoredomSense()

            await refreshBrainMode()
            await refreshReadModelsSnapshot()
            refreshKnowledgeEntries()
            await collectMailboxItems()

            await enterDreamOnLoadIfNeeded()
            if motionGestureOptionEnabled {
                startMotionGestureMonitoringIfAvailable()
            }
        } catch {
            isBrainConnected = false
            stopBoredomSense()
            stopMotionGestureMonitoring()
            statusText = "Core unavailable"
            appendEventLog(kind: .error, title: "core connect failed", body: error.localizedDescription)
        }
    }

    func shortTapWake() {
        statusText = "Wake tap"
        enqueueHostPipelineAction(.coreTouch(name: "short_touch", title: "short_touch"))
    }

    func startMotionGestureMonitoringIfAvailable() {
        guard motionGestureOptionEnabled else { return }
        guard MotionGestureMonitor.isAvailable(), motionGestureMonitor == nil else { return }
        let monitor = MotionGestureMonitor { [weak self] observation in
            self?.handleMotionGestureObservation(observation)
        }
        motionGestureMonitor = monitor
        monitor.start()
        appendEventLog(
            kind: .state,
            title: "motion gestures",
            body: "Accelerometer gesture monitoring is active.",
            metadata: [
                "capability": "motion_gesture",
                "sense_direction": "push",
                "source": "host_accelerometer",
            ]
        )
    }

    func stopMotionGestureMonitoring() {
        motionGestureMonitor?.stop()
        motionGestureMonitor = nil
    }

    func handleMotionGestureObservation(_ observation: MotionGestureObservation) {
        let metadata = motionGestureMetadata(observation)
        appendEventLog(kind: .sent, title: "motion gesture", body: observation.summary, metadata: metadata)
        recordRecentStimulus(
            kind: "motion_gesture",
            summary: observation.summary,
            metadata: metadata
        )
        enqueueHostPipelineAction(.pushedMotionGesture(observation))
    }

    func beginPoke() {
        guard !isPoking else { return }
        guard !isToolRunning else {
            statusText = "Core call already running"
            return
        }
        guard !isBrainUnavailableForConversation else {
            statusText = brainModeStatusText
            return
        }
        guard canSend else {
            statusText = "Wait until Affective finishes speaking"
            return
        }

        pokeFlushTask?.cancel()
        pokeFlushTask = nil
        isPoking = true
        pokeStartedAt = Date()
        statusText = "Poking"
    }

    func endPoke() {
        guard isPoking else { return }
        let endedAt = Date()
        let startedAt = pokeStartedAt ?? endedAt
        let pressMilliseconds = max(endedAt.timeIntervalSince(startedAt) * 1000, 1)
        let pauseBeforeMilliseconds = lastPokeEndedAt.map { max(startedAt.timeIntervalSince($0) * 1000, 0) } ?? 0

        pendingPokePulses.append(.init(
            pressMilliseconds: pressMilliseconds,
            pauseBeforeMilliseconds: pauseBeforeMilliseconds
        ))
        lastPokeEndedAt = endedAt
        pokeStartedAt = nil
        isPoking = false
        statusText = "Poke noted"
        schedulePokeFlush()
    }

    func cancelPoke() {
        pokeFlushTask?.cancel()
        pokeFlushTask = nil
        pokeStartedAt = nil
        lastPokeEndedAt = nil
        pendingPokePulses = []
        isPoking = false
    }

    func schedulePokeFlush() {
        pokeFlushTask?.cancel()
        pokeFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 850_000_000)
            } catch {
                return
            }
            await self?.flushPokeSequence()
        }
    }

    func flushPokeSequence() async {
        pokeFlushTask?.cancel()
        pokeFlushTask = nil
        guard !isPoking else {
            schedulePokeFlush()
            return
        }
        let pulses = pendingPokePulses
        pendingPokePulses = []
        lastPokeEndedAt = nil
        guard !pulses.isEmpty else { return }

        appendEventLog(
            kind: .sent,
            title: "poke",
            body: pulses.map { "\(Int($0.pressMilliseconds.rounded()))ms" }.joined(separator: " / "),
            metadata: pokeMetadata(pulses: pulses, mirrorToChat: false)
        )
        recordRecentStimulus(
            kind: "poke_sequence",
            summary: pokeStimulusSummary(pulses),
            metadata: pokeMetadata(pulses: pulses, mirrorToChat: false)
        )
        enqueueHostPipelineAction(.pokeSequence(pulses))
    }

    func refreshBrainState() {
        enqueueHostPipelineAction(.refreshBrainState)
    }

    func performRefreshBrainState() async {
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

            statusText = "Refreshing read models"
            await refreshReadModelsSnapshot()
            refreshKnowledgeEntries()
            statusText = "Brain state refreshed"
        } catch {
            isBrainConnected = false
            statusText = "Brain state refresh failed"
            appendEventLog(kind: .error, title: "read_models_snapshot failed", body: error.localizedDescription)
        }
    }

    func forgetTodaysExperience(now: Date = Date(), calendar: Calendar = .current) {
        Task {
            guard !isToolRunning else {
                statusText = "Core call already running"
                return
            }

            isToolRunning = true
            defer { isToolRunning = false }

            statusText = "Forgetting today's experience"
            appendEventLog(kind: .sent, title: "forget_today", body: "Pruning today's events, memories, and local mailbox UI state.")

            await brainCore.disconnect()
            isBrainConnected = false
            stopBoredomSense()

            do {
                let result = try BrainExperienceForgetter.forgetToday(in: brain, now: now, calendar: calendar)
                loadMailboxItems()
                refreshMailboxItems()
                statusText = "Forgot today's experience"
                appendEventLog(
                    kind: .result,
                    title: "forget_today",
                    body: result.summary,
                    metadata: result.metadata
                )
            } catch {
                statusText = "Forget today failed"
                appendEventLog(kind: .error, title: "forget_today failed", body: error.localizedDescription)
            }
        }
    }

    func shareMemoryWithBrain() {
        let trimmed = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "Add memory text first"
            return
        }

        let tags = parsedTags(memoryTags)
        memoryText = ""
        var text = "I want to share something that may be worth remembering: \(trimmed)"
        if !tags.isEmpty {
            text += "\nTags: \(tags.joined(separator: ", "))"
        }
        enqueueHostPipelineAction(.typedText(
            text: text,
            stimulusContext: currentStimulusContext(kind: "user_memory_share")
        ))
    }

    func askMemoryQuestion() {
        let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = parsedTags(memoryTags)
        guard !query.isEmpty || !tags.isEmpty else {
            statusText = "Add a query or tag first"
            return
        }

        var parts: [String] = []
        if !query.isEmpty { parts.append(query) }
        if !tags.isEmpty { parts.append("tags: \(tags.joined(separator: ", "))") }
        enqueueHostPipelineAction(.typedText(
            text: "What do you remember about \(parts.joined(separator: " "))?",
            stimulusContext: currentStimulusContext(kind: "user_memory_question")
        ))
    }

    func setReminder() {
        let schedule = reminderSchedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = reminderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !schedule.isEmpty, !text.isEmpty else {
            statusText = "Add reminder schedule and text"
            return
        }

        reminderText = ""
        enqueueHostPipelineAction(.typedText(
            text: "Please remind me \(schedule): \(text)",
            stimulusContext: currentStimulusContext(kind: "user_reminder_request")
        ))
    }

    func listReminders() {
        enqueueHostPipelineAction(.typedText(
            text: "What reminders do you have for me?",
            stimulusContext: currentStimulusContext(kind: "user_reminder_question")
        ))
    }

    func sendText(interrupt: Bool = false) {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isBrainUnavailableForConversation else {
            statusText = brainModeStatusText
            appendEventLog(kind: .state, title: "conversation blocked", body: brainModeStatusText, metadata: ["brain_mode": brainMode])
            return
        }
        let context = currentStimulusContext(kind: interrupt ? "user_interrupt_message" : "user_message")
        clearSocialTurnResponseWindow()
        chatEntries.append(.init(kind: .user, title: "Other", body: trimmed, metadata: ["source": "typed text"]))
        recordConversationTurn(role: "other", text: trimmed, source: "experience", metadata: ["source": "typed text"])
        appendEventLog(kind: .sent, title: "text", body: trimmed)
        messageText = ""
        if interrupt, canInterruptUserMessage {
            interruptWithUserMessage(trimmed, stimulusContext: context)
        } else {
            enqueueHostPipelineAction(.typedText(text: trimmed, stimulusContext: context))
        }
    }

    func markInputActivity() {
        markCounterpartActive()
        let nextStatus = "Typing"
        guard statusText != nextStatus else { return }
        statusText = nextStatus
    }

    func reportDroppedImage(name: String) {
        droppedImageName = name
        statusText = "Image staged"
        appendEventLog(kind: .sent, title: "imageData", body: name)
        chatEntries.append(.init(kind: .user, title: "Uploaded image", body: "Please look at this uploaded image.", metadata: ["file": name]))
    }

    func sendImage(data: Data, suggestedName: String?) {
        do {
            let storedImage = try storeChatImage(data: data, suggestedName: suggestedName)
            let caption = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = caption.isEmpty ? "Sent a picture." : caption
            messageText = ""

            let metadata = [
                "media_kind": "image",
                "image_path": storedImage.url.path,
                "mime_type": storedImage.mimeType,
                "source": "photo picker",
            ]
            let mediaPayload = mediaUploadPayload(metadata: metadata, caption: caption)
            let context = currentStimulusContext(kind: "user_media_message")
            chatEntries.append(.init(kind: .user, title: "Other", body: body, metadata: metadata))
            recordConversationTurn(role: "other", text: body, source: "image", metadata: metadata)
            appendEventLog(kind: .sent, title: "image attachment", body: storedImage.url.path, metadata: metadata)

            let prompt = caption.isEmpty
                ? "Please inspect the attached picture."
                : "\(caption)\n\nPlease inspect the attached picture."
            let attachment: [String: JSONValue] = [
                "kind": .string("image"),
                "path": .string(storedImage.url.path),
                "mime_type": .string(storedImage.mimeType),
                "caption": .string(caption),
                "source": .string("user_upload"),
            ]
            enqueueHostPipelineAction(.imageText(
                prompt: prompt,
                attachment: attachment,
                mediaPayload: mediaPayload,
                stimulusContext: context
            ))
        } catch {
            reportImageSendFailure(error.localizedDescription)
        }
    }

    func sendMediaUploadedEvent(payload: String) async {
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            _ = try await brainCore.sendExperienceEvent(
                hostID: nil,
                source: "user",
                kind: "User.MediaUploaded",
                payload: payload,
                salience: 0.65,
                confidence: 0.95,
                valence: 0.0,
                arousal: 0.1,
                uncertainty: 0.1,
                causalParentIDs: [],
                retention: "episode",
                visibility: "host"
            )
        } catch {
            appendEventLog(kind: .error, title: "media event", body: error.localizedDescription)
        }
    }

    private func mediaUploadPayload(metadata: [String: String], caption: String) -> String {
        var payload = metadata
        payload["caption"] = caption
        payload["uploaded_at"] = ISO8601DateFormatter().string(from: Date())
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    func reportImageSendFailure(_ message: String) {
        statusText = "Could not send picture"
        appendEventLog(kind: .error, title: "image send failed", body: message)
        chatEntries.append(.init(kind: .error, title: "Image upload", body: message, metadata: ["source": "photo picker"]))
    }

    func setSendEnabled(_ enabled: Bool) {
        canSend = enabled
        statusText = enabled ? "Ready" : "Affective is speaking"
    }

    func setAutonomyMode(_ mode: String) {
        let normalizedMode = Self.normalizeAutonomyMode(mode)
        guard normalizedMode != autonomyMode else { return }
        let previousMode = autonomyMode
        autonomyMode = normalizedMode
        appendEventLog(kind: .sent, title: "option autonomy_mode", body: normalizedMode)

        do {
            try saveAutonomyMode()
            statusText = normalizedMode == "off" ? "Autonomy disabled" : "Autonomy \(normalizedMode)"
            refreshBoredomSense()
        } catch {
            autonomyMode = previousMode
            statusText = "Could not save autonomy"
            appendEventLog(kind: .error, title: "autonomy save failed", body: error.localizedDescription)
        }
    }

    func setBrainVoiceEnabled(_ enabled: Bool) {
        guard enabled != brainVoiceEnabled else { return }
        brainVoiceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.brainVoiceEnabledKey)
        appendEventLog(
            kind: .sent,
            title: "option brain_voice",
            body: enabled ? "on" : "off"
        )
        if enabled {
            statusText = "Brain voice enabled"
        } else {
            speechSpeaker.stop()
            if hostPipelineHold == .speechOutput {
                setHostPipelineHold(.none)
            }
            canSend = hostPipelineQueue.isEmpty
            statusText = "Brain voice disabled"
        }
    }

    func addAutonomyActionBudget() {
        let previousGroups = optionGroups
        let newBudget = autonomyActionBudget + 1
        setRuntimeOptionValue(Self.autonomyBudgetOptionKey, value: "\(newBudget)", commit: true)
        appendEventLog(kind: .sent, title: "option \(Self.autonomyBudgetOptionKey)", body: "\(newBudget)")

        do {
            try saveRuntimeOption(key: Self.autonomyBudgetOptionKey, value: newBudget)
            statusText = "Added 1 autonomy action"
        } catch {
            optionGroups = previousGroups
            statusText = "Could not save autonomy budget"
            appendEventLog(kind: .error, title: "autonomy budget save failed", body: error.localizedDescription)
        }
    }

    func applyOptions() {
        let changes = optionGroups.flatMap(\.options).filter(\.isDirty)
        guard !changes.isEmpty else { return }
        for option in changes {
            appendEventLog(kind: .sent, title: "option \(option.key)", body: option.logValue)
        }
        do {
            try saveOptions()
            var committedGroups = optionGroups
            for groupIndex in committedGroups.indices {
                for optionIndex in committedGroups[groupIndex].options.indices {
                    committedGroups[groupIndex].options[optionIndex].commit()
                }
            }
            optionGroups = committedGroups
            statusText = "Preferences saved"
        } catch {
            statusText = "Could not save preferences"
            appendEventLog(kind: .error, title: "preferences save failed", body: error.localizedDescription)
        }
    }

    func testCredential(for option: RuntimeOption) {
        guard let key = ProviderCredentialKey(rawValue: option.key) else { return }
        Task {
            await testCredential(key, candidate: option.value)
        }
    }

    func testCredentialOptions(_ options: [RuntimeOption]) {
        let credentialOptions = options.filter { ProviderCredentialKey(rawValue: $0.key) != nil }
        guard !credentialOptions.isEmpty else { return }
        Task {
            for option in credentialOptions {
                guard let key = ProviderCredentialKey(rawValue: option.key) else { continue }
                await testCredential(key, candidate: option.value)
            }
        }
    }

    func sendTextToBrain(
        _ text: String,
        source: LanguageInputSource = .typedText,
        attachments: [[String: JSONValue]] = [],
        stimulusContext: StimulusContext? = nil,
        mirrorChatMessages: Bool = true,
        speakResponse: Bool = true,
        handleHostRequests: Bool = true
    ) async {
        guard !isBrainUnavailableForConversation else {
            statusText = brainModeStatusText
            appendEventLog(kind: .state, title: "conversation blocked", body: brainModeStatusText, metadata: ["brain_mode": brainMode])
            return
        }
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            let response = try await brainCore.sendText(
                text,
                source: source,
                attachments: attachments,
                stimulusContext: stimulusContext
            )
            guard !response.events.isEmpty else {
                canSend = true
                statusText = "Core protocol error"
                appendEventLog(
                    kind: .error,
                    title: "user_text",
                    body: "Core returned no event batch for the user_text dispatch.",
                    metadata: response.metadata
                )
                return
            }
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let awaitingHostSense = response.metadata["awaiting_host_sense"] == "true"
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: mirrorChatMessages,
                speak: speakResponse,
                handleHostRequests: handleHostRequests
            )
            let resolvedText = eventResult.resolvedBrainText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !eventResult.didApplyActivityStatus {
                statusText = responseText.isEmpty ? "Core returned no reply" : "Zig core responded"
            }
            if awaitingHostSense {
                if resolvedText.isEmpty {
                    appendEventLog(
                        kind: .result,
                        title: response.toolName,
                        body: Self.pausedForHostSenseLabel(metadata: response.metadata),
                        metadata: response.metadata
                    )
                }
            } else {
                appendEventLog(kind: .result, title: response.toolName, body: response.text, metadata: response.metadata)
            }
            if !awaitingHostSense || !responseText.isEmpty {
                appendEventLog(
                    kind: .state,
                    title: "chat display",
                    body: conversationDisplaySummary(responseText: responseText, metadata: response.metadata),
                    metadata: response.metadata
                )
            } else {
                statusText = Self.awaitingHostSenseStatusText(metadata: response.metadata)
            }
            if responseText.isEmpty, response.metadata["awaiting_host_sense"] != "true" {
                canSend = true
            }
        } catch {
            canSend = true
            statusText = "Core error"
            appendEventLog(kind: .error, title: "text send failed", body: error.localizedDescription)
        }
    }

    func refreshBrainMode() async {
        do {
            let response = try await brainCore.brainMode()
            brainMode = response.mode
            appendEventLog(kind: .state, title: response.toolName, body: response.mode, metadata: response.metadata)
            if isBrainUnavailableForConversation {
                canSend = false
                statusText = brainModeStatusText
            } else if hostPipelineQueue.isEmpty, hostPipelineHold == .none, !isHostPipelineRunning {
                canSend = true
                if statusText == "Brain is drowsy" || statusText == "Brain is dreaming" || statusText == "Brain is waking up" || statusText == "Brain is unavailable" {
                    statusText = "Ready"
                }
            }
        } catch {
            appendEventLog(kind: .error, title: "brain_mode failed", body: error.localizedDescription)
        }
    }

    func refreshReadModelsSnapshot() async {
        do {
            let response = try await brainCore.readModelsSnapshot()
            if let mode = response.readModels.objectValue?["brain_mode"]?.stringValue {
                brainMode = mode
                if isBrainUnavailableForConversation {
                    canSend = false
                    statusText = brainModeStatusText
                }
            }
            applyAutonomyControlSnapshot(response.readModels)
            appendEventLog(kind: .state, title: response.toolName, body: readModelsSnapshotSummary(response.readModels), metadata: response.metadata)
        } catch {
            appendEventLog(kind: .error, title: "read_models_snapshot failed", body: error.localizedDescription)
        }
    }

    func readModelsSnapshotSummary(_ readModels: JSONValue) -> String {
        guard let object = readModels.objectValue else { return "read models unavailable" }
        var autonomySummary: String?
        if let control = object["autonomy_control_model"]?.objectValue,
           case .number(let controlCapacity) = control["control_capacity"],
           case .number(let maxCapacity) = control["max_capacity"],
           let mode = control["mode"]?.stringValue,
           maxCapacity > 0 {
            let percent = Int((max(0, controlCapacity) / maxCapacity * 100).rounded())
            autonomySummary = "autonomy=\(Self.normalizeAutonomyMode(mode)) \(percent)%"
        }
        let parts = [
            object["brain_mode"]?.stringValue.map { "mode=\($0)" },
            autonomySummary,
            object["salient_belief"]?.objectValue?["proposition"]?.stringValue.map { "belief=\($0)" },
            object["strongest_self_trust"]?.objectValue?["faculty"]?.stringValue.map { "self_trust=\($0)" },
            object["winning_disposition"]?.objectValue?["action_tendency"]?.stringValue.map { "disposition=\($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? "read models refreshed" : parts.joined(separator: " ")
    }

    func currentStimulusContext(kind: String, now: Date = Date()) -> StimulusContext {
        let ongoingAction = currentHostPipelineAction?.stimulusDescription
        let hold = hostPipelineHold.stimulusDescription
        let isOngoing = isHostPipelineRunning || hold != nil || isAwaitingChatResponse || speechSpeaker.isSpeaking
        let socialTurnRemaining = socialTurnResponseWindowRemainingSeconds(now: now)
        let counterpartActivityRemaining = counterpartActivityWindowRemainingSeconds(now: now)
        return StimulusContext(
            kind: kind,
            receivedDuring: isOngoing ? "ongoing_action" : (socialTurnRemaining > 0 ? "awaiting_social_response" : "idle"),
            ongoingAction: ongoingAction,
            hostHold: hold,
            queuedActionCount: hostPipelineQueue.count,
            speechOutputActive: speechSpeaker.isSpeaking,
            awaitingSocialResponse: socialTurnRemaining > 0,
            socialTurnResponseWindowRemainingSeconds: socialTurnRemaining,
            counterpartActive: counterpartActivityRemaining > 0,
            counterpartActivityWindowRemainingSeconds: counterpartActivityRemaining,
            recentStimuli: recentStimulusSnapshots(now: now),
            senseInventory: stimulusInventorySnapshots(now: now),
            localTime: now,
            conversationContext: conversationContextSnapshot(now: now)
        )
    }

    func recordConversationTurn(
        role: String,
        text: String,
        source: String,
        metadata: [String: String],
        now: Date = Date()
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let speaker = conversationSpeaker(role: role, metadata: metadata)
        if speaker.role == "other" {
            markCounterpartActive(now: now)
            clearSocialTurnResponseWindow()
        }
        conversationWorkingState.recentTurns.append(.init(
            speakerRole: speaker.role,
            speakerName: speaker.name,
            text: trimmed,
            occurredAt: now,
            source: source,
            salience: conversationSalience(speakerRole: speaker.role, text: trimmed, metadata: metadata),
            metadata: metadata
        ))
        compactConversationTurnsIfNeeded()
        refreshConversationDerivedState()
    }

    func conversationContextSnapshot(now: Date = Date()) -> ConversationContextSnapshot {
        ConversationContextSnapshot(
            mode: conversationWorkingState.mode,
            rollingSummary: conversationWorkingState.rollingSummary,
            activeThreads: conversationWorkingState.activeThreads,
            unresolvedQuestions: conversationWorkingState.unresolvedQuestions,
            recentTurns: conversationWorkingState.recentTurns.map { turn in
                ConversationTurnSnapshot(
                    speakerRole: turn.speakerRole,
                    speakerName: turn.speakerName,
                    text: turn.text,
                    occurredAtUnixMS: (turn.occurredAt.timeIntervalSince1970 * 1000).rounded(),
                    ageSeconds: max(0, now.timeIntervalSince(turn.occurredAt)),
                    source: turn.source,
                    salience: turn.salience,
                    metadata: turn.metadata
                )
            }
        )
    }

    func compactConversationTurnsIfNeeded() {
        let overflow = conversationWorkingState.recentTurns.count - Self.conversationRecentTurnLimit
        guard overflow > 0 else { return }
        let compactedTurns = Array(conversationWorkingState.recentTurns.prefix(overflow))
        conversationWorkingState.recentTurns.removeFirst(overflow)
        let additions = compactedTurns.map { turn in
            let speaker = turn.speakerName ?? turn.speakerRole
            return "\(speaker): \(turn.text)"
        }
        let summaryParts = ([conversationWorkingState.rollingSummary] + additions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        conversationWorkingState.rollingSummary = summaryParts.joined(separator: "\n")
    }

    func refreshConversationDerivedState() {
        conversationWorkingState.activeThreads = derivedConversationThreads()
        conversationWorkingState.unresolvedQuestions = derivedUnresolvedQuestions()
    }

    func derivedConversationThreads() -> [String] {
        let candidates = conversationWorkingState.recentTurns
            .suffix(6)
            .flatMap { conversationKeywords(from: $0.text) }
        return Array(NSOrderedSet(array: candidates).compactMap { $0 as? String }.prefix(5))
    }

    func derivedUnresolvedQuestions() -> [String] {
        let questions = conversationWorkingState.recentTurns
            .suffix(8)
            .filter { $0.speakerRole == "other" && $0.text.contains("?") }
            .map(\.text)
        return Array(questions.suffix(3))
    }

    func conversationKeywords(from text: String) -> [String] {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                word.count >= 4 && !Self.conversationStopWords.contains(word)
            }
        return Array(NSOrderedSet(array: words).compactMap { $0 as? String }.prefix(4))
    }

    func conversationSalience(speakerRole: String, text: String, metadata: [String: String]) -> Double {
        if let rawValue = metadata["salience"], let value = Double(rawValue) {
            return min(max(value, 0), 1)
        }
        if metadata["media_kind"] != nil { return 0.8 }
        if text.contains("?") { return 0.7 }
        if speakerRole == "other" { return 0.65 }
        return 0.55
    }

    func conversationSpeaker(role rawRole: String, metadata: [String: String]) -> (role: String, name: String?) {
        let role = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitName = conversationSpeakerName(from: metadata)
        switch role {
        case "self", "brain", "bot", "assistant", "agent":
            return ("self", explicitName ?? brainSenderName)
        case "other", "user", "human", "person", "counterpart", "speaker":
            return ("other", explicitName)
        default:
            return ("other", explicitName)
        }
    }

    func conversationSpeakerName(from metadata: [String: String]) -> String? {
        for key in ["speaker_name", "person_name", "display_name", "name"] {
            if let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func noteQueuedChatResponses(_ count: Int) {
        guard count > 0 else { return }
        pendingChatResponseCount += count
        refreshAwaitingChatResponse()
    }

    func fulfillCurrentChatResponseIfNeeded() {
        guard currentHostPipelineActionIsAwaitingChatResponse else { return }
        currentHostPipelineActionIsAwaitingChatResponse = false
        pendingChatResponseCount = max(0, pendingChatResponseCount - 1)
        refreshAwaitingChatResponse()
    }

    func refreshAwaitingChatResponse() {
        isAwaitingChatResponse = pendingChatResponseCount > 0
    }

    var canInterruptUserMessage: Bool {
        isHostPipelineRunning || hostPipelineHold != .none || !hostPipelineQueue.isEmpty || speechSpeaker.isSpeaking
    }

    func interruptWithUserMessage(_ text: String, stimulusContext: StimulusContext) {
        let interruptedAction = currentHostPipelineAction?.stimulusDescription
        enqueuePriorityHostPipelineActions([
            .interrupt(
                userText: text,
                reason: "user_requested_interrupt",
                interruptedAction: interruptedAction,
                canceledQueuedActionCount: 0
            ),
            .typedText(text: text, stimulusContext: stimulusContext),
        ])
    }

    func sendInterruptToBrain(
        userText: String,
        reason: String,
        interruptedAction: String?,
        canceledQueuedActionCount: Int
    ) async {
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            let response = try await brainCore.interrupt(
                userText: userText,
                reason: reason,
                interruptedAction: interruptedAction,
                canceledQueuedActionCount: canceledQueuedActionCount
            )
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: false,
                speak: false,
                handleHostRequests: false
            )
            appendEventLog(kind: .state, title: response.toolName, body: response.text, metadata: response.metadata)
            if eventResult.didRequestSpeech {
                appendEventLog(kind: .state, title: "interrupt speech suppressed", body: "Host pipeline interrupt events do not speak.")
            }
        } catch {
            appendEventLog(kind: .error, title: "interrupt failed", body: error.localizedDescription)
        }
    }

    var boredomSenseIsAwake: Bool {
        isBrainConnected && autonomyIsEnabled
    }

    var boredomIntervalMaxSeconds: Int {
        max(runtimeOptionIntValue(for: Self.boredomIntervalOptionKey) ?? 600, Self.boredomIntervalMinSeconds)
    }

    func nextBoredomWaitSeconds(now: Date = Date()) -> Int {
        let maxSeconds = boredomIntervalMaxSeconds
        let minSeconds = Self.boredomIntervalMinSeconds
        guard maxSeconds > minSeconds else { return maxSeconds }
        return Int.random(in: minSeconds...maxSeconds)
    }

    func hostIdleSeconds(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(lastHostStimulusAt).rounded()))
    }

    func recordHostStimulus(now: Date = Date()) {
        lastHostStimulusAt = now
    }

    func recordRecentStimulus(
        kind: String,
        summary: String,
        metadata: [String: String],
        now: Date = Date()
    ) {
        markCounterpartActive(now: now)
        clearSocialTurnResponseWindow()
        pruneRecentStimuli(now: now)
        let id = nextStimulusSequence
        nextStimulusSequence += 1
        stimulusInventory[kind] = StimulusInventoryRecord(
            kind: kind,
            totalCount: (stimulusInventory[kind]?.totalCount ?? 0) + 1,
            lastOccurredAt: now,
            lastSummary: summary,
            lastMetadata: metadata
        )
        recentStimuli.append(.init(
            id: id,
            kind: kind,
            occurredAt: now,
            summary: summary,
            salience: stimulusSalience(from: metadata),
            metadata: metadata
        ))
        if recentStimuli.count > Self.recentStimulusLimit {
            recentStimuli.removeFirst(recentStimuli.count - Self.recentStimulusLimit)
        }
    }

    func recentStimulusSnapshots(now: Date = Date()) -> [RecentStimulusSnapshot] {
        pruneRecentStimuli(now: now)
        return recentStimuli
            .sorted { lhs, rhs in
                if lhs.salience == rhs.salience {
                    return lhs.occurredAt > rhs.occurredAt
                }
                return lhs.salience > rhs.salience
            }
            .map { stimulus in
            RecentStimulusSnapshot(
                id: stimulus.id,
                kind: stimulus.kind,
                ageSeconds: max(0, now.timeIntervalSince(stimulus.occurredAt)),
                summary: stimulus.summary,
                salience: stimulus.salience,
                metadata: stimulus.metadata
            )
        }
    }

    func stimulusInventorySnapshots(now: Date = Date()) -> [StimulusInventorySnapshot] {
        let recentCounts = Dictionary(grouping: recentStimuli, by: \.kind)
            .mapValues(\.count)
        return stimulusInventory.values
            .sorted { lhs, rhs in
                if lhs.lastOccurredAt == rhs.lastOccurredAt {
                    return lhs.kind < rhs.kind
                }
                return lhs.lastOccurredAt > rhs.lastOccurredAt
            }
            .map { record in
                StimulusInventorySnapshot(
                    kind: record.kind,
                    totalCount: record.totalCount,
                    recentCount: recentCounts[record.kind] ?? 0,
                    lastAgeSeconds: max(0, now.timeIntervalSince(record.lastOccurredAt)),
                    lastSummary: record.lastSummary,
                    lastMetadata: record.lastMetadata
                )
            }
    }

    func pruneRecentStimuli(now: Date = Date()) {
        recentStimuli.removeAll { now.timeIntervalSince($0.occurredAt) > Self.recentStimulusRetentionSeconds }
    }

    func stimulusSalience(from metadata: [String: String]) -> Double {
        guard let rawValue = metadata["salience"], let value = Double(rawValue) else {
            return 0.5
        }
        return min(max(value, 0), 1)
    }

    func markAwaitingSocialResponse(now: Date = Date()) {
        awaitingSocialResponseUntil = now.addingTimeInterval(Self.socialTurnResponseWindowSeconds)
    }

    func clearSocialTurnResponseWindow() {
        awaitingSocialResponseUntil = nil
    }

    func socialTurnResponseWindowRemainingSeconds(now: Date = Date()) -> Double {
        guard let until = awaitingSocialResponseUntil else { return 0 }
        let remaining = until.timeIntervalSince(now)
        if remaining <= 0 {
            awaitingSocialResponseUntil = nil
            return 0
        }
        return remaining
    }

    func markCounterpartActive(now: Date = Date()) {
        counterpartActiveUntil = now.addingTimeInterval(Self.counterpartActivityWindowSeconds)
    }

    func counterpartActivityWindowRemainingSeconds(now: Date = Date()) -> Double {
        guard let until = counterpartActiveUntil else { return 0 }
        let remaining = until.timeIntervalSince(now)
        if remaining <= 0 {
            counterpartActiveUntil = nil
            return 0
        }
        return remaining
    }

    func pokeStimulusSummary(_ pulses: [PokePulse]) -> String {
        let rhythm = pulses
            .map { "\(Int($0.pressMilliseconds.rounded()))ms" }
            .joined(separator: " / ")
        return "User poked \(pulses.count) time\(pulses.count == 1 ? "" : "s"): \(rhythm)."
    }

    func refreshBoredomSense() {
        if boredomSenseIsAwake {
            startBoredomSenseIfNeeded()
        } else {
            stopBoredomSense()
        }
    }

    func startBoredomSenseIfNeeded() {
        guard boredomSenseTask == nil else { return }
        recordHostStimulus()
        boredomSenseGeneration += 1
        let generation = boredomSenseGeneration
        boredomSenseTask = Task { [weak self] in
            defer {
                if self?.boredomSenseGeneration == generation {
                    self?.boredomSenseTask = nil
                }
            }
            while !Task.isCancelled {
                guard let waitSeconds = self?.nextBoredomWaitSeconds() else { return }
                do {
                    try await Task.sleep(for: .seconds(waitSeconds))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.boredomSenseGeneration == generation else { return }
                guard self.boredomSenseIsAwake else { return }
                guard self.canEmitBoredomStimulus(waitSeconds: waitSeconds) else { continue }
                self.emitBoredomStimulus(waitSeconds: waitSeconds)
            }
        }
    }

    func stopBoredomSense() {
        boredomSenseGeneration += 1
        boredomSenseTask?.cancel()
        boredomSenseTask = nil
    }

    func canEmitBoredomStimulus(waitSeconds: Int, now: Date = Date()) -> Bool {
        guard boredomSenseIsAwake else { return false }
        guard !isHostPipelineRunning, hostPipelineHold == .none, hostPipelineQueue.isEmpty else { return false }
        guard !isAwaitingChatResponse, !speechSpeaker.isSpeaking, !isPoking else { return false }
        return hostIdleSeconds(now: now) >= waitSeconds
    }

    func emitBoredomStimulus(waitSeconds: Int, now: Date = Date()) {
        let idleSeconds = hostIdleSeconds(now: now)
        let summary = boredomStimulusSummary(idleSeconds: idleSeconds)
        let body = boredomStimulusText(idleSeconds: idleSeconds)
        let context = currentStimulusContext(kind: "boredom", now: now)
        let metadata: [String: String] = [
            "brain": brain.id,
            "stimulus_kind": "boredom",
            "idle_seconds": "\(idleSeconds)",
            "wait_seconds": "\(waitSeconds)",
            "max_interval_seconds": "\(boredomIntervalMaxSeconds)",
        ]
        appendEventLog(
            kind: .sent,
            title: "boredom stimulus",
            body: body,
            metadata: metadata
        )
        recordRecentStimulus(
            kind: "boredom",
            summary: summary,
            metadata: metadata,
            now: now
        )
        enqueueHostPipelineAction(.boredomStimulus(text: body, stimulusContext: context))
    }

    func boredomStimulusSummary(idleSeconds: Int) -> String {
        "Host quiet for \(idleSeconds)s."
    }

    func boredomStimulusText(idleSeconds: Int) -> String {
        "It has been \(idleSeconds) seconds since anything interesting happened. You feel bored."
    }

    func applyAutonomyControlSnapshot(_ readModels: JSONValue) {
        guard let object = readModels.objectValue else { return }
        let controlModel = object["autonomy_control_model"]?.objectValue
            ?? object["autonomy_budget_model"]?.objectValue
        guard let controlModel else { return }

        if let mode = controlModel["mode"]?.stringValue {
            autonomyMode = Self.normalizeAutonomyMode(mode)
        }
        if case .number(let value) = controlModel["control_capacity"] {
            autonomyControlCapacity = max(0, value)
        }
        if case .number(let value) = controlModel["max_capacity"] {
            autonomyMaxCapacity = max(0.01, value)
        }
    }

}

private extension HostPipelineAction {
    var presentsChatResponse: Bool {
        switch self {
        case .typedText, .imageText:
            return true
        case .interrupt:
            return false
        case .coreTouch, .pokeSequence, .pushedMotionGesture, .boredomStimulus:
            return false
        case .refreshBrainState:
            return false
        }
    }

    var stimulusDescription: String {
        switch self {
        case .interrupt:
            return "interrupt"
        case .typedText:
            return "experience:user_message"
        case .imageText:
            return "image_text"
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
        }
    }
}

private extension HostPipelineHold {
    var stimulusDescription: String? {
        switch self {
        case .none:
            return nil
        case .cameraPermission:
            return "camera_permission"
        case .orientationPermission:
            return "orientation_permission"
        case .cameraCapture:
            return "camera_capture"
        case .speechOutput:
            return "speech_output"
        }
    }
}
