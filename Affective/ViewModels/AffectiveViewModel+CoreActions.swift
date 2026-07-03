//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation
import Combine

extension AffectiveViewModel {
    func enqueueHostPipelineAction(_ action: HostPipelineAction) {
        recordHostStimulus()
        noteSocialSenseInput(for: action)
        noteHostPipelineProgress()
        hostPipelineQueue.append(action)
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
        for action in actions {
            noteSocialSenseInput(for: action)
        }
        var queuedActions: [HostPipelineAction] = []
        for action in actions {
            if case .interrupt = action {
                Task {
                    await self.performHostPipelineAction(action)
                }
            } else {
                queuedActions.append(action)
            }
        }
        guard !queuedActions.isEmpty else { return }
        hostPipelineQueue.insert(contentsOf: queuedActions, at: 0)
        noteQueuedChatResponses(queuedActions.filter(\.presentsChatResponse).count)
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
                refreshUserSendAvailability()
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
                noteHostPipelineActionStarted(action)
                defer {
                    noteHostPipelineActionFinished()
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
        case .typedText(let text, let stimulusContext, let delivery):
            await deliverHostStimulusToBrain(
                text: text,
                stimulusContext: stimulusContext,
                delivery: delivery
            )
        case .imageText(let prompt, let attachment, let mediaPayload, let stimulusContext):
            await sendMediaUploadedEvent(payload: mediaPayload)
            await deliverHostStimulusToBrain(
                text: prompt,
                stimulusContext: stimulusContext,
                attachments: [attachment],
                delivery: .counterpartSpeech(name: nil, source: .typedText)
            )
        case .pullSenseRequest(let event, let observationResponsePresentation):
            scheduleAsyncPullSenseFulfillment(
                event: event,
                observationResponsePresentation: observationResponsePresentation
            )
        case .coreTouch(let name, let title):
            await callCoreTouch(name: name, title: title)
        case .pokeSequence(let pulses):
            await callCorePokeSequence(pulses)
        case .pushedMotionGesture(let observation):
            await sendPushedMotionGestureObservation(observation)
        case .boredomStimulus:
            await runAutonomyTick()
        case .refreshBrainState:
            await performRefreshBrainState()
        case .collectMailbox:
            await collectMailboxItems()
        case .mailboxMarkRead(let mailboxID):
            await markMailboxReadInCore(mailboxID: mailboxID)
        }
    }

    func setHostPipelineHold(_ hold: HostPipelineHold) {
        hostPipelineHold = hold
        statusText = hold.statusText
    }

    func disconnectFromBrain() async {
        speechSpeaker.stop()
        stopBoredomSense()
        stopAutonomySense()
        stopHostPipelineHealthMonitor()
        stopMotionGestureMonitoring()
        pokeFlushTask?.cancel()
        pokeFlushTask = nil
        if isPoking {
            isPoking = false
        }
        BrainHostServiceRoutes.clearLLMCompletionObserver()
        await clearCoreEventSinkHandler()
        await brainCore.disconnect()
        isBrainConnected = false
        isBrainConnectionInFlight = false
        statusText = "Disconnected"
    }

