//
//  Split from AffectiveViewModel.swift
//  Affective
//

import Foundation
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ImageIO)
import ImageIO
#endif

nonisolated struct SenseObservationTimeoutError: LocalizedError, Equatable {
    let timeoutMS: Int

    var errorDescription: String? {
        "Sense observation timed out after \(timeoutMS) ms."
    }
}

nonisolated enum PullSenseHostTimeout {
    static let defaultMS = 8_000
}

actor PullSenseFulfillmentRace {
    private var isResolved = false

    func resolve() -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        return true
    }
}

extension AffectiveViewModel {
    func storeChatImage(data: Data, suggestedName: String?) throws -> (url: URL, mimeType: String) {
        let imageFormat = detectedImageFormat(data)
        let directory = brain.rootURL
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("host_uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = sanitizedFileBaseName(suggestedName) ?? "image-\(UUID().uuidString)"
        let fileName = "\(baseName).\(imageFormat.fileExtension)"
        let destination = directory.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return (destination, imageFormat.mimeType)
    }

    func detectedImageFormat(_ data: Data) -> (fileExtension: String, mimeType: String) {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ("png", "image/png")
        }
        if bytes.starts(with: [0xFF, 0xD8]) {
            return ("jpg", "image/jpeg")
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return ("gif", "image/gif")
        }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return ("webp", "image/webp")
        }
        return ("jpg", "image/jpeg")
    }

    func sanitizedFileBaseName(_ name: String?) -> String? {
        let raw = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\.[A-Za-z0-9]+$", with: "", options: .regularExpression)
        guard let raw, !raw.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { scalar -> UnicodeScalar in
            allowed.contains(scalar) ? scalar : "-"
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(64))
    }

    func speakBrainResponse(_ text: String) {
        if BrainSpeechNotificationPolicy.shouldNotify(isForeground: appIsForeground, text: text) {
            Task {
                let posted = await brainSpeechNotifications.postIfAuthorized(
                    brainID: brain.id,
                    brainName: brain.displayName,
                    text: text
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
            }
            canSend = true
            statusText = "Ready"
            return
        }
        if speechSpeaker.shouldSkipDuplicateSpeech(text) {
            appendEventLog(
                kind: .state,
                title: "speech output",
                body: "duplicate speech skipped",
                metadata: ["reason": "already_spoken"]
            )
            canSend = true
            statusText = "Ready"
            return
        }
        notificationSounds.playSpeechNotification()
        guard brainVoiceEnabled else {
            canSend = true
            statusText = "Ready"
            appendEventLog(kind: .state, title: "speech output", body: "apple_speech=false", metadata: ["reason": "brain_voice_disabled"])
            markAwaitingSocialResponse()
            return
        }
        canSend = false
        statusText = "Affective is speaking"
        let preferredVoice = runtimeOptionStringValue(for: Self.speechVoiceOptionKey)
        appendEventLog(kind: .state, title: "speech output", body: "apple_speech=true", metadata: ["voice": preferredVoice ?? "system"])
        if let speechSpeakOverride {
            speechSpeakOverride(text, preferredVoice) { [weak self] in
                guard let self else { return }
                self.markAwaitingSocialResponse()
                self.canSend = true
                self.statusText = "Ready"
            }
            return
        }
        speechSpeaker.speak(text, preferredVoiceName: preferredVoice) { [weak self] in
            guard let self else { return }
            self.markAwaitingSocialResponse()
            self.canSend = true
            self.statusText = "Ready"
        }
    }

    func speakBrainResponseAndWait(_ text: String) async {
        if BrainSpeechNotificationPolicy.shouldNotify(isForeground: appIsForeground, text: text) {
            let posted = await brainSpeechNotifications.postIfAuthorized(
                brainID: brain.id,
                brainName: brain.displayName,
                text: text
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
            canSend = true
            statusText = "Ready"
            return
        }
        if speechSpeaker.shouldSkipDuplicateSpeech(text) {
            appendEventLog(
                kind: .state,
                title: "speech output",
                body: "duplicate speech skipped",
                metadata: ["reason": "already_spoken"]
            )
            refreshUserSendAvailability()
            statusText = "Ready"
            return
        }
        notificationSounds.playSpeechNotification()
        guard brainVoiceEnabled else {
            appendEventLog(kind: .state, title: "speech output", body: "apple_speech=false", metadata: ["reason": "brain_voice_disabled"])
            markAwaitingSocialResponse()
            refreshUserSendAvailability()
            statusText = "Ready"
            return
        }
        setHostPipelineHold(.speechOutput)
        canSend = false
        statusText = "Affective is speaking"
        let preferredVoice = runtimeOptionStringValue(for: Self.speechVoiceOptionKey)
        appendEventLog(kind: .state, title: "speech output", body: "apple_speech=true", metadata: ["voice": preferredVoice ?? "system"])
        if let speechSpeakOverride {
            await withCheckedContinuation { continuation in
                speechSpeakOverride(text, preferredVoice) { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.setHostPipelineHold(.none)
                    self.markAwaitingSocialResponse()
                    self.refreshUserSendAvailability()
                    self.statusText = "Ready"
                    continuation.resume()
                }
            }
            return
        }
        await withCheckedContinuation { continuation in
            speechSpeaker.speak(text, preferredVoiceName: preferredVoice) { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.setHostPipelineHold(.none)
                self.markAwaitingSocialResponse()
                self.refreshUserSendAvailability()
                self.statusText = "Ready"
                continuation.resume()
            }
        }
    }

    func fulfillCameraSenseRequest(
        _ event: BrainEvent,
        requestID: String? = nil,
        observationResponsePresentation: BrainEventPresentation = .internalOnly
    ) async {
        let requestID = requestID ?? pullSenseRequestID(for: event)
        guard cameraCaptureIsEnabled else {
            statusText = "Camera sense paused"
            await sendCapabilityStatus(
                capability: "camera",
                status: "disabled",
                requestID: requestID,
                reason: "Camera capture disabled by host"
            )
            await sendPullSenseStatus(
                sense: "camera",
                status: .unavailable,
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "Camera capture disabled by host",
                availability: "disabled",
                permissionState: currentPullSenseDescriptor(for: "camera")?.permissionState,
                terminal: true
            )
            return
        }
        if let pendingCameraRequestID {
            if !didLogCoalescedCameraRequest {
                appendEventLog(
                    kind: .state,
                    title: "camera request coalesced",
                    body: "Camera request already pending for \(pendingCameraRequestID).",
                    metadata: coreEventMetadata(event)
                )
                didLogCoalescedCameraRequest = true
            }
            await sendPullSenseStatus(
                sense: "camera",
                status: .busy,
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "Camera pull sense request already pending for \(pendingCameraRequestID).",
                availability: currentPullSenseDescriptor(for: "camera")?.availability,
                permissionState: currentPullSenseDescriptor(for: "camera")?.permissionState,
                terminal: true,
                updatesAwaitingHostSenseMarker: false
            )
            return
        }

        pendingCameraRequestID = requestID
        didLogCoalescedCameraRequest = false
        defer {
            pendingCameraRequestID = nil
            didLogCoalescedCameraRequest = false
        }

        let status = await requestCameraPermissionIfNeeded(requestID: requestID)
        await recordCameraPermissionStatus(status, requestID: requestID)
        guard status == .available else {
            guard !isPullSenseRequestClosed(requestID) else { return }
            statusText = "Camera unavailable"
            await sendCapabilityStatus(capability: "camera", status: status.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            await sendPullSenseStatus(
                sense: "camera",
                status: pullSenseStatus(for: status),
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "OS camera permission prompt",
                availability: status == .available ? "available" : status.rawValue,
                permissionState: status.rawValue,
                terminal: true
            )
            return
        }

        var phase = "permission"
        var failureMetadata = coreEventMetadata(event)

        do {
            phase = "capture"
            let data = try await captureWebcamPhotoData()
            failureMetadata["byte_count"] = "\(data.count)"
            phase = "decode"
            let imageInfo = try validateCapturedImageData(data)
            phase = "store"
            let storedImage = try storeChatImage(data: data, suggestedName: "frontend-camera-\(UUID().uuidString)")
            guard closePullSenseForObservationDispatch(requestID: requestID) else { return }
            let metadata = [
                "media_kind": "image",
                "image_path": storedImage.url.path,
                "mime_type": storedImage.mimeType,
                "source": "affective_requested_capture",
                "byte_count": "\(data.count)",
                "pixel_width": "\(imageInfo.width)",
                "pixel_height": "\(imageInfo.height)",
            ]
            failureMetadata.merge(metadata) { _, new in new }
            appendEventLog(kind: .sent, title: "camera sense", body: storedImage.url.path, metadata: metadata)
            recordRecentStimulus(
                kind: "camera_observation",
                summary: "Camera captured an image: \(imageInfo.width)x\(imageInfo.height).",
                metadata: metadata
            )
            phase = "recognize"
            let precomputedIdentity = await precomputeCameraIdentity(for: storedImage.url.path)
            phase = "dispatch_sense_observation"
            let stimulusContext = currentStimulusContext(kind: "camera_observation")
            let response: BrainToolResponse
            if isAwaitingChatResponse || currentHostPipelineActionIsAwaitingChatResponse {
                response = try await brainCore.cameraObservation(
                    path: storedImage.url.path,
                    mimeType: storedImage.mimeType,
                    source: "affective_requested_capture",
                    requestID: requestID,
                    presentation: .internalOnly,
                    precomputedIdentity: precomputedIdentity,
                    stimulusContext: stimulusContext
                )
            } else {
                response = try await brainCore.cameraObservation(
                    path: storedImage.url.path,
                    mimeType: storedImage.mimeType,
                    source: "affective_requested_capture",
                    requestID: requestID,
                    presentation: observationResponsePresentation,
                    precomputedIdentity: precomputedIdentity,
                    stimulusContext: stimulusContext
                )
            }
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            appendEventLog(
                kind: .result,
                title: response.toolName,
                body: responseText.isEmpty ? storedImage.url.path : response.text,
                metadata: response.metadata.merging(metadata) { current, _ in current }
            )
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: observationResponsePresentation.mirrorsToChat,
                speak: response.shouldSpeak,
                context: .senseObservation(requestID: requestID)
            )
            noteBrainResponseMetadata(response.metadata)
            noteCoreHostSenseWaitCleared()
            _ = eventResult
            if observationResponsePresentation.mirrorsToChat, !responseText.isEmpty {
                appendEventLog(
                    kind: .state,
                    title: "chat display",
                    body: conversationDisplaySummary(responseText: responseText, metadata: response.metadata),
                    metadata: response.metadata
                )
            }
        } catch {
            guard !isPullSenseRequestClosed(requestID) else { return }
            statusText = "Camera sense failed"
            failureMetadata["phase"] = phase
            failureMetadata.merge(cameraCaptureErrorMetadata(error)) { current, _ in current }
            appendEventLog(kind: .error, title: "camera sense failed", body: error.localizedDescription, metadata: failureMetadata)
            await sendPullSenseStatus(
                sense: "camera",
                status: pullSenseFailureStatus(for: error),
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: error.localizedDescription,
                availability: currentPullSenseDescriptor(for: "camera")?.availability,
                permissionState: currentPullSenseDescriptor(for: "camera")?.permissionState,
                terminal: true
            )
        }
    }

    func ensureCameraPermissionForCaptureEvent(title: String) async -> Bool {
        let status = await requestCameraPermissionIfNeeded(requestID: nil)
        await recordCameraPermissionStatus(status, requestID: nil)
        await synchronizeCoreCameraCapabilityIfNeeded(status)
        guard status == .available else {
            statusText = "\(title) disabled"
            return false
        }
        return true
    }

    func recordCameraPermissionStatus(_ status: HostCameraPermissionStatus, requestID: String?) async {
        let metadata = cameraPermissionMetadata(status: status, requestID: requestID)
        appendEventLog(
            kind: status == .available ? .state : .error,
            title: "camera permission",
            body: "camera=\(status.rawValue)",
            metadata: metadata
        )
    }

    func requestCameraPermissionIfNeeded(requestID: String? = nil) async -> HostCameraPermissionStatus {
        if let cameraPermissionRequestTask {
            return await cameraPermissionRequestTask.value
        }

        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await sendCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.available.rawValue, requestID: requestID, reason: "Camera permission already granted")
            return .available
        case .notDetermined:
            setHostPipelineHold(.cameraPermission)
            await sendCapabilityStatus(capability: "camera", status: "pending", requestID: requestID, reason: "OS camera permission prompt")
            let task = Task { await Self.requestSystemCameraPermission() }
            cameraPermissionRequestTask = task
            let status = await task.value
            cameraPermissionRequestTask = nil
            if status == .available {
                await Self.waitForSystemCameraAuthorization()
            }
            setHostPipelineHold(.none)
            await sendCapabilityStatus(capability: "camera", status: status.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            return status
        case .denied, .restricted:
            await sendCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.denied.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            return .denied
        @unknown default:
            await sendCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.unavailable.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    func synchronizeCoreCameraCapabilityIfNeeded(_ status: HostCameraPermissionStatus) async {
        guard status != .available, isBrainConnected else { return }
        await brainCore.disconnect()
        isBrainConnected = false
        appendEventLog(
            kind: .state,
            title: "core camera capability",
            body: "Reconnecting core with camera=\(status.rawValue).",
            metadata: ["capability": "camera", "status": status.rawValue]
        )
        await connectToBrain()
    }

    func cameraPermissionMetadata(status: HostCameraPermissionStatus, requestID: String?) -> [String: String] {
        var metadata = [
            "source": "host_permission",
            "capability": "camera",
            "status": status.rawValue,
        ]
        if let requestID, !requestID.isEmpty {
            metadata["request_id"] = requestID
        }
        return metadata
    }

    func cameraCaptureErrorMetadata(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        var metadata = [
            "error_domain": nsError.domain,
            "error_code": "\(nsError.code)",
            "error_description": error.localizedDescription,
        ]
        if let cameraError = error as? CameraCaptureError {
            metadata["camera_error"] = String(describing: cameraError)
        }
        return metadata
    }

    func fulfillOrientationRequest(
        _ event: BrainEvent,
        requestID: String? = nil,
        observationResponsePresentation: BrainEventPresentation = .internalOnly
    ) async {
        let requestID = requestID ?? pullSenseRequestID(for: event)
        if let pendingOrientationRequestID {
            await sendPullSenseStatus(
                sense: "orientation",
                status: .busy,
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "Orientation pull sense request already pending for \(pendingOrientationRequestID).",
                availability: currentPullSenseDescriptor(for: "orientation")?.availability,
                permissionState: currentPullSenseDescriptor(for: "orientation")?.permissionState,
                terminal: true
            )
            return
        }

        pendingOrientationRequestID = requestID
        defer {
            if pendingOrientationRequestID == requestID {
                pendingOrientationRequestID = nil
            }
        }

        let previousStatus = currentHostOrientationCapabilityStatus()
        let status = await requestOrientationPermissionIfNeeded(requestID: requestID, reason: event.body ?? event.text)
        await recordOrientationPermissionStatus(status, requestID: requestID)
        if previousStatus != status.rawValue {
            await synchronizeCoreOrientationCapabilityIfNeeded(status)
        }
        guard status == .available else {
            guard !isPullSenseRequestClosed(requestID) else { return }
            statusText = "Orientation unavailable"
            await sendCapabilityStatus(
                capability: "orientation",
                status: status.rawValue,
                requestID: requestID,
                reason: "Host orientation permission prompt"
            )
            await sendPullSenseStatus(
                sense: "orientation",
                status: pullSenseStatus(for: status),
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "Host orientation permission prompt",
                availability: status == .available ? "available" : status.rawValue,
                permissionState: status.rawValue,
                terminal: true
            )
            return
        }

        do {
            statusText = "Sensing orientation"
            let observation = try await observeOrientation()
            guard closePullSenseForObservationDispatch(requestID: requestID) else { return }
            let metadata = orientationObservationMetadata(observation, requestID: requestID)
            appendEventLog(kind: .sent, title: "orientation sense", body: observation.summary, metadata: metadata)
            recordRecentStimulus(
                kind: "orientation_observation",
                summary: observation.summary,
                metadata: metadata
            )
            let response = try await brainCore.orientationObservation(
                observation,
                requestID: requestID,
                presentation: observationResponsePresentation
            )
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            appendEventLog(
                kind: .result,
                title: "sense_observation",
                body: responseText.isEmpty ? observation.summary : response.text,
                metadata: response.metadata.merging(metadata) { current, _ in current }
            )
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: observationResponsePresentation.mirrorsToChat,
                speak: response.shouldSpeak,
                context: .senseObservation(requestID: requestID)
            )
            noteBrainResponseMetadata(response.metadata)
            noteCoreHostSenseWaitCleared()
            _ = eventResult
            statusText = "Orientation sensed"
        } catch {
            guard !isPullSenseRequestClosed(requestID) else { return }
            statusText = "Orientation sense failed"
            appendEventLog(kind: .error, title: "orientation sense failed", body: error.localizedDescription)
            await sendPullSenseStatus(
                sense: "orientation",
                status: pullSenseFailureStatus(for: error),
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: error.localizedDescription,
                availability: currentPullSenseDescriptor(for: "orientation")?.availability,
                permissionState: currentPullSenseDescriptor(for: "orientation")?.permissionState,
                terminal: true
            )
        }
    }

    func requestOrientationPermissionIfNeeded(
        requestID: String?,
        reason: String?
    ) async -> HostOrientationPermissionStatus {
        if let orientationPermissionStatusOverride {
            return orientationPermissionStatusOverride
        }

        switch currentHostOrientationCapabilityStatus() {
        case HostOrientationPermissionStatus.available.rawValue:
            return .available
        case HostOrientationPermissionStatus.denied.rawValue:
            return .denied
        case HostOrientationPermissionStatus.unavailable.rawValue:
            return .unavailable
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            setHostPipelineHold(.orientationPermission)
            orientationPermissionContinuation = continuation
            let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            orientationPermissionPrompt = OrientationPermissionPrompt(
                requestID: requestID,
                reason: trimmedReason?.isEmpty == false
                    ? trimmedReason!
                    : "Affective wants to check the device orientation once."
            )
        }
    }

    func observeOrientation() async throws -> OrientationObservation {
        if let orientationObservationOverride {
            return try await orientationObservationOverride()
        }
        return try await OrientationQueryProvider().observe()
    }

    func pullSenseRequestID(for event: BrainEvent) -> String {
        if let requestID = event.requestID, !requestID.isEmpty {
            return requestID
        }
        return UUID().uuidString
    }

    func pullSenseCatalog() -> [PullSenseDescriptor] {
        [
            PullSenseDescriptor(
                senseID: "camera",
                direction: .pull,
                availability: currentHostCameraCapabilityStatus(),
                permissionState: currentHostCameraPermissionState(),
                statusReason: cameraCaptureIsEnabled
                    ? "Host camera permission and hardware status."
                    : "Camera capture disabled by host."
            ),
            PullSenseDescriptor(
                senseID: "orientation",
                direction: .pull,
                availability: currentHostOrientationCapabilityStatus(),
                permissionState: currentHostOrientationCapabilityStatus(),
                statusReason: "Host orientation permission and Core Motion status."
            ),
            PullSenseDescriptor(
                senseID: "motion_gesture",
                direction: .push,
                availability: currentMotionGestureCapabilityStatus(),
                permissionState: currentMotionGestureCapabilityStatus(),
                statusReason: "Host accelerometer gesture monitor status."
            ),
            PullSenseDescriptor(
                senseID: "time",
                direction: .pull,
                availability: CoreConfigStorage.currentDateTimeCapabilityStatus(),
                permissionState: CoreConfigStorage.currentDateTimeCapabilityStatus(),
                statusReason: "Host system clock and local timezone."
            ),
        ]
    }

    func currentPullSenseDescriptor(for sense: String) -> PullSenseDescriptor? {
        pullSenseCatalog().first { $0.senseID == sense }
    }

    func currentHostCameraCapabilityStatus() -> String {
        cameraCaptureIsEnabled ? CoreConfigStorage.currentCameraCapabilityStatus() : "disabled"
    }

    func currentHostCameraPermissionState() -> String {
        cameraCaptureIsEnabled ? CoreConfigStorage.currentCameraCapabilityStatus() : "disabled"
    }

    func currentHostOrientationCapabilityStatus() -> String {
        orientationCapabilityStatusOverride?.rawValue ?? CoreConfigStorage.currentOrientationCapabilityStatus()
    }

    func currentMotionGestureCapabilityStatus() -> String {
        guard motionGestureOptionEnabled else { return "disabled" }
        return CoreConfigStorage.currentMotionGestureCapabilityStatus(brain: brain)
    }

    func sendSenseCatalog(requestID: String?) async {
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else { return }
            let response = try await brainCore.senseCatalog(
                senses: pullSenseCatalog(),
                requestID: requestID
            )
            appendEventLog(
                kind: .state,
                title: "sense catalog",
                body: "host senses=\(pullSenseCatalog().map(\.senseID).joined(separator: ","))",
                metadata: response.metadata
            )
        } catch {
            appendEventLog(kind: .error, title: "sense catalog failed", body: error.localizedDescription)
        }
    }

    func sendSenseStatus(for requestedSense: String?, requestID: String?) async {
        guard let sense = requestedSense?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sense.isEmpty else {
            await sendSenseCatalog(requestID: requestID)
            return
        }

        guard let descriptor = currentPullSenseDescriptor(for: sense) else {
            await sendPullSenseStatus(
                sense: sense,
                status: .unsupported,
                requestID: requestID,
                timeoutMS: nil,
                reason: "Unsupported sense status requested by brain.",
                availability: "unavailable",
                permissionState: "unavailable",
                terminal: true
            )
            return
        }

        await sendPullSenseStatus(
            sense: descriptor.senseID,
            status: descriptor.availability == "available" ? .fulfilled : .unavailable,
            requestID: requestID,
            timeoutMS: nil,
            reason: descriptor.statusReason,
            availability: descriptor.availability,
            permissionState: descriptor.permissionState,
            terminal: false
        )
    }

    func effectivePullSenseTimeoutMS(for event: BrainEvent) -> Int? {
        if let timeoutMS = event.timeoutMS, timeoutMS > 0 {
            return timeoutMS
        }
        if let markerTimeout = coreAwaitingHostSenseMarker?.timeoutMS, markerTimeout > 0 {
            return markerTimeout
        }
        return PullSenseHostTimeout.defaultMS
    }

    func awaitPullSenseFulfillment(
        event: BrainEvent,
        sense: String,
        requestID: String,
        operation: @escaping @Sendable () async -> Void
    ) async {
        guard let timeoutMS = effectivePullSenseTimeoutMS(for: event) else {
            await operation()
            return
        }

        let completed = await withCheckedContinuation { continuation in
            let race = PullSenseFulfillmentRace()
            let operationTask = Task {
                await operation()
                if await race.resolve() {
                    continuation.resume(returning: true)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMS) * 1_000_000)
                guard !Task.isCancelled else { return }
                if await race.resolve() {
                    operationTask.cancel()
                    continuation.resume(returning: false)
                }
            }
        }

        guard !completed else { return }
        guard !isPullSenseRequestClosed(requestID) else { return }
        closedPullSenseRequestIDs.insert(requestID)
        cancelPendingPullSenseIfNeeded(sense: sense, requestID: requestID)

        let didDeliverTimeout = await sendPullSenseStatus(
            sense: sense,
            status: .timedOut,
            requestID: requestID,
            timeoutMS: timeoutMS,
            reason: "Pull sense timed out before host fulfillment completed.",
            availability: currentPullSenseDescriptor(for: sense)?.availability,
            permissionState: currentPullSenseDescriptor(for: sense)?.permissionState,
            terminal: true
        )
        guard didDeliverTimeout else { return }
        appendEventLog(
            kind: .error,
            title: "\(sense) sense timed out",
            body: "Pull sense timed out before host fulfillment completed.",
            metadata: [
                "event_type": "sense_status",
                "sense": sense,
                "sense_direction": PullSenseDirection.pull.rawValue,
                "status": PullSenseTerminalStatus.timedOut.rawValue,
                "request_id": requestID,
                "timeout_ms": "\(timeoutMS)",
            ]
        )
    }

    func cancelPendingPullSenseIfNeeded(sense: String, requestID: String) {
        if pendingCameraRequestID == requestID {
            pendingCameraRequestID = nil
        }
        if pendingOrientationRequestID == requestID {
            pendingOrientationRequestID = nil
        }
        if sense == "camera" {
            cancelActiveCameraCapture()
        }
        if sense == "orientation", orientationPermissionContinuation != nil {
            orientationPermissionPrompt = nil
            orientationPermissionContinuation?.resume(returning: .unavailable)
            orientationPermissionContinuation = nil
        }
        setHostPipelineHold(.none)
    }

    func cancelActiveCameraCapture() {
        activeCameraCaptureCancel?()
        activeCameraCaptureCancel = nil
    }

    func pullSenseKey(for event: BrainEvent) -> String {
        let sense = (event.sense ?? event.senseID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sense.isEmpty ? "unknown" : sense
    }

    func scheduleAsyncPullSenseFulfillment(
        event: BrainEvent,
        observationResponsePresentation: BrainEventPresentation
    ) {
        let sense = pullSenseKey(for: event)
        let requestID = pullSenseRequestID(for: event)
        guard !isPullSenseRequestClosed(requestID) else { return }

        if let activeRequestID = inFlightPullSenseRequestIDs[sense] {
            if activeRequestID == requestID {
                return
            }
            if coalescedPullSenseLoggedForActiveRequest[sense] != activeRequestID {
                coalescedPullSenseLoggedForActiveRequest[sense] = activeRequestID
                appendEventLog(
                    kind: .state,
                    title: "pull sense coalesced",
                    body: "\(sense) request already in flight for \(activeRequestID).",
                    metadata: [
                        "sense": sense,
                        "active_request_id": activeRequestID,
                        "request_id": requestID,
                    ]
                )
            }
            Task { @MainActor [weak self] in
                await self?.sendPullSenseStatus(
                    sense: sense,
                    status: .busy,
                    requestID: requestID,
                    timeoutMS: event.timeoutMS,
                    reason: "\(sense) pull sense request already in flight for \(activeRequestID).",
                    availability: self?.currentPullSenseDescriptor(for: sense)?.availability,
                    permissionState: self?.currentPullSenseDescriptor(for: sense)?.permissionState,
                    terminal: true,
                    updatesAwaitingHostSenseMarker: false
                )
            }
            return
        }

        inFlightPullSenseRequestIDs[sense] = requestID
        coalescedPullSenseLoggedForActiveRequest.removeValue(forKey: sense)
        noteHostPipelineProgress()
        noteCoreHostSenseWaitCleared()
        activePullSenseFulfillmentCount += 1
        notePullSenseFulfillmentStarted()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.inFlightPullSenseRequestIDs[sense] == requestID {
                    self.inFlightPullSenseRequestIDs.removeValue(forKey: sense)
                    self.coalescedPullSenseLoggedForActiveRequest.removeValue(forKey: sense)
                }
                self.activePullSenseFulfillmentCount -= 1
                self.notePullSenseFulfillmentFinished()
            }
            await self.sendPullSenseStatus(
                sense: sense,
                status: .fulfilled,
                requestID: requestID,
                timeoutMS: event.timeoutMS,
                reason: "\(sense) pull sense request accepted by host sense lane.",
                availability: self.currentPullSenseDescriptor(for: sense)?.availability,
                permissionState: self.currentPullSenseDescriptor(for: sense)?.permissionState,
                terminal: false,
                updatesAwaitingHostSenseMarker: false
            )
            await self.fulfillSenseRequest(
                event,
                observationResponsePresentation: observationResponsePresentation
            )
        }
    }

    func isPullSenseRequestClosed(_ requestID: String?) -> Bool {
        guard let requestID, !requestID.isEmpty else { return false }
        return closedPullSenseRequestIDs.contains(requestID)
    }

    func closePullSenseForObservationDispatch(requestID: String?) -> Bool {
        guard let requestID, !requestID.isEmpty else { return true }
        guard !closedPullSenseRequestIDs.contains(requestID) else { return false }
        closedPullSenseRequestIDs.insert(requestID)
        return true
    }

    @discardableResult
    func sendPullSenseStatus(
        sense: String,
        status: PullSenseTerminalStatus,
        requestID: String?,
        timeoutMS: Int?,
        reason: String,
        availability: String?,
        permissionState: String?,
        terminal: Bool,
        updatesAwaitingHostSenseMarker: Bool = true
    ) async -> Bool {
        let terminalRequestID = terminal == true
            ? requestID?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        if let terminalRequestID, !terminalRequestID.isEmpty {
            guard !terminalPullSenseRequestIDs.contains(terminalRequestID) else { return false }
            closedPullSenseRequestIDs.insert(terminalRequestID)
        }
        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else {
                if let terminalRequestID {
                    closedPullSenseRequestIDs.remove(terminalRequestID)
                }
                return false
            }
            let response = try await brainCore.pullSenseStatus(
                sense: sense,
                direction: currentPullSenseDescriptor(for: sense)?.direction ?? .pull,
                status: status,
                requestID: requestID,
                timeoutMS: timeoutMS,
                reason: reason,
                availability: availability,
                permissionState: permissionState,
                terminal: terminal
            )
            let logKind: LogKind = {
                if status == .fulfilled || !terminal { return .state }
                if status == .busy, !updatesAwaitingHostSenseMarker { return .state }
                return .error
            }()
            appendEventLog(
                kind: logKind,
                title: "sense status",
                body: "\(sense)=\(status.rawValue)",
                metadata: response.metadata
            )
            if let terminalRequestID, !terminalRequestID.isEmpty {
                terminalPullSenseRequestIDs.insert(terminalRequestID)
            }
            if terminal, updatesAwaitingHostSenseMarker {
                noteCoreHostSenseWaitCleared()
                noteBrainResponseMetadata(response.metadata)
            }
            noteHostPipelineProgress()
            return true
        } catch {
            if let terminalRequestID {
                closedPullSenseRequestIDs.remove(terminalRequestID)
            }
            appendEventLog(kind: .error, title: "sense status failed", body: error.localizedDescription)
            return false
        }
    }

    func pullSenseStatus(for status: HostCameraPermissionStatus) -> PullSenseTerminalStatus {
        switch status {
        case .available:
            return .fulfilled
        case .denied:
            return .permissionDenied
        case .unavailable:
            return .unavailable
        }
    }

    func pullSenseStatus(for status: HostOrientationPermissionStatus) -> PullSenseTerminalStatus {
        switch status {
        case .available:
            return .fulfilled
        case .denied:
            return .permissionDenied
        case .promptRequired:
            return .permissionRequired
        case .unavailable:
            return .unavailable
        }
    }

    func pullSenseFailureStatus(for error: Error) -> PullSenseTerminalStatus {
        if error is SenseObservationTimeoutError {
            return .timedOut
        }
        return .failed
    }

    func awaitSenseObservationResponse<T>(
        event: BrainEvent,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard event.awaitResponse == true, let timeoutMS = event.timeoutMS, timeoutMS > 0 else {
            return try await operation()
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMS) * 1_000_000)
                throw SenseObservationTimeoutError(timeoutMS: timeoutMS)
            }

            guard let result = try await group.next() else {
                throw SenseObservationTimeoutError(timeoutMS: timeoutMS)
            }
            group.cancelAll()
            return result
        }
    }

    func resolveOrientationPermission(_ approved: Bool) {
        let status: HostOrientationPermissionStatus = approved ? .available : .denied
        UserDefaults.standard.set(status.rawValue, forKey: Self.orientationPermissionStatusKey)
        orientationPermissionPrompt = nil
        orientationPermissionContinuation?.resume(returning: status)
        orientationPermissionContinuation = nil
        setHostPipelineHold(.none)
    }

    func sendCapabilityStatus(
        capability: String,
        status: String,
        requestID: String?,
        reason: String
    ) async {
        if status == "pending", hostCapabilityPendingSince[capability] == nil {
            hostCapabilityPendingSince[capability] = Date()
        }
        let pendingSince = hostCapabilityPendingSince[capability]
        let elapsedMS = pendingSince.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0

        do {
            if !isBrainConnected {
                await connectToBrain()
            }
            guard isBrainConnected else { return }
            let response = try await brainCore.capabilityStatus(
                capability: capability,
                status: status,
                requestID: requestID,
                pendingSince: pendingSince,
                pendingElapsedMS: elapsedMS,
                reason: reason
            )
            appendEventLog(
                kind: status == "denied" || status == "unavailable" ? .error : .state,
                title: "host capability",
                body: "\(capability)=\(status)",
                metadata: response.metadata
            )
        } catch {
            appendEventLog(kind: .error, title: "host capability failed", body: error.localizedDescription)
        }

        if status != "pending" {
            hostCapabilityPendingSince[capability] = nil
        }
    }

    func advertiseCameraCapabilityConfiguration(requestID: String? = nil) async {
        let cameraStatus = currentHostCameraCapabilityStatus()
        let reason = cameraCaptureIsEnabled
            ? "Host camera permission and hardware status."
            : "Camera capture disabled by host."
        await sendCapabilityStatus(
            capability: "camera",
            status: cameraStatus,
            requestID: requestID,
            reason: reason
        )
        await sendCapabilityStatus(
            capability: "camera_capture",
            status: cameraStatus,
            requestID: requestID,
            reason: reason
        )

        let dependentStatus = cameraCaptureIsEnabled ? "available" : "disabled"
        for capability in cameraDependentCapabilityIDs {
            await sendCapabilityStatus(
                capability: capability,
                status: dependentStatus,
                requestID: requestID,
                reason: cameraCaptureIsEnabled
                    ? "Camera-dependent host capability available."
                    : "Camera-dependent host capability disabled because camera capture is off."
            )
        }
    }

    var cameraDependentCapabilityIDs: [String] {
        [
            "provider_vision_completion",
            "face_identification",
            "identity_recognition",
            "face_enrollment",
            "face_picture_update",
        ]
    }

    func recordOrientationPermissionStatus(_ status: HostOrientationPermissionStatus, requestID: String?) async {
        appendEventLog(
            kind: status == .available ? .state : .error,
            title: "orientation permission",
            body: "orientation=\(status.rawValue)",
            metadata: orientationPermissionMetadata(status: status, requestID: requestID)
        )
    }

    func synchronizeCoreOrientationCapabilityIfNeeded(_ status: HostOrientationPermissionStatus) async {
        guard isBrainConnected else { return }
        await brainCore.disconnect()
        isBrainConnected = false
        appendEventLog(
            kind: .state,
            title: "core orientation capability",
            body: "Reconnecting core with orientation=\(status.rawValue).",
            metadata: ["capability": "orientation", "status": status.rawValue]
        )
        await connectToBrain()
    }

    func orientationPermissionMetadata(status: HostOrientationPermissionStatus, requestID: String?) -> [String: String] {
        var metadata = [
            "source": "host_permission",
            "capability": "orientation",
            "status": status.rawValue,
        ]
        if let requestID, !requestID.isEmpty {
            metadata["request_id"] = requestID
        }
        return metadata
    }

    func orientationObservationMetadata(_ observation: OrientationObservation, requestID: String?) -> [String: String] {
        var metadata = [
            "source": "host_orientation",
            "capability": "orientation",
            "posture": observation.posture,
            "confidence": "\(observation.confidence)",
        ]
        if let requestID, !requestID.isEmpty {
            metadata["request_id"] = requestID
        }
        if let x = observation.gravityX, let y = observation.gravityY, let z = observation.gravityZ {
            metadata["gravity"] = "x=\(x) y=\(y) z=\(z)"
        }
        return metadata
    }

    static func requestSystemCameraPermission() async -> HostCameraPermissionStatus {
        #if canImport(AVFoundation)
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .available : .denied
        #else
        return .unavailable
        #endif
    }

    static func waitForSystemCameraAuthorization() async {
        #if canImport(AVFoundation)
        for _ in 0..<10 {
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #endif
    }

    func precomputeCameraIdentity(for imagePath: String) async -> FaceRecognitionIdentityResult? {
        guard biometricPolicy.canRecognize, FaceRecognitionService.bundledModelsAvailable else {
            return nil
        }
        let thresholds = faceRecognitionThresholds()
        let request = FaceRecognitionIdentifyRequest(
            imagePath: imagePath,
            memoryPath: brain.memoryDatabaseURL.path,
            embeddingsDir: brain.faceEmbeddingsURL.path,
            detectorModel: nil,
            recognizerModel: nil,
            knownThreshold: thresholds.known,
            uncertainThreshold: thresholds.uncertain
        )
        return await Task.detached(priority: .userInitiated) {
            let service = FaceRecognitionService()
            guard let result = try? service.identify(request) else { return nil }
            BrainHostServiceRoutes.primeIdentifyCache(imagePath: imagePath, result: result)
            return result
        }.value
    }

    func faceRecognitionThresholds() -> (known: Float, uncertain: Float) {
        func floatValue(for key: String, default defaultValue: Float) -> Float {
            guard let raw = runtimeOptionStringValue(for: key),
                  let value = Float(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return defaultValue
            }
            return value
        }
        return (
            floatValue(for: "known_threshold", default: 0.85),
            floatValue(for: "uncertain_threshold", default: 0.60)
        )
    }

    func captureWebcamPhotoData() async throws -> Data {
        #if canImport(AVFoundation)
        var lastError: Error?
        let cameraDeviceID = selectedCameraDeviceIDForCapture()
        let capturePhotoData = cameraPhotoCaptureOverride ?? { [weak self] in
            let captureSession = CameraPhotoCaptureSession()
            captureSession.preferredDeviceUniqueID = cameraDeviceID
            self?.activeCameraCaptureCancel = { captureSession.cancel() }
            defer { self?.activeCameraCaptureCancel = nil }
            return try await captureSession.capturePhotoData()
        }
        for attempt in 0..<2 {
            do {
                return try await capturePhotoData()
            } catch {
                lastError = error
                guard attempt == 0, Self.isTransientCameraAuthorizationError(error) else {
                    throw error
                }
                await Self.waitForSystemCameraAuthorization()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw lastError ?? CameraCaptureError.cannotConfigure
        #else
        throw CameraCaptureError.noCamera
        #endif
    }

    func selectedCameraDeviceIDForCapture() -> String? {
        guard let value = runtimeOptionStringValue(for: Self.cameraDeviceIDOptionKey),
              value != Self.automaticCameraDeviceID else {
            return nil
        }
        return value
    }

    static func cameraDeviceOptionChoices() -> [RuntimeOptionChoice] {
        #if canImport(AVFoundation) && os(macOS)
        let deviceChoices = CameraPhotoCaptureSession.availableCameraDevices()
            .map { RuntimeOptionChoice(value: $0.uniqueID, label: $0.localizedName) }
        return [RuntimeOptionChoice(value: automaticCameraDeviceID, label: "Automatic")] + deviceChoices
        #else
        return [RuntimeOptionChoice(value: automaticCameraDeviceID, label: "Automatic")]
        #endif
    }

    @discardableResult
    func validateCapturedImageData(_ data: Data) throws -> CapturedImageInfo {
        guard !data.isEmpty else {
            throw CameraCaptureError.noImageData
        }
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw CameraCaptureError.invalidImageData
        }
        if Self.isEffectivelyBlackCapturedImage(source: source, width: width, height: height) {
            throw CameraCaptureError.blackImageData
        }
        return CapturedImageInfo(width: width, height: height)
        #else
        return CapturedImageInfo(width: 0, height: 0)
        #endif
    }

    #if canImport(ImageIO)
    static func isEffectivelyBlackCapturedImage(
        source: CGImageSource,
        width: Int,
        height: Int
    ) -> Bool {
        guard width * height >= 64 else { return false }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }

        let sampleWidth = min(width, 16)
        let sampleHeight = min(height, 16)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard didDraw else { return false }

        var luminanceSum = 0.0
        var squaredLuminanceSum = 0.0
        var maxLuminance = 0.0
        let sampleCount = sampleWidth * sampleHeight

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            luminanceSum += luminance
            squaredLuminanceSum += luminance * luminance
            maxLuminance = max(maxLuminance, luminance)
        }

        let mean = luminanceSum / Double(sampleCount)
        let variance = max((squaredLuminanceSum / Double(sampleCount)) - (mean * mean), 0)
        let standardDeviation = sqrt(variance)
        return (mean < 8 && standardDeviation < 4) || (maxLuminance < 8 && mean < 4 && standardDeviation < 2)
    }
    #endif

    #if canImport(AVFoundation)
    static func isTransientCameraAuthorizationError(_ error: Error) -> Bool {
        if let cameraError = error as? CameraCaptureError, cameraError == .notAuthorized {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return nsError.code == AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue
        }
        return false
    }
    #endif

}

