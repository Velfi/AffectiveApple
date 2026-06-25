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
        guard brainVoiceEnabled else {
            canSend = true
            statusText = "Ready"
            appendCommand(kind: .state, title: "speech output", body: "apple_speech=false", metadata: ["reason": "brain_voice_disabled"])
            return
        }
        canSend = false
        statusText = "Affective is speaking"
        let preferredVoice = runtimeOptionStringValue(for: Self.speechVoiceOptionKey)
        appendCommand(kind: .state, title: "speech output", body: "apple_speech=true", metadata: ["voice": preferredVoice ?? "system"])
        speechSpeaker.speak(text, preferredVoiceName: preferredVoice) { [weak self] in
            guard let self else { return }
            self.markAwaitingSocialResponse()
            self.canSend = true
            self.statusText = "Ready"
        }
    }

    func speakBrainResponseAndWait(_ text: String) async {
        guard brainVoiceEnabled else {
            canSend = true
            statusText = "Ready"
            appendCommand(kind: .state, title: "speech output", body: "apple_speech=false", metadata: ["reason": "brain_voice_disabled"])
            return
        }
        setHostPipelineHold(.speechOutput)
        canSend = false
        let preferredVoice = runtimeOptionStringValue(for: Self.speechVoiceOptionKey)
        appendCommand(kind: .state, title: "speech output", body: "apple_speech=true", metadata: ["voice": preferredVoice ?? "system"])
        await withCheckedContinuation { continuation in
            speechSpeaker.speak(text, preferredVoiceName: preferredVoice) { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.setHostPipelineHold(.none)
                self.markAwaitingSocialResponse()
                self.canSend = self.hostPipelineQueue.isEmpty
                continuation.resume()
            }
        }
    }

    func fulfillCameraSenseRequest(
        _ event: BrainHostEvent,
        observationResponsePresentation: BrainEventPresentation = .internalOnly
    ) async {
        if let pendingCameraRequestID {
            if !didLogCoalescedCameraRequest {
                appendCommand(
                    kind: .state,
                    title: "camera request coalesced",
                    body: "Camera request already pending for \(pendingCameraRequestID).",
                    metadata: coreEventMetadata(event)
                )
                didLogCoalescedCameraRequest = true
            }
            return
        }

        pendingCameraRequestID = event.requestID ?? UUID().uuidString
        didLogCoalescedCameraRequest = false
        defer {
            pendingCameraRequestID = nil
            didLogCoalescedCameraRequest = false
        }

        let status = await requestCameraPermissionIfNeeded(requestID: event.requestID)
        await recordCameraPermissionStatus(status, requestID: event.requestID)
        guard status == .available else {
            statusText = "Camera unavailable"
            await sendHostCapabilityStatus(capability: "camera", status: status.rawValue, requestID: event.requestID, reason: "OS camera permission prompt")
            return
        }

        var phase = "permission"
        var failureMetadata = coreEventMetadata(event)

        do {
            phase = "capture"
            setHostPipelineHold(.cameraCapture)
            let data = try await captureWebcamPhotoData()
            failureMetadata["byte_count"] = "\(data.count)"
            phase = "decode"
            let imageInfo = try validateCapturedImageData(data)
            setHostPipelineHold(.none)
            phase = "store"
            let storedImage = try storeChatImage(data: data, suggestedName: "frontend-camera-\(UUID().uuidString)")
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
            appendCommand(kind: .sent, title: "camera sense", body: storedImage.url.path, metadata: metadata)
            recordRecentStimulus(
                kind: "camera_observation",
                summary: "Camera captured an image: \(imageInfo.width)x\(imageInfo.height).",
                metadata: metadata
            )
            phase = "dispatch_sense_observation"
            let response = try await awaitSenseObservationResponse(event: event) {
                try await self.brainCore.cameraObservation(
                    path: storedImage.url.path,
                    mimeType: storedImage.mimeType,
                    source: "affective_requested_capture",
                    requestID: event.requestID,
                    presentation: observationResponsePresentation
                )
            }
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            appendCommand(
                kind: .result,
                title: response.toolName,
                body: responseText.isEmpty ? storedImage.url.path : response.text,
                metadata: response.metadata.merging(metadata) { current, _ in current }
            )
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: observationResponsePresentation.mirrorsToChat,
                speak: response.shouldSpeak,
                handleHostRequests: false
            )
            appendAwaitedSenseFallbackIfNeeded(
                event: event,
                responseText: responseText,
                didAppendBrainChat: eventResult.didAppendBrainChat,
                presentation: observationResponsePresentation
            )
        } catch {
            setHostPipelineHold(.none)
            statusText = "Camera sense failed"
            failureMetadata["phase"] = phase
            failureMetadata.merge(cameraCaptureErrorMetadata(error)) { current, _ in current }
            appendCommand(kind: .error, title: "camera sense failed", body: error.localizedDescription, metadata: failureMetadata)
            appendCameraSenseFailureChatIfNeeded(
                error,
                metadata: failureMetadata,
                presentation: observationResponsePresentation
            )
        }
    }

    func appendCameraSenseFailureChatIfNeeded(
        _ error: Error,
        metadata: [String: String],
        presentation: BrainEventPresentation
    ) {
        guard presentation.mirrorsToChat else { return }
        let message: String
        if let cameraError = error as? CameraCaptureError, cameraError == .blackImageData {
            message = "I tried to use the camera, but the frame came back nearly black."
        } else {
            message = "I tried to use the camera, but I couldn't get a usable image. \(error.localizedDescription)"
        }
        chatEntries.append(.init(
            kind: .error,
            title: "Camera",
            body: message,
            metadata: metadata
        ))
    }

    func ensureCameraPermissionForCaptureCommand(title: String) async -> Bool {
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
        appendCommand(
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
            await sendHostCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.available.rawValue, requestID: requestID, reason: "Camera permission already granted")
            return .available
        case .notDetermined:
            setHostPipelineHold(.cameraPermission)
            await sendHostCapabilityStatus(capability: "camera", status: "pending", requestID: requestID, reason: "OS camera permission prompt")
            let task = Task { await Self.requestSystemCameraPermission() }
            cameraPermissionRequestTask = task
            let status = await task.value
            cameraPermissionRequestTask = nil
            if status == .available {
                await Self.waitForSystemCameraAuthorization()
            }
            setHostPipelineHold(.none)
            await sendHostCapabilityStatus(capability: "camera", status: status.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            return status
        case .denied, .restricted:
            await sendHostCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.denied.rawValue, requestID: requestID, reason: "OS camera permission prompt")
            return .denied
        @unknown default:
            await sendHostCapabilityStatus(capability: "camera", status: HostCameraPermissionStatus.unavailable.rawValue, requestID: requestID, reason: "OS camera permission prompt")
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
        appendCommand(
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
        _ event: BrainHostEvent,
        observationResponsePresentation: BrainEventPresentation = .internalOnly
    ) async {
        let previousStatus = CoreConfigStorage.currentOrientationCapabilityStatus()
        let status = await requestOrientationPermissionIfNeeded(requestID: event.requestID, reason: event.body ?? event.text)
        await recordOrientationPermissionStatus(status, requestID: event.requestID)
        if previousStatus != status.rawValue {
            await synchronizeCoreOrientationCapabilityIfNeeded(status)
        }
        guard status == .available else {
            statusText = "Orientation unavailable"
            return
        }

        do {
            statusText = "Sensing orientation"
            let observation = try await observeOrientation()
            let metadata = orientationObservationMetadata(observation, requestID: event.requestID)
            appendCommand(kind: .sent, title: "orientation sense", body: observation.summary, metadata: metadata)
            recordRecentStimulus(
                kind: "orientation_observation",
                summary: observation.summary,
                metadata: metadata
            )
            let response = try await awaitSenseObservationResponse(event: event) {
                try await self.brainCore.orientationObservation(
                    observation,
                    requestID: event.requestID,
                    presentation: observationResponsePresentation
                )
            }
            let responseText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            appendCommand(
                kind: .result,
                title: "sense_observation",
                body: responseText.isEmpty ? observation.summary : response.text,
                metadata: response.metadata.merging(metadata) { current, _ in current }
            )
            let eventResult = await applyCoreEvents(
                response.events,
                mirrorChatMessages: observationResponsePresentation.mirrorsToChat,
                speak: response.shouldSpeak,
                handleHostRequests: false
            )
            appendAwaitedSenseFallbackIfNeeded(
                event: event,
                responseText: responseText,
                didAppendBrainChat: eventResult.didAppendBrainChat,
                presentation: observationResponsePresentation
            )
            statusText = "Orientation sensed"
        } catch {
            statusText = "Orientation sense failed"
            appendCommand(kind: .error, title: "orientation sense failed", body: error.localizedDescription)
        }
    }

    func requestOrientationPermissionIfNeeded(
        requestID: String?,
        reason: String?
    ) async -> HostOrientationPermissionStatus {
        if let orientationPermissionStatusOverride {
            return orientationPermissionStatusOverride
        }

        switch CoreConfigStorage.currentOrientationCapabilityStatus() {
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

    func appendAwaitedSenseFallbackIfNeeded(
        event: BrainHostEvent,
        responseText: String,
        didAppendBrainChat: Bool,
        presentation: BrainEventPresentation
    ) {
        guard event.awaitResponse == true, presentation.mirrorsToChat, !didAppendBrainChat else { return }
        let sense = event.sense ?? "sense"
        appendCommand(
            kind: .state,
            title: "awaited sense",
            body: "\(sense) observation completed without a chat event.",
            metadata: [
                "event_type": "awaited_sense_response",
                "sense": sense,
                "request_id": event.requestID ?? "",
                "timeout_ms": event.timeoutMS.map(String.init) ?? "",
            ]
        )
    }

    func awaitSenseObservationResponse<T>(
        event: BrainHostEvent,
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

    func sendHostCapabilityStatus(
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
            let response = try await brainCore.hostCapabilityStatus(
                capability: capability,
                status: status,
                requestID: requestID,
                pendingSince: pendingSince,
                pendingElapsedMS: elapsedMS,
                reason: reason
            )
            appendCommand(
                kind: status == "denied" || status == "unavailable" ? .error : .state,
                title: "host capability",
                body: "\(capability)=\(status)",
                metadata: response.metadata
            )
        } catch {
            appendCommand(kind: .error, title: "host capability failed", body: error.localizedDescription)
        }

        if status != "pending" {
            hostCapabilityPendingSince[capability] = nil
        }
    }

    func recordOrientationPermissionStatus(_ status: HostOrientationPermissionStatus, requestID: String?) async {
        appendCommand(
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
        appendCommand(
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

    func captureWebcamPhotoData() async throws -> Data {
        #if canImport(AVFoundation)
        var lastError: Error?
        let cameraDeviceID = selectedCameraDeviceIDForCapture()
        let capturePhotoData = cameraPhotoCaptureOverride ?? {
            try await CameraPhotoCaptureSession.capturePhotoDataWithManagedLifetime(preferredDeviceUniqueID: cameraDeviceID)
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
        return maxLuminance < 8 && mean < 4 && standardDeviation < 2
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
    private var continuation: CheckedContinuation<Data, Error>?
    private var isFinished = false
    private var timeoutWorkItem: DispatchWorkItem?

    static func capturePhotoDataWithManagedLifetime(preferredDeviceUniqueID: String? = nil) async throws -> Data {
        let captureSession = CameraPhotoCaptureSession()
        captureSession.preferredDeviceUniqueID = preferredDeviceUniqueID
        return try await captureSession.capturePhotoData()
    }

    private var preferredDeviceUniqueID: String?

    func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                startCapture(continuation: continuation)
            }
        }
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            finish(with: .failure(CameraCaptureError.noImageData))
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let data = imageContext.jpegRepresentation(of: image, colorSpace: colorSpace) else {
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
            self?.finish(with: .failure(CameraCaptureError.timedOut))
        }
        timeoutWorkItem = timeout
        captureQueue.asyncAfter(deadline: .now() + 10, execute: timeout)
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

    private var preferredDeviceUniqueID: String?

    func capturePhotoData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async { [self] in
                startCapture(continuation: continuation)
            }
        }
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