    func connectToBrain() async {
        guard !isBrainConnected, !isBrainConnectionInFlight else { return }
        markInitialCoreLoadAttempted()
        isBrainConnectionInFlight = true
        defer {
            isBrainConnectionInFlight = false
            coreLoadProgressLabel = ""
            coreLoadProgressDetail = ""
        }

        let loadSession = CoreLoadPerformanceSession { [weak self] label, detail in
            self?.coreLoadProgressLabel = label
            self?.coreLoadProgressDetail = detail ?? ""
            self?.statusText = label
        }

        statusText = "Opening Zig core"
        coreLoadProgressLabel = "Opening Zig core"
        coreLoadProgressDetail = ""
        CoreLoadPerformanceSession.writeStartupToConsole(brainID: brain.id)
        appendEventLog(kind: .sent, title: "initialize", body: "brain-core")
        installHostLLMCompletionObserver()

        do {
            let envelope = try await brainCore.connect(progress: loadSession)
            isBrainConnected = true
            statusText = "Zig core ready"
            coreLoadProgressLabel = "Zig core ready"
            appendEventLog(kind: .state, title: "core", body: "Brain core is ready.")
            if !SystemBrainSpeechNotificationService.didRequestAuthorizationThisLaunch {
                SystemBrainSpeechNotificationService.didRequestAuthorizationThisLaunch = true
                brainSpeechNotifications.registerDelegateIfNeeded()
                let notificationStatus = await loadSession.measure(id: "notification_permission", label: "Requesting notification permission") {
                    await brainSpeechNotifications.requestAuthorizationIfNeeded()
                }
                appendEventLog(
                    kind: .state,
                    title: "notification permission",
                    body: notificationStatus.rawValue
                )
            }
            _ = await loadSession.measure(id: "apply_core_events", label: "Applying core events") {
                await applyCoreEvents(
                    envelope.events,
                    mirrorChatMessages: false,
                    speak: false,
                    context: .diagnosticStatus
                )
            }
            noteBrainResponseMetadata(envelope.metadata())
            ensureAwaitingHostSenseFulfillmentIfNeeded()
            await loadSession.measure(id: "refresh_senses", label: "Starting background senses") {
                refreshBoredomSense()
                refreshAutonomySense()
            }

            await loadSession.measure(id: "refresh_brain_mode", label: "Refreshing brain mode") {
                await refreshBrainMode()
            }
            await loadSession.measure(id: "read_models_snapshot", label: "Loading read models") {
                await refreshReadModelsSnapshot()
            }
            await loadSession.measure(id: "refresh_knowledge", label: "Loading knowledge") {
                refreshKnowledgeEntries()
            }
            await loadSession.measure(id: "collect_mailbox", label: "Loading mailbox") {
                await collectMailboxItems()
            }
            if supportsAvatarFacialExpressions {
                _ = try await loadSession.measure(id: "facial_expression_catalog", label: "Loading avatar expressions") {
                    try await brainCore.refreshFacialExpressionCatalog()
                }
            }

            await enterDreamOnLoadIfNeeded(loadSession: loadSession)
            if motionGestureOptionEnabled {
                await loadSession.measure(id: "motion_gesture_monitor", label: "Starting motion gestures") {
                    startMotionGestureMonitoringIfAvailable()
                }
            }

            let metrics = loadSession.report()
            recordCoreLoadMetrics(metrics)
            loadSession.logReportToConsole(outcome: "complete", brainID: brain.id)
            appendEventLog(kind: .state, title: "core load metrics", body: metrics.eventLogBody)
            refreshUserSendAvailability()
            if !isBrainUnavailableForConversation {
                statusText = "Ready"
            }
            await installCoreEventSinkHandler()
            startHostPipelineHealthMonitor()
        } catch {
            let metrics = loadSession.report()
            recordCoreLoadMetrics(metrics)
            loadSession.logReportToConsole(outcome: "failed", brainID: brain.id, error: error.localizedDescription)
            appendEventLog(kind: .error, title: "core load metrics", body: metrics.eventLogBody)
            isBrainConnected = false
            stopBoredomSense()
            stopAutonomySense()
            stopHostPipelineHealthMonitor()
            stopMotionGestureMonitoring()
            statusText = "Core unavailable"
            appendEventLog(kind: .error, title: "core connect failed", body: error.localizedDescription)
        }
    }