struct CapturedImageInfo: Equatable {
    let width: Int
    let height: Int
}

enum HostCameraPermissionStatus: String {
    case available
    case denied
    case unavailable
}

enum CameraCaptureError: LocalizedError {
    case noCamera
    case cannotConfigure
    case noImageData
    case invalidImageData
    case blackImageData
    case notAuthorized
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera is available."
        case .cannotConfigure:
            return "The camera session could not be configured."
        case .noImageData:
            return "The camera did not return image data."
        case .invalidImageData:
            return "The camera returned image data that could not be decoded."
        case .blackImageData:
            return "The camera returned a nearly black image."
        case .notAuthorized:
            return "Camera permission is not available yet."
        case .timedOut:
            return "The camera did not return a photo in time."
        }
    }
}

#if canImport(AVFoundation) && canImport(CoreImage)
final class CameraPhotoCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "Affective.camera.photo.capture")
    private let imageContext = CIContext()
    // /tmp/camera-matrix showed frames 1-3 were black and 0.75s was usable,
    // while 1.0s was the first stable exposure plateau across trials.
    private let minimumWarmupFrames = 8
    private let minimumWarmupSeconds: TimeInterval = 1.0
    private var continuation: CheckedContinuation<Data, Error>?
    private var isFinished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var captureStartedAt: Date?
    private var deliveredFrameCount = 0
    private var didRejectBlackFrame = false

    static func capturePhotoDataWithManagedLifetime(preferredDeviceUniqueID: String? = nil) async throws -> Data {
        let captureSession = CameraPhotoCaptureSession()
        captureSession.preferredDeviceUniqueID = preferredDeviceUniqueID
        return try await captureSession.capturePhotoData()
    }

    fileprivate var preferredDeviceUniqueID: String?

    func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                startCapture(continuation: continuation)
            }
        }
    }

    func cancel() {
        finish(with: .failure(CameraCaptureError.timedOut))
    }

    private func startCapture(continuation: CheckedContinuation<Data, Error>) {
        guard self.continuation == nil else {
            continuation.resume(throwing: CameraCaptureError.cannotConfigure)
            return
        }
        self.continuation = continuation
        captureStartedAt = Date()
        deliveredFrameCount = 0
        didRejectBlackFrame = false

        do {
            try configureSession()
            session.startRunning()
            guard session.isRunning else {
                throw CameraCaptureError.cannotConfigure
            }
            scheduleTimeout()
        } catch {
            finish(with: .failure(error))
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraCaptureError.notAuthorized
        }
        session.sessionPreset = .high
        guard let device = Self.preferredCameraDevice(uniqueID: preferredDeviceUniqueID) else {
            throw CameraCaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addOutput(output)
    }

    static func availableCameraDevices() -> [AVCaptureDevice] {
        #if os(macOS)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.sorted { lhs, rhs in
            let lhsRank = cameraDeviceAutomaticRank(lhs)
            let rhsRank = cameraDeviceAutomaticRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
        #else
        return []
        #endif
    }

    private static func cameraDeviceAutomaticRank(_ device: AVCaptureDevice) -> Int {
        let name = device.localizedName.lowercased()
        if name.contains("obs") {
            return 100
        }
        if name.contains("virtual") || name.contains("screen capture") {
            return 90
        }
        if device.deviceType == .builtInWideAngleCamera {
            return 0
        }
        return 10
    }

    private static func preferredCameraDevice(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID,
           let device = availableCameraDevices().first(where: { $0.uniqueID == uniqueID }) {
            return device
        }
        #if os(iOS)
        return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        #else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? availableCameraDevices().first
            ?? AVCaptureDevice.default(for: .video)
        #endif
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        deliveredFrameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let elapsed = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard deliveredFrameCount >= minimumWarmupFrames, elapsed >= minimumWarmupSeconds else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let data = imageContext.jpegRepresentation(of: image, colorSpace: colorSpace) else {
            return
        }
        if Self.isEffectivelyBlackImageData(
            data,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        ) {
            didRejectBlackFrame = true
            return
        }
        finish(with: .success(data))
    }

    private func finish(with result: Result<Data, Error>) {
        captureQueue.async { [self] in
            guard !isFinished else { return }
            isFinished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning {
                session.stopRunning()
            }
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func scheduleTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(with: .failure(self.didRejectBlackFrame ? CameraCaptureError.blackImageData : CameraCaptureError.timedOut))
        }
        timeoutWorkItem = timeout
        captureQueue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private static func isEffectivelyBlackImageData(_ data: Data, width: Int, height: Int) -> Bool {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return AffectiveViewModel.isEffectivelyBlackCapturedImage(source: source, width: width, height: height)
        #else
        return false
        #endif
    }
}
#elseif canImport(AVFoundation)
final class CameraPhotoCaptureSession: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let captureQueue = DispatchQueue(label: "Affective.camera.photo.capture")
    private var continuation: CheckedContinuation<Data, Error>?
    private var isFinished = false
    private var timeoutWorkItem: DispatchWorkItem?

    static func capturePhotoDataWithManagedLifetime(preferredDeviceUniqueID: String? = nil) async throws -> Data {
        let captureSession = CameraPhotoCaptureSession()
        captureSession.preferredDeviceUniqueID = preferredDeviceUniqueID
        return try await captureSession.capturePhotoData()
    }

    fileprivate var preferredDeviceUniqueID: String?

    func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                startCapture(continuation: continuation)
            }
        }
    }

    func cancel() {
        finish(with: .failure(CameraCaptureError.timedOut))
    }

    private func startCapture(continuation: CheckedContinuation<Data, Error>) {
        guard self.continuation == nil else {
            continuation.resume(throwing: CameraCaptureError.cannotConfigure)
            return
        }
        self.continuation = continuation

        do {
            try configureSession()
            session.startRunning()
            guard session.isRunning else {
                throw CameraCaptureError.cannotConfigure
            }
            scheduleTimeout()
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        } catch {
            finish(with: .failure(error))
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraCaptureError.notAuthorized
        }
        session.sessionPreset = .photo
        guard let device = Self.preferredCameraDevice(uniqueID: preferredDeviceUniqueID) else {
            throw CameraCaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addOutput(output)
    }

    static func availableCameraDevices() -> [AVCaptureDevice] {
        #if os(macOS)
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.sorted { lhs, rhs in
            let lhsRank = cameraDeviceAutomaticRank(lhs)
            let rhsRank = cameraDeviceAutomaticRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
        #else
        return []
        #endif
    }

    private static func cameraDeviceAutomaticRank(_ device: AVCaptureDevice) -> Int {
        let name = device.localizedName.lowercased()
        if name.contains("obs") {
            return 100
        }
        if name.contains("virtual") || name.contains("screen capture") {
            return 90
        }
        if device.deviceType == .builtInWideAngleCamera {
            return 0
        }
        return 10
    }

    private static func preferredCameraDevice(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID,
           let device = availableCameraDevices().first(where: { $0.uniqueID == uniqueID }) {
            return device
        }
        #if os(iOS)
        return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        #else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? availableCameraDevices().first
            ?? AVCaptureDevice.default(for: .video)
        #endif
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finish(with: .failure(CameraCaptureError.noImageData))
            return
        }
        finish(with: .success(data))
    }

    private func finish(with result: Result<Data, Error>) {
        captureQueue.async { [self] in
            guard !isFinished else { return }
            isFinished = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            if session.isRunning {
                session.stopRunning()
            }
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func scheduleTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(with: .failure(CameraCaptureError.timedOut))
        }
        timeoutWorkItem = timeout
        captureQueue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
}
#endif