    private func installCoreEventSinkHandler() async {
        await brainCore.setEventSinkHandler { [weak self] events in
            guard !events.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isBrainConnected else { return }
                _ = await self.applyCoreEvents(
                    events,
                    mirrorChatMessages: true,
                    speak: self.brainVoiceEnabled,
                    context: .eventSink
                )
            }
        }
    }

    private func clearCoreEventSinkHandler() async {
        await brainCore.setEventSinkHandler(nil)
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
        if isHostPipelineRunning || !hostPipelineQueue.isEmpty {
            enqueueHostPipelineAction(.pokeSequence(pulses))
        } else {
            await callCorePokeSequence(pulses)
        }
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
            stimulusContext: currentStimulusContext(kind: "user_memory_share"),
            delivery: .hostNarration
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
            stimulusContext: currentStimulusContext(kind: "user_memory_question"),
            delivery: .hostNarration
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
            stimulusContext: currentStimulusContext(kind: "user_reminder_request"),
            delivery: .hostNarration
        ))
    }

    func listReminders() {
        enqueueHostPipelineAction(.typedText(
            text: "What reminders do you have for me?",
            stimulusContext: currentStimulusContext(kind: "user_reminder_question"),
            delivery: .hostNarration
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
        let interruptedAction = interrupt ? ongoingHostActionDescription : nil
        clearSocialTurnResponseWindow()
        chatEntries.append(.init(kind: .user, title: "Other", body: trimmed, metadata: ["source": "typed text"]))
        recordConversationTurn(role: "other", text: trimmed, source: "experience", metadata: ["source": "typed text"])
        appendEventLog(kind: .sent, title: "text", body: trimmed)
        messageText = ""
        dropQueuedBoredomStimuli()
        if !interrupt,
           shouldCoalesceUserMessageWhileHostPipelineBusy {
            enqueueCoalescedUserMessage(text: trimmed, stimulusContext: context)
            return
        }
        prepareForIncomingUserMessage()
        if interrupt {
            enqueuePriorityHostPipelineActions([
                .interrupt(
                    userText: trimmed,
                    reason: "user_requested_interrupt",
                    interruptedAction: interruptedAction,
                    canceledQueuedActionCount: 0
                ),
                .typedText(text: trimmed, stimulusContext: context),
            ])
        } else {
            enqueueHostPipelineAction(.typedText(text: trimmed, stimulusContext: context))
        }
    }

    func markInputActivity() {
        recordHostStimulus()
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

    func prepareForIncomingUserMessage() {
        if speechSpeaker.isSpeaking {
            speechSpeaker.stop()
        }
        if hostPipelineHold == .speechOutput {
            setHostPipelineHold(.none)
        }
        if currentHostPipelineActionIsAwaitingChatResponse {
            currentHostPipelineActionIsAwaitingChatResponse = false
            releaseChatResponseSlot()
        }
        dropQueuedConversationMessages()
        dropQueuedBoredomStimuli()
        conversationDispatchGeneration += 1
        let generation = conversationDispatchGeneration
        Task {
            await self.brainCore.syncConversationDispatchGeneration(generation)
        }
        refreshUserSendAvailability()
    }

    func prepareForConversationInterrupt() {
        prepareForIncomingUserMessage()
    }

    var shouldCoalesceUserMessageWhileHostPipelineBusy: Bool {
        guard isHostPipelineRunning else { return false }
        return currentHostPipelineAction?.presentsChatResponse == true
    }

    func enqueueCoalescedUserMessage(text: String, stimulusContext: StimulusContext) {
        statusText = "Queued message for core inbox"
        Task {
            await self.deliverCoalescedUserMessage(text: text, stimulusContext: stimulusContext)
        }
    }

    func deliverCoalescedUserMessage(text: String, stimulusContext: StimulusContext) async {
        let record = recordStimulus(
            kind: stimulusContext.kind,
            summary: stimulusSummary(text: text, attachments: [], delivery: .counterpartSpeech(name: nil, source: .typedText)),
            metadata: stimulusRecordMetadata(for: stimulusContext, attachments: [], delivery: .counterpartSpeech(name: nil, source: .typedText))
        )
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            let ingestArguments = BrainCore.speechStimulusArguments(
                text: text,
                source: .typedText,
                stimulusContext: stimulusContext
            )
            _ = try await brainCore.ingestStimulus(
                "stimulus_ingest",
                arguments: ingestArguments
            )
            stimulusInbox.markDelivered(sequenceIDs: [record.id])
            stimulusInboxPendingCount = stimulusInbox.pendingCount
        } catch {
            appendEventLog(kind: .error, title: "inbox coalesce failed", body: error.localizedDescription)
        }
    }

    var ongoingHostActionDescription: String? {
        currentHostPipelineAction?.stimulusDescription ?? hostPipelineHold.stimulusDescription
    }

    func dropQueuedConversationMessages() {
        var removedChatResponses = 0
        hostPipelineQueue.removeAll { action in
            let isConversation: Bool = switch action {
            case .typedText, .imageText:
                true
            default:
                false
            }
            if isConversation, action.presentsChatResponse {
                removedChatResponses += 1
            }
            return isConversation
        }
        if removedChatResponses > 0 {
            pendingChatResponseCount = max(0, pendingChatResponseCount - removedChatResponses)
            refreshAwaitingChatResponse()
        }
    }

    func dropQueuedBoredomStimuli() {
        hostPipelineQueue.removeAll { action in
            if case .boredomStimulus = action {
                return true
            }
            return false
        }
    }

    func deliverBoredomStimulusToBrain(text: String, stimulusContext: StimulusContext) async {
        await deliverHostStimulusToBrain(
            text: text,
            stimulusContext: stimulusContext,
            delivery: .hostNarration,
            expectResponse: false
        )
    }

    func canRunBoredomDelivery() -> Bool {
        !isAwaitingChatResponse
            && !isHostPipelineRunning
            && hostPipelineHold == .none
    }

    func deliverHostStimulusToBrain(
        text: String,
        stimulusContext: StimulusContext?,
        attachments: [[String: JSONValue]] = [],
        delivery: HostStimulusDelivery,
        mirrorChatMessages: Bool = true,
        speakResponse: Bool = true,
        expectResponse: Bool = true
    ) async {
        if expectResponse, isBrainUnavailableForConversation {
            statusText = brainModeStatusText
            appendEventLog(kind: .state, title: "conversation blocked", body: brainModeStatusText, metadata: ["brain_mode": brainMode])
            return
        }
        if !expectResponse, !canRunBoredomDelivery() {
            return
        }

        let stimulusText = hostStimulusBodyText(
            text: text,
            attachments: attachments,
            delivery: delivery
        )
        var recordedStimulus: StimulusRecord?
        if let stimulusContext {
            recordedStimulus = recordStimulus(
                kind: stimulusContext.kind,
                summary: stimulusSummary(text: text, attachments: attachments, delivery: delivery),
                metadata: stimulusRecordMetadata(for: stimulusContext, attachments: attachments, delivery: delivery)
            )
        }
        statusText = attachments.isEmpty ? "Sending stimulus to core" : "Sending picture stimulus to core"

        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            var ingestArguments = BrainCore.speechStimulusArguments(
                text: stimulusText,
                source: delivery.languageInputSource,
                stimulusContext: stimulusContext
            )
            if !attachments.isEmpty {
                ingestArguments["attachments"] = .array(attachments.map { .object($0) })
                ingestArguments["raw_magnitude"] = .number(0.90)
            }
            let ingestEnvelope = try await brainCore.ingestStimulus(
                "stimulus_ingest",
                arguments: ingestArguments
            )
            if ingestEnvelope.stimulusWasQueued {
                if let recordedStimulus {
                    stimulusInbox.markDelivered(sequenceIDs: [recordedStimulus.id])
                    stimulusInboxPendingCount = stimulusInbox.pendingCount
                }
                statusText = "Message queued for core"
                appendEventLog(
                    kind: .state,
                    title: "stimulus queued",
                    body: "Core accepted the message while busy; it will integrate on the next deliberation pass.",
                    metadata: ["request_id": ingestEnvelope.requestID]
                )
                refreshUserSendAvailability()
                return
            }
            if let recordedStimulus {
                stimulusInbox.markDelivered(sequenceIDs: [recordedStimulus.id])
                stimulusInboxPendingCount = stimulusInbox.pendingCount
            }
            statusText = expectResponse ? "Message accepted by core" : statusText
            appendEventLog(
                kind: .state,
                title: "stimulus accepted",
                body: "Core accepted the stimulus; any brain work will arrive as events.",
                metadata: ["request_id": ingestEnvelope.requestID]
            )
            if expectResponse, autonomyIsEnabled {
                await runAutonomyTick()
            }
            refreshUserSendAvailability()
        } catch {
            canSend = true
            statusText = "Core error"
            appendEventLog(kind: .error, title: "stimulus delivery failed", body: error.localizedDescription)
        }
    }

    func stimulusSummary(
        text: String,
        attachments: [[String: JSONValue]],
        delivery: HostStimulusDelivery
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(180))
        if attachments.isEmpty {
            switch delivery {
            case .hostNarration:
                return prefix.isEmpty ? "Host sent a text stimulus." : prefix
            case .counterpartSpeech:
                return prefix.isEmpty ? "User sent a text stimulus." : "User said: \(prefix)"
            }
        }
        return prefix.isEmpty ? "User sent media." : "User sent media: \(prefix)"
    }

    func stimulusRecordMetadata(
        for context: StimulusContext,
        attachments: [[String: JSONValue]],
        delivery: HostStimulusDelivery
    ) -> [String: String] {
        var metadata: [String: String] = [
            "stimulus_kind": context.kind,
            "source": delivery.languageInputSource.rawValue,
            "salience": attachments.isEmpty ? "0.65" : "0.8",
        ]
        if !attachments.isEmpty {
            metadata["media_kind"] = "image"
            metadata["raw_payload_available"] = "true"
        }
        if let attachment = attachments.first,
           let path = attachment["path"]?.stringValue {
            metadata["image_path"] = path
        }
        return metadata
    }

    func hostStimulusBodyText(
        text: String,
        attachments: [[String: JSONValue]],
        delivery: HostStimulusDelivery
    ) -> String {
        switch delivery {
        case .hostNarration, .counterpartSpeech:
            return BrainCore.textByAppendingAttachmentMarkers(text, attachments: attachments)
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

    func reactToBrainUtterance(entryID: UUID, emoji: String) async {
        guard let normalized = EmojiReactionValidation.normalizedReaction(from: emoji) else { return }
        guard let index = chatEntries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = chatEntries[index]
        guard entry.kind == .brain || entry.kind == .emote else { return }
        let utteranceText = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utteranceText.isEmpty else { return }

        chatEntries[index] = LogEntry(
            kind: entry.kind,
            title: entry.title,
            body: entry.body,
            metadata: entry.metadata,
            userReaction: normalized,
            id: entry.id,
            createdAt: entry.createdAt
        )

        reserveChatResponseSlot()
        defer { releaseChatResponseSlot() }

        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else {
                throw BrainCoreError.unavailable("The core is not connected.")
            }
            let response = try await brainCore.sendEmojiReaction(
                emoji: normalized,
                utteranceText: utteranceText,
                speakerLabel: "You",
                utteranceEventID: entry.metadata["event_id"]
            )
            appendEventLog(
                kind: .sent,
                title: "emoji_reaction",
                body: "\(normalized) on \(utteranceText)",
                metadata: response.metadata
            )
            if !response.events.isEmpty {
                _ = await applyCoreEvents(
                    response.events,
                    mirrorChatMessages: true,
                    speak: response.shouldSpeak,
                    context: .dispatchResponse(operation: response.toolName, requestID: response.metadata["request_id"])
                )
            }
        } catch {
            appendEventLog(kind: .error, title: "emoji_reaction failed", body: error.localizedDescription)
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
        setRuntimeOptionValue("autonomy_mode", value: normalizedMode, commit: true)
        appendEventLog(kind: .sent, title: "option background agency", body: normalizedMode)

        do {
            try saveAutonomyMode()
            statusText = "Attention settings updated"
            refreshBoredomSense()
            refreshAutonomySense()
            syncInnerStateSummary()
        } catch {
            autonomyMode = previousMode
            statusText = "Could not save agency"
            appendEventLog(kind: .error, title: "agency save failed", body: error.localizedDescription)
        }
    }

    func setAttentionPaused(_ paused: Bool) {
        let value = paused ? "on" : "off"
        guard runtimeOptionStringValue(for: "autonomy_sleep") != value else { return }
        setRuntimeOptionValue("autonomy_sleep", value: value, commit: true)
        autonomyControlBlockedReason = paused ? "sleep" : "none"
        do {
            try saveRuntimeOption(key: "autonomy_sleep", value: value)
            statusText = paused ? "Attention paused" : "Attention resumed"
            appendEventLog(kind: .sent, title: "option autonomy_sleep", body: value)
            syncInnerStateSummary()
        } catch {
            statusText = "Could not update attention"
            appendEventLog(kind: .error, title: "attention save failed", body: error.localizedDescription)
        }
    }

    func setCameraCaptureEnabled(_ enabled: Bool) {
        let value = enabled ? "on" : "off"
        guard runtimeOptionStringValue(for: Self.cameraCaptureEnabledOptionKey) != value else { return }
        setRuntimeOptionValue(Self.cameraCaptureEnabledOptionKey, value: value, commit: true)
        if !enabled {
            cancelActiveCameraCapture()
        }
        do {
            try saveRuntimeOption(key: Self.cameraCaptureEnabledOptionKey, value: value)
            statusText = enabled ? "Camera sense enabled" : "Camera sense paused"
            appendEventLog(kind: .sent, title: "option camera_capture_enabled", body: value)
            Task {
                await self.advertiseCameraCapabilityConfiguration(requestID: "camera-toggle-\(value)")
            }
        } catch {
            statusText = "Could not update camera sense"
            appendEventLog(kind: .error, title: "camera sense save failed", body: error.localizedDescription)
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
            refreshUserSendAvailability()
            statusText = "Brain voice disabled"
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
            if let mode = runtimeOptionStringValue(for: "autonomy_mode") {
                autonomyMode = Self.normalizeAutonomyMode(mode)
                refreshBoredomSense()
                refreshAutonomySense()
            }
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
        await deliverHostStimulusToBrain(
            text: text,
            stimulusContext: stimulusContext,
            attachments: attachments,
            delivery: .counterpartSpeech(name: nil, source: source),
            mirrorChatMessages: mirrorChatMessages,
            speakResponse: speakResponse,
            expectResponse: handleHostRequests
        )
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
            appendEventLog(kind: .error, title: "brain_read failed", body: error.localizedDescription)
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
            applyActiveProcessModel(from: response.readModels)
            if let presentMoment = response.readModels.objectValue?["present_moment_model"]?.objectValue,
               case .number(let pending) = presentMoment["stimulus_inbox_pending"] {
                stimulusInboxPendingCount = Int(pending)
            }
            innerStateSummaryCore = readModelsSnapshotCoreSummary(response.readModels)
            syncInnerStateSummary()
            appendEventLog(kind: .state, title: response.toolName, body: innerStateSummary, metadata: response.metadata)
        } catch {
            appendEventLog(kind: .error, title: "read_models_snapshot failed", body: error.localizedDescription)
        }
    }

    func scheduleDeferredReadModelsRefresh(delay: Duration = .milliseconds(250)) {
        readModelsRefreshTask?.cancel()
        readModelsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.refreshReadModelsSnapshot()
        }
    }

    func readModelsSnapshotCoreSummary(_ readModels: JSONValue) -> String {
        guard let object = readModels.objectValue else { return "read models unavailable" }
        let parts = [
            object["brain_mode"]?.stringValue.map { "mode=\($0)" },
            object["salient_belief"]?.objectValue?["proposition"]?.stringValue.map { "belief=\($0)" },
            object["strongest_self_trust"]?.objectValue?["faculty"]?.stringValue.map { "self_trust=\($0)" },
            object["winning_disposition"]?.objectValue?["action_tendency"]?.stringValue.map { "disposition=\($0)" },
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    func readModelsSnapshotSummary(_ readModels: JSONValue) -> String {
        innerStateSummaryCore = readModelsSnapshotCoreSummary(readModels)
        return composedInnerStateSummary()
    }

    func currentStimulusContext(kind: String, now: Date = Date()) -> StimulusContext {
        let ongoingAction = currentHostPipelineAction?.stimulusDescription
        let hold = hostPipelineHold.stimulusDescription
        let isOngoing = isHostPipelineRunning || hold != nil || isAwaitingChatResponse || speechSpeaker.isSpeaking
        let socialTurnRemaining = socialTurnResponseWindowRemainingSeconds(now: now)
        let counterpartActivityRemaining = counterpartActivityWindowRemainingSeconds(now: now)
        let contextPayload = stimulusContextPayload(kind: kind, now: now)
        return StimulusContext(
            kind: kind,
            receivedDuring: isOngoing ? "ongoing_action" : (socialTurnRemaining > 0 ? "awaiting_social_response" : "idle"),
            ongoingAction: ongoingAction,
            hostHold: hold,
            queuedActionCount: hostPipelineQueue.count,
            inboxPendingCount: stimulusInboxPendingCount,
            speechOutputActive: speechSpeaker.isSpeaking,
            awaitingSocialResponse: socialTurnRemaining > 0,
            socialTurnResponseWindowRemainingSeconds: socialTurnRemaining,
            counterpartActive: counterpartActivityRemaining > 0,
            counterpartActivityWindowRemainingSeconds: counterpartActivityRemaining,
            activeProcessGoal: activeProcessGoal,
            activeProcessState: activeProcessState,
            activeProcessStepName: activeProcessStepName,
            recentStimuli: contextPayload.recent,
            sensePacket: contextPayload.packet,
            senseInventory: contextPayload.inventory,
            localTime: now,
            conversationContext: conversationContextSnapshot(now: now)
        )
    }

    func stimulusContextPayload(
        kind: String,
        now: Date = Date()
    ) -> (
        recent: [RecentStimulusSnapshot],
        packet: SensePacketSnapshot?,
        inventory: [StimulusInventorySnapshot]
    ) {
        if kind == "autonomy_tick" {
            let packet = stimulusInbox.sensePacket(for: .autonomyTick, triggerKind: kind, now: now)
            return (
                recent: [],
                packet: packet,
                inventory: []
            )
        }
        let context = stimulusInbox.fullContext(now: now)
        let packet = context.packet.map {
            SensePacketSnapshot(
                packetID: "\(kind)-\($0.sequenceIDs.min() ?? 0)-\($0.sequenceIDs.max() ?? 0)",
                triggerKind: kind,
                windowSeconds: $0.windowSeconds,
                openedAt: $0.openedAt,
                closedAt: $0.closedAt,
                records: $0.records,
                digest: $0.digest,
                inventory: $0.inventory
            )
        }
        return (
            recent: context.recent,
            packet: packet,
            inventory: context.inventory
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

    func reserveChatResponseSlot() {
        noteQueuedChatResponses(1)
    }

    func releaseChatResponseSlot() {
        pendingChatResponseCount = max(0, pendingChatResponseCount - 1)
        refreshAwaitingChatResponse()
    }

    func fulfillCurrentChatResponseIfNeeded() {
        guard currentHostPipelineActionIsAwaitingChatResponse else { return }
        currentHostPipelineActionIsAwaitingChatResponse = false
        releaseChatResponseSlot()
    }

    func refreshAwaitingChatResponse() {
        let wasAwaiting = isAwaitingChatResponse
        isAwaitingChatResponse = pendingChatResponseCount > 0
        if wasAwaiting, !isAwaitingChatResponse {
            clearChatWorkingActivity()
        }
    }

    func refreshUserSendAvailability() {
        if isBrainUnavailableForConversation {
            canSend = false
        } else if speechSpeaker.isSpeaking || hostPipelineHold == .speechOutput {
            canSend = false
        } else {
            canSend = true
        }
    }

    func waitForHostPipelineIdle(timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now + timeout
        while isHostPipelineRunning || !hostPipelineQueue.isEmpty || activePullSenseFulfillmentCount > 0 {
            if ContinuousClock.now >= deadline {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    var canInterruptUserMessage: Bool {
        isHostPipelineRunning || hostPipelineHold != .none || !hostPipelineQueue.isEmpty || speechSpeaker.isSpeaking
    }

    func interruptWithUserMessage(_ text: String, stimulusContext: StimulusContext) {
        prepareForConversationInterrupt()
        let interruptedAction = ongoingHostActionDescription
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
                context: .diagnosticStatus
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

    @discardableResult
    func recordRecentStimulus(
        kind: String,
        summary: String,
        metadata: [String: String],
        now: Date = Date()
    ) -> StimulusRecord {
        if stimulusShouldMarkCounterpartActive(kind: kind, metadata: metadata) {
            markCounterpartActive(now: now)
            clearSocialTurnResponseWindow()
        }
        let record = stimulusInbox.record(
            kind: kind,
            summary: summary,
            metadata: metadataForStimulusRecord(metadata),
            context: currentStimulusRecordContext(now: now),
            now: now
        )
        stimulusInboxPendingCount = stimulusInbox.pendingCount
        return record
    }

    @discardableResult
    func recordStimulus(
        kind: String,
        summary: String,
        metadata: [String: String],
        now: Date = Date()
    ) -> StimulusRecord {
        recordRecentStimulus(kind: kind, summary: summary, metadata: metadata, now: now)
    }

    func stimulusShouldMarkCounterpartActive(kind: String, metadata: [String: String]) -> Bool {
        if kind.hasPrefix("user_") {
            return true
        }
        if kind == "short_touch" || kind == "long_touch" || kind == "poke_sequence" {
            return true
        }
        if metadata["tool"] == "short_touch" || metadata["tool"] == "long_touch" || metadata["tool"] == "poke_sequence" {
            return true
        }
        return false
    }

    func metadataForStimulusRecord(_ metadata: [String: String]) -> [String: String] {
        var enriched = metadata
        if let activeProcessGoal {
            enriched["active_process_goal"] = activeProcessGoal
        }
        if let activeProcessState {
            enriched["active_process_state"] = activeProcessState
        }
        if let activeProcessStepName {
            enriched["active_process_step"] = activeProcessStepName
        }
        return enriched
    }

    func currentStimulusRecordContext(now: Date = Date()) -> StimulusRecordContext {
        let hold = hostPipelineHold.stimulusDescription
        let socialTurnRemaining = socialTurnResponseWindowRemainingSeconds(now: now)
        let isOngoing = isHostPipelineRunning || hold != nil || isAwaitingChatResponse || speechSpeaker.isSpeaking
        return StimulusRecordContext(
            receivedDuring: isOngoing ? "ongoing_action" : (socialTurnRemaining > 0 ? "awaiting_social_response" : "idle"),
            activeProcessGoal: activeProcessGoal,
            activeProcessState: activeProcessState,
            activeProcessStepName: activeProcessStepName
        )
    }

    func recentStimulusSnapshots(now: Date = Date()) -> [RecentStimulusSnapshot] {
        stimulusInbox.recentSnapshots(now: now)
    }

    func stimulusInventorySnapshots(now: Date = Date()) -> [StimulusInventorySnapshot] {
        stimulusInbox.inventorySummary(now: now)
    }

    func pruneRecentStimuli(now: Date = Date()) {
        _ = stimulusInbox.recentSnapshots(now: now)
    }

    func stimulusSalience(from metadata: [String: String]) -> Double {
        StimulusInbox.salience(from: metadata)
    }

    func sensePacketDigestKey(kind: String, metadata: [String: String]) -> String {
        StimulusInbox.digestKey(kind: kind, metadata: metadata)
    }

    func stimulusRawPayloadReference(from metadata: [String: String]) -> String? {
        StimulusInbox.rawPayloadReference(from: metadata)
    }

    func stimulusRawPayloadAvailable(from metadata: [String: String]) -> Bool {
        if stimulusRawPayloadReference(from: metadata) != nil { return true }
        return metadata["raw_payload_available"] == "true"
    }

    func stimulusProcessingState(from metadata: [String: String], salience: Double) -> String {
        StimulusInbox.processingState(from: metadata, salience: salience)
    }

    func sensePacketDigestProcessingState(for stimuli: [RecentStimulus], salience: Double) -> String {
        StimulusInbox.digestProcessingState(for: stimuli, salience: salience)
    }

    func sensePacketDigestSummary(for stimuli: [RecentStimulus]) -> String {
        StimulusInbox.digestSummary(for: stimuli)
    }

    func stimulusPossibleMeanings(kind: String, metadata: [String: String]) -> [String] {
        StimulusInbox.features(kind: kind, metadata: metadata, rawPayloadReference: stimulusRawPayloadReference(from: metadata))
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

    func refreshAutonomySense() {
        if autonomySenseIsAwake {
            startAutonomySenseIfNeeded()
        } else {
            stopAutonomySense()
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

    var autonomySenseIsAwake: Bool {
        isBrainConnected && autonomyIsEnabled
    }

    func autonomyTickBaseIntervalSeconds() -> Int {
        max(runtimeOptionIntValue(for: "autonomy_interval_seconds") ?? 300, 30)
    }

    func autonomyTickIntervalSeconds(now: Date = Date()) -> Int {
        let base = autonomyTickBaseIntervalSeconds()
        guard let lastSocialSenseInputAt else { return base }
        let engaged = min(max(runtimeOptionIntValue(for: "autonomy_engaged_interval_seconds") ?? 60, 15), base)
        let decaySeconds = Double(max(runtimeOptionIntValue(for: "autonomy_engagement_decay_seconds") ?? 600, 1))
        let elapsed = now.timeIntervalSince(lastSocialSenseInputAt)
        guard elapsed < decaySeconds else { return base }
        let recovered = max(elapsed, 0) / decaySeconds
        return Int((Double(engaged) + Double(base - engaged) * recovered).rounded())
    }

    func autonomyTickIsDue(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastAutonomyTickAt) >= Double(autonomyTickIntervalSeconds(now: now))
    }

    func noteSocialSenseInput(for action: HostPipelineAction, now: Date = Date()) {
        guard action.isSocialSenseInput else { return }
        lastSocialSenseInputAt = now
    }

    func startAutonomySenseIfNeeded() {
        guard autonomySenseTask == nil else { return }
        lastAutonomyTickAt = Date()
        autonomySenseGeneration += 1
        let generation = autonomySenseGeneration
        autonomySenseTask = Task { [weak self] in
            defer {
                if self?.autonomySenseGeneration == generation {
                    self?.autonomySenseTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(AffectiveViewModel.autonomySensePollSeconds))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.autonomySenseGeneration == generation else { return }
                guard self.autonomySenseIsAwake else { return }
                guard self.autonomyTickIsDue(), self.canRunAutonomyTick() else { continue }
                await self.runAutonomyTick()
            }
        }
    }

    func stopAutonomySense() {
        autonomySenseGeneration += 1
        autonomySenseTask?.cancel()
        autonomySenseTask = nil
    }

    func canRunAutonomyTick() -> Bool {
        guard autonomySenseIsAwake else { return false }
        guard !isHostPipelineRunning, hostPipelineQueue.isEmpty else { return false }
        switch hostPipelineHold {
        case .cameraPermission, .orientationPermission, .cameraCapture, .speechOutput:
            return false
        case .none:
            break
        }
        guard !isAwaitingChatResponse, !speechSpeaker.isSpeaking, !isPoking else { return false }
        return true
    }

    func runAutonomyTick() async {
        lastAutonomyTickAt = Date()
        let autonomyContext = currentStimulusContext(kind: "autonomy_tick")
        let deliveredSequenceIDs = autonomyContext.sensePacket?.sequenceIDs ?? []
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            let response = try await brainCore.autonomyTick(stimulusContext: autonomyContext)
            noteBrainResponseMetadata(response.metadata)
            if !response.events.isEmpty {
                _ = await applyCoreEvents(
                    response.events,
                    mirrorChatMessages: true,
                    speak: response.shouldSpeak,
                    context: .dispatchResponse(operation: response.toolName, requestID: response.envelope.requestID)
                )
            }
            ensureAwaitingHostSenseFulfillmentIfNeeded()
            stimulusInbox.markDelivered(sequenceIDs: deliveredSequenceIDs)
            stimulusInboxPendingCount = stimulusInbox.pendingCount
        } catch {
            appendEventLog(kind: .error, title: "autonomy_tick failed", body: error.localizedDescription)
        }
    }

    func runAutonomyTickForSenseInput(triggerKind: String, now: Date = Date()) async {
        guard stimulusInbox.sensePacket(for: .autonomyTick, triggerKind: triggerKind, now: now) != nil else {
            return
        }
        await runAutonomyTick()
    }

    func markMailboxReadInCore(mailboxID: String) async {
        do {
            _ = try await brainCore.mailboxMarkRead(mailboxID: mailboxID)
        } catch {
            appendEventLog(kind: .error, title: "mailbox_update failed", body: error.localizedDescription)
        }
    }

    func canEmitBoredomStimulus(waitSeconds: Int, now: Date = Date()) -> Bool {
        guard boredomSenseIsAwake else { return false }
        guard !isHostPipelineRunning, hostPipelineHold == .none, hostPipelineQueue.isEmpty else { return false }
        guard !isAwaitingChatResponse, !speechSpeaker.isSpeaking, !isPoking else { return false }
        guard !hostIsSociallyEngaged(now: now) else { return false }
        return hostIdleSeconds(now: now) >= waitSeconds
    }

    func hostIsSociallyEngaged(now: Date = Date()) -> Bool {
        socialTurnResponseWindowRemainingSeconds(now: now) > 0
            || counterpartActivityWindowRemainingSeconds(now: now) > 0
    }

    func emitBoredomStimulus(waitSeconds: Int, now: Date = Date()) {
        let idleSeconds = hostIdleSeconds(now: now)
        let summary = boredomStimulusSummary(idleSeconds: idleSeconds)
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
            body: summary,
            metadata: metadata
        )
        recordRecentStimulus(
            kind: "boredom",
            summary: summary,
            metadata: metadata,
            now: now
        )
        Task {
            await runAutonomyTickForSenseInput(triggerKind: "boredom", now: now)
            recordHostStimulus()
        }
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
        if let blockedReason = controlModel["blocked_reason"]?.stringValue {
            autonomyControlBlockedReason = blockedReason
        } else {
            autonomyControlBlockedReason = "none"
        }
        syncInnerStateSummary()
    }

}

private extension HostPipelineAction {
    var isSocialSenseInput: Bool {
        switch self {
        case .typedText, .imageText, .interrupt:
            return true
        case .coreTouch, .pokeSequence:
            return true
        case .pullSenseRequest, .pushedMotionGesture, .boredomStimulus,
             .refreshBrainState, .collectMailbox, .mailboxMarkRead:
            return false
        }
    }

    var presentsChatResponse: Bool {
        switch self {
        case .typedText, .imageText:
            return true
        case .interrupt, .pullSenseRequest:
            return false
        case .coreTouch, .pokeSequence, .pushedMotionGesture, .boredomStimulus:
            return false
        case .refreshBrainState:
            return false
        case .collectMailbox, .mailboxMarkRead:
            return false
        }
    }

    var stimulusDescription: String {
        switch self {
        case .interrupt:
            return "interrupt"
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

extension AffectiveViewModel {
    func installHostLLMCompletionObserver() {
        BrainHostServiceRoutes.llmCompletionObserver = { [weak self] observation in
            guard let self else { return }
            Task { @MainActor in
                self.recordHostLLMCompletion(observation)
            }
        }
    }

    func recordHostLLMCompletion(_ observation: HostLLMCompletionObservation) {
        appendEventLog(
            kind: .process,
            title: "llm complete",
            body: observation.eventLogBody,
            metadata: observation.eventLogMetadata
        )
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
