//
//  Split from BrainCore.swift
//  Affective
//

import Foundation
#if canImport(os)
  import os
#endif
#if canImport(AVFoundation)
  import AVFoundation
#endif
#if canImport(CoreMotion)
  import CoreMotion
#endif

#if os(iOS) || os(macOS)
  nonisolated final class BrainHostServiceRoutes {
    typealias CredentialProvider = HostProviderRouter.CredentialProvider
    typealias ProviderPicker = HostProviderRouter.ProviderPicker
    typealias JSONLoader = HostLLMCompletionClient.JSONLoader
    typealias TextRoutePicker = HostLLMCompletionClient.RoutePicker

    nonisolated(unsafe) private static weak var currentInstance: BrainHostServiceRoutes?
    nonisolated(unsafe) static var llmCompletionObserver: (@Sendable (HostLLMCompletionObservation) -> Void)?

    static func clearLLMCompletionObserver() {
      llmCompletionObserver = nil
    }

    private struct Header: Decodable {
      let name: String
      let value: String
    }

    private struct HostImageGenerationPayload: Decodable {
      let prompt: String
      let outputDirectory: String

      enum CodingKeys: String, CodingKey {
        case prompt
        case outputDirectory = "output_dir"
      }
    }

    private struct HostVisionCompletionPayload: Decodable {
      let prompt: String
      let imagePaths: [String]
      let responseFormat: String
      let maxTokens: Int?
      let temperature: Double?
      let jsonSchema: String?

      enum CodingKeys: String, CodingKey {
        case prompt
        case imagePaths = "image_paths"
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case temperature
        case jsonSchema = "json_schema"
      }
    }

    private struct HostImageGenerationResponse: Encodable {
      let path: String
      let mimeType: String

      enum CodingKeys: String, CodingKey {
        case path
        case mimeType = "mime_type"
      }
    }

    private static let hostLLMCompletionURL = "affective-host://llm/complete"
    private static let hostHTTPLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "EmbeddedHostHTTP")
    private static let hostImageGenerationURL = "affective-host://image/generate"
    private static let hostVisionCompletionURL = "affective-host://vision/complete"
    private static let hostRecognizeIdentifyURL = "affective-host://recognize/identify"
    private static let hostRecognizeEnrollURL = "affective-host://recognize/enroll"
    private static let hostEmbedComputeURL = "affective-host://embed/compute"
    private static let hostSystemPowerURL = "affective-host://system/power"
    private static let hostSystemStorageURL = "affective-host://system/storage"

    private let providerRouter: HostProviderRouter
    private let textProviderPreference: HostTextProviderPreference
    private let textRoutePicker: TextRoutePicker
    private let jsonLoader: JSONLoader?
    private let faceRecognizer: FaceRecognizing
    private let conversationDispatchLock = NSLock()
    private var conversationDispatchGeneration = 0
    private var activeUserTextDispatchGeneration = 0
    private let identifyCacheLock = NSLock()
    private var identifyCache: [String: (data: Data, storedAt: Date)] = [:]
    private static let identifyCacheTTL: TimeInterval = 60

    init(
      credentialProvider: @escaping CredentialProvider = CoreConfigStorage.providerCredentials,
      providerPicker: @escaping ProviderPicker = { $0.randomElement() },
      textProviderPreference: HostTextProviderPreference = .random,
      textRoutePicker: @escaping TextRoutePicker = { $0.randomElement() },
      jsonLoader: JSONLoader? = nil,
      faceRecognizer: FaceRecognizing = FaceRecognitionService()
    ) {
      self.providerRouter = HostProviderRouter(
        credentialProvider: credentialProvider,
        providerPicker: providerPicker
      )
      self.textProviderPreference = textProviderPreference
      self.textRoutePicker = textRoutePicker
      self.jsonLoader = jsonLoader
      self.faceRecognizer = faceRecognizer
      Self.currentInstance = self
    }

    func syncConversationDispatchGeneration(_ generation: Int) {
      conversationDispatchLock.lock()
      conversationDispatchGeneration = generation
      conversationDispatchLock.unlock()
    }

    func beginUserTextDispatchFromCurrentConversationGeneration() {
      conversationDispatchLock.lock()
      activeUserTextDispatchGeneration = conversationDispatchGeneration
      conversationDispatchLock.unlock()
    }

    func beginUserTextDispatch(generation: Int) {
      conversationDispatchLock.lock()
      activeUserTextDispatchGeneration = generation
      conversationDispatchLock.unlock()
    }

    func isUserTextDispatchSuperseded() -> Bool {
      conversationDispatchLock.lock()
      defer { conversationDispatchLock.unlock() }
      return activeUserTextDispatchGeneration != conversationDispatchGeneration
    }

    func postJSON(url urlString: String, headersJSON: String, body: Data) throws -> Data {
      try performPostJSON(url: urlString, headersJSON: headersJSON, body: body)
    }

    func requestForPostJSON(url urlString: String, headersJSON: String, body: Data)
      throws -> URLRequest
    {
      guard let url = URL(string: urlString) else {
        throw HostHTTPError.invalidURL(urlString)
      }
      let headers = try JSONDecoder().decode([Header].self, from: Data(headersJSON.utf8))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = 60
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      for header in headers {
        request.setValue(header.value, forHTTPHeaderField: header.name)
      }
      try providerRouter.authorizeProviderRequest(&request)
      return request
    }

    private func performPostJSON(url urlString: String, headersJSON: String, body: Data)
      throws -> Data
    {
      if urlString == Self.hostLLMCompletionURL {
        return try performHostLLMCompletion(body: body)
      }
      if urlString == Self.hostImageGenerationURL {
        return try performHostImageGeneration(body: body)
      }
      if urlString == Self.hostVisionCompletionURL {
        return try performHostVisionCompletion(body: body)
      }
      if urlString == Self.hostRecognizeIdentifyURL {
        return try performHostRecognizeIdentify(body: body)
      }
      if urlString == Self.hostRecognizeEnrollURL {
        return try performHostRecognizeEnroll(body: body)
      }
      if urlString == Self.hostEmbedComputeURL {
        return try performHostEmbedCompute(body: body)
      }
      if urlString == Self.hostSystemPowerURL {
        return try HostSystemSensesReading.encodedPowerSnapshot()
      }
      if urlString == Self.hostSystemStorageURL {
        return try HostSystemSensesReading.encodedStorageSnapshot()
      }

      let request = try requestForPostJSON(url: urlString, headersJSON: headersJSON, body: body)
      let (data, response) = try Self.runBlockingDetached {
        try await URLSession.shared.data(for: request)
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        throw HostHTTPError.missingHTTPResponse
      }
      guard 200..<300 ~= httpResponse.statusCode else {
        throw HostHTTPError.badStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
      }
      return data
    }

    private func performHostLLMCompletion(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(HostLLMPromptPayload.self, from: body)
      let prompt = HostPromptBuilder.combinedPrompt(for: payload)
      let client = HostLLMCompletionClient(
        providerRouter: providerRouter,
        textProviderPreference: textProviderPreference,
        routePicker: textRoutePicker,
        jsonLoader: jsonLoader
      )
      let maxTokens = payload.maxTokens ?? 512
      let request = HostLLMCompletionRequest(
        prompt: prompt,
        maxTokens: maxTokens,
        responseFormat: HostResponseFormat(rawValue: payload.responseFormat) ?? .text,
        jsonSchema: payload.jsonSchema ?? "{}"
      )
      let completion: HostLLMCompletionResponse
      if try client.primaryRoute() == .appleFoundationModels {
        completion = try Self.runBlockingOnMainActor {
          try await client.complete(request)
        }
      } else {
        completion = try Self.runBlockingDetached {
          try await client.complete(request)
        }
      }
      let observation = payload.completionObservation(
        provider: completion.source,
        maxTokens: maxTokens,
        prompt: prompt,
        response: completion.text
      )
      Self.logHostLLMCompletion(observation)
      return Data(completion.text.utf8)
    }

    private static func logHostLLMCompletion(_ observation: HostLLMCompletionObservation) {
      hostHTTPLogger.info(
        "Host LLM complete subsystem=\(observation.subsystem, privacy: .public) \(observation.eventLogBody, privacy: .public)"
      )
      llmCompletionObserver?(observation)
    }

    private func performHostRecognizeIdentify(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(FaceRecognitionIdentifyRequest.self, from: body)
      if let cached = cachedIdentifyResponse(for: payload.imagePath) {
        return cached
      }
      let result = try faceRecognizer.identify(payload)
      let encoded = try JSONEncoder().encode(result)
      storeIdentifyResponse(encoded, for: payload.imagePath)
      return encoded
    }

    private func cachedIdentifyResponse(for imagePath: String) -> Data? {
      identifyCacheLock.lock()
      defer { identifyCacheLock.unlock() }
      guard let cached = identifyCache[imagePath] else { return nil }
      guard Date().timeIntervalSince(cached.storedAt) <= Self.identifyCacheTTL else {
        identifyCache.removeValue(forKey: imagePath)
        return nil
      }
      return cached.data
    }

    private func storeIdentifyResponse(_ data: Data, for imagePath: String) {
      identifyCacheLock.lock()
      identifyCache[imagePath] = (data, Date())
      identifyCacheLock.unlock()
    }

    private func removeCachedIdentifyResponse(for imagePath: String) {
      identifyCacheLock.lock()
      identifyCache.removeValue(forKey: imagePath)
      identifyCacheLock.unlock()
    }

    static func primeIdentifyCache(imagePath: String, result: FaceRecognitionIdentityResult) {
      guard let data = try? JSONEncoder().encode(result) else { return }
      guard let currentInstance else { return }
      currentInstance.storeIdentifyResponse(data, for: imagePath)
    }

    private func performHostRecognizeEnroll(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(FaceRecognitionEnrollRequest.self, from: body)
      let result = try faceRecognizer.enroll(payload)
      removeCachedIdentifyResponse(for: payload.imagePath)
      return try JSONEncoder().encode(result)
    }

    private func performHostEmbedCompute(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(HostEmbeddingRequest.self, from: body)
      return try HostEmbeddingClient.encodedResponse(for: payload.texts)
    }

    private func performHostImageGeneration(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(HostImageGenerationPayload.self, from: body)
      let client = HostImageGenerationClient(providerRouter: providerRouter, jsonLoader: jsonLoader)
      let generated = try Self.runBlockingDetached {
        try await client.generate(HostImageGenerationRequest(
          prompt: payload.prompt,
          outputDirectory: URL(fileURLWithPath: payload.outputDirectory)
        ))
      }
      return try JSONEncoder().encode(HostImageGenerationResponse(
        path: generated.path,
        mimeType: generated.mimeType
      ))
    }

    private func performHostVisionCompletion(body: Data) throws -> Data {
      let payload = try JSONDecoder().decode(HostVisionCompletionPayload.self, from: body)
      let responseFormat = HostResponseFormat(rawValue: payload.responseFormat) ?? .text
      let client = HostVisionCompletionClient(providerRouter: providerRouter, jsonLoader: jsonLoader)
      let completion = try Self.runBlockingDetached {
        try await client.complete(HostVisionCompletionRequest(
          prompt: payload.prompt,
          imagePaths: payload.imagePaths,
          responseFormat: responseFormat,
          maxTokens: payload.maxTokens ?? 800,
          temperature: payload.temperature ?? 0.2,
          jsonSchema: payload.jsonSchema ?? "{}"
        ))
      }
      return Data(completion.text.utf8)
    }

    /// Foundation Models must run on the main actor.
    private static func runBlockingOnMainActor<T>(
      timeoutSeconds: TimeInterval = 65,
      _ work: @escaping @Sendable @MainActor () async throws -> T
    ) throws -> T {
      let semaphore = DispatchSemaphore(value: 0)
      let resultBox = BlockingAsyncResultBox<T>()
      Task { @MainActor in
        do {
          resultBox.result = .success(try await work())
        } catch {
          resultBox.result = .failure(error)
        }
        semaphore.signal()
      }
      guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
        throw HostHTTPError.timeout
      }
      return try resultBox.result?.get() ?? {
        throw HostHTTPError.missingResponse
      }()
    }

    /// Network and credential-provider completions stay off the main actor.
    private static func runBlockingDetached<T>(
      timeoutSeconds: TimeInterval = 65,
      _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
      let semaphore = DispatchSemaphore(value: 0)
      let resultBox = BlockingAsyncResultBox<T>()
      Task.detached(priority: .userInitiated) {
        do {
          resultBox.result = .success(try await work())
        } catch {
          resultBox.result = .failure(error)
        }
        semaphore.signal()
      }
      guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
        throw HostHTTPError.timeout
      }
      return try resultBox.result?.get() ?? {
        throw HostHTTPError.missingResponse
      }()
    }

    private final class BlockingAsyncResultBox<T>: @unchecked Sendable {
      var result: Result<T, Error>?
    }

    private enum HostHTTPError: Error, CustomStringConvertible {
      case invalidURL(String)
      case missingResponse
      case missingHTTPResponse
      case badStatus(Int, String)
      case timeout
      case supersededByNewUserMessage

      var description: String {
        switch self {
        case .invalidURL(let url): return "invalid HTTP URL: \(url)"
        case .missingResponse: return "host HTTP request produced no response"
        case .missingHTTPResponse: return "host HTTP request produced a non-HTTP response"
        case .badStatus(let status, let body): return "host HTTP request failed with HTTP \(status): \(body)"
        case .timeout: return "host HTTP request timed out"
        case .supersededByNewUserMessage: return "superseded by new user message"
        }
      }
    }

  }
#endif

#if os(iOS) || os(macOS)
  nonisolated struct CoreConfigStorage {
    let brainID: [UInt8]
    let brainRoot: [UInt8]
    let conversationModels: [UInt8]
    let conversationReasoningEffort: [UInt8]
    let imageGenerationModel: [UInt8]
    let imageGenerationOutputDir: [UInt8]
    let memoryPath: [UInt8]
    let graphPath: [UInt8]
    let schedulePath: [UInt8]
    let maintenanceStatePath: [UInt8]
    let faceEmbeddingsDir: [UInt8]
    let hostManifestJSON: [UInt8]

    init(
      brain: BrainDescriptor,
      providerCredentials explicitProviderCredentials: [ProviderCredentialKey: String]? = nil,
      appleFoundationModelsStatus: AppleFoundationModelsAvailability = AppleFoundationModelsTextClient.currentAvailability(),
      textProviderPreference: HostTextProviderPreference? = nil
    ) {
      let providerCredentials = explicitProviderCredentials ?? Self.providerCredentials()
      let resolvedTextProviderPreference = textProviderPreference ?? Self.textProviderPreference(brain: brain)
      brainID = Array(brain.id.utf8)
      brainRoot = Array(brain.rootURL.path.utf8)
      conversationModels = Array(Self.conversationModels(
        for: providerCredentials,
        appleFoundationModelsStatus: appleFoundationModelsStatus,
        textProviderPreference: resolvedTextProviderPreference
      ).utf8)
      conversationReasoningEffort = Array("auto".utf8)
      imageGenerationModel = Array("gemini-3.1-flash-image".utf8)
      imageGenerationOutputDir = Array(
        brain.rootURL.appendingPathComponent("generated/images", isDirectory: true).path.utf8)
      memoryPath = Array(brain.memoryDatabaseURL.path.utf8)
      graphPath = Array(brain.graphDatabaseURL.path.utf8)
      schedulePath = Array(brain.scheduleURL.path.utf8)
      maintenanceStatePath = Array(brain.maintenanceStateURL.path.utf8)
      faceEmbeddingsDir = Array(brain.faceEmbeddingsURL.path.utf8)
      hostManifestJSON = Array(EmbeddedHostCapabilityManifest.current(
        providerCredentials: providerCredentials,
        appleFoundationModelsStatus: appleFoundationModelsStatus,
        textProviderPreference: resolvedTextProviderPreference,
        cameraStatus: Self.currentCameraCapabilityStatus(brain: brain),
        orientationStatus: Self.currentOrientationCapabilityStatus(),
        motionGestureStatus: Self.currentMotionGestureCapabilityStatus(brain: brain),
        biometricPolicy: BiometricDataPolicy.load(for: brain)
      ).jsonString().utf8)
    }

    static func providerCredentials() -> [ProviderCredentialKey: String] {
      ProviderCredentialKey.resolvedCredentials(using: BrainCore.credentialStore)
    }

    static func conversationModels(
      for credentials: [ProviderCredentialKey: String],
      appleFoundationModelsStatus: AppleFoundationModelsAvailability = .unsupportedPlatform,
      textProviderPreference: HostTextProviderPreference = .random
    )
      -> String
    {
      var models: [String] = []
      let shouldIncludeLocal = appleFoundationModelsStatus.isAvailable
        && (textProviderPreference == .random || textProviderPreference == .local)
      if shouldIncludeLocal {
        models.append("openai:gpt-4.1-nano")
      }
      if credentials[.openAI] != nil
          && (textProviderPreference == .random || textProviderPreference == .openAI)
          && !models.contains("openai:gpt-4.1-nano") {
        models.append("openai:gpt-4.1-nano")
      }
      if credentials[.anthropic] != nil
          && (textProviderPreference == .random || textProviderPreference == .anthropic) {
        models.append("anthropic:claude-haiku-4-5-20251001")
      }
      if credentials[.google] != nil
          && (textProviderPreference == .random || textProviderPreference == .google) {
        models.append("google:gemini-3.1-flash-lite")
      }
      if credentials[.deepseek] != nil
          && (textProviderPreference == .random || textProviderPreference == .deepseek) {
        models.append("deepseek:deepseek-chat")
      }
      return models.joined(separator: ",")
    }

    static func textProviderPreference(brain: BrainDescriptor?) -> HostTextProviderPreference {
      guard let brain,
            let data = try? Data(contentsOf: brain.runtimeOptionsURL),
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawValue = object[AffectiveViewModel.textProviderPreferenceOptionKey] as? String
      else {
        return .random
      }
      return HostTextProviderPreference(rawValue: rawValue)?.resolvedForHostRouting() ?? .random
    }

    static func hostManifestJSON(
      hasProvider: Bool,
      appleFoundationModelsStatus: AppleFoundationModelsAvailability = .unsupportedPlatform,
      textProviderPreference: HostTextProviderPreference = .random,
      cameraStatus: String = "prompt_required",
      orientationStatus: String = "prompt_required",
      motionGestureStatus: String = currentMotionGestureCapabilityStatus(),
      biometricPolicy: BiometricDataPolicy = .disabledDefault
    ) -> String {
      EmbeddedHostCapabilityManifest(
        configuredProviders: hasProvider ? Set(ProviderCredentialKey.allCases) : [],
        appleFoundationModelsStatus: appleFoundationModelsStatus,
        textProviderPreference: textProviderPreference,
        cameraStatus: cameraStatus,
        orientationStatus: orientationStatus,
        motionGestureStatus: motionGestureStatus,
        biometricPolicy: biometricPolicy
      ).jsonString()
    }

    static func shouldAdvertiseCameraSense(cameraStatus: String) -> Bool {
      cameraStatus == "available" || cameraStatus == "prompt_required"
    }

    static func shouldAdvertiseOrientationQuery(orientationStatus: String) -> Bool {
      orientationStatus == "available" || orientationStatus == "prompt_required"
    }

    static func currentCameraCapabilityStatus(brain: BrainDescriptor? = nil) -> String {
      if let brain,
         let data = try? Data(contentsOf: brain.runtimeOptionsURL),
         !data.isEmpty,
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let rawValue = object[AffectiveViewModel.cameraCaptureEnabledOptionKey] as? String,
         rawValue == "off" {
        return "disabled"
      }
      #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
          return "available"
        case .notDetermined:
          return "prompt_required"
        case .denied, .restricted:
          return "denied"
        @unknown default:
          return "unavailable"
        }
      #else
        return "unavailable"
      #endif
    }

    static func currentOrientationCapabilityStatus() -> String {
      #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        let stored = UserDefaults.standard.string(forKey: AffectiveViewModel.orientationPermissionStatusKey)
        if stored == HostOrientationPermissionStatus.available.rawValue {
          return HostOrientationPermissionStatus.available.rawValue
        }
        if stored == HostOrientationPermissionStatus.denied.rawValue {
          return HostOrientationPermissionStatus.denied.rawValue
        }
        return HostOrientationPermissionStatus.promptRequired.rawValue
      #else
        return HostOrientationPermissionStatus.unavailable.rawValue
      #endif
    }

    static func currentMotionGestureCapabilityStatus(brain: BrainDescriptor? = nil) -> String {
      guard motionGestureEnabled(brain: brain) else {
        return "disabled"
      }
      #if os(iOS) && canImport(CoreMotion) && !targetEnvironment(simulator)
        return "prompt_required"
      #else
        return "unavailable"
      #endif
    }

    static func currentDateTimeCapabilityStatus() -> String {
      "available"
    }

    static func motionGestureEnabled(brain: BrainDescriptor?) -> Bool {
      guard let brain,
            let data = try? Data(contentsOf: brain.runtimeOptionsURL),
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawValue = object[AffectiveViewModel.motionGestureEnabledOptionKey] as? String
      else {
        return false
      }
      return rawValue == "on"
    }
  }

  nonisolated struct EmbeddedHostCapabilityManifest {
    let configuredProviders: Set<ProviderCredentialKey>
    let appleFoundationModelsStatus: AppleFoundationModelsAvailability
    let textProviderPreference: HostTextProviderPreference
    let cameraStatus: String
    let orientationStatus: String
    let motionGestureStatus: String
    let biometricPolicy: BiometricDataPolicy

    init(
      configuredProviders: Set<ProviderCredentialKey>,
      appleFoundationModelsStatus: AppleFoundationModelsAvailability,
      textProviderPreference: HostTextProviderPreference,
      cameraStatus: String,
      orientationStatus: String,
      motionGestureStatus: String = "unavailable",
      biometricPolicy: BiometricDataPolicy = .disabledDefault
    ) {
      self.configuredProviders = configuredProviders
      self.appleFoundationModelsStatus = appleFoundationModelsStatus
      self.textProviderPreference = textProviderPreference
      self.cameraStatus = cameraStatus
      self.orientationStatus = orientationStatus
      self.motionGestureStatus = motionGestureStatus
      self.biometricPolicy = biometricPolicy
    }

    static func current(
      providerCredentials: [ProviderCredentialKey: String],
      appleFoundationModelsStatus: AppleFoundationModelsAvailability,
      textProviderPreference: HostTextProviderPreference,
      cameraStatus: String,
      orientationStatus: String,
      motionGestureStatus: String = CoreConfigStorage.currentMotionGestureCapabilityStatus(),
      biometricPolicy: BiometricDataPolicy = .disabledDefault
    ) -> EmbeddedHostCapabilityManifest {
      EmbeddedHostCapabilityManifest(
        configuredProviders: Set(providerCredentials.keys),
        appleFoundationModelsStatus: appleFoundationModelsStatus,
        textProviderPreference: textProviderPreference,
        cameraStatus: cameraStatus,
        orientationStatus: orientationStatus,
        motionGestureStatus: motionGestureStatus,
        biometricPolicy: biometricPolicy
      )
    }

    var hasTextRouting: Bool {
      Self.hasRoutableTextCompletion(
        configuredProviders: configuredProviders,
        appleFoundationModelsStatus: appleFoundationModelsStatus,
        textProviderPreference: textProviderPreference
      )
    }

    var hasNetworkProviderRouting: Bool {
      !configuredProviders.isEmpty
    }

    static func hasRoutableTextCompletion(
      configuredProviders: Set<ProviderCredentialKey>,
      appleFoundationModelsStatus: AppleFoundationModelsAvailability,
      textProviderPreference: HostTextProviderPreference
    ) -> Bool {
      let router = HostProviderRouter(
        credentialProvider: {
          ProviderCredentialKey.allCases.reduce(into: [ProviderCredentialKey: String]()) { credentials, key in
            guard configuredProviders.contains(key) else { return }
            credentials[key] = "manifest-placeholder"
          }
        }
      )
      let client = HostLLMCompletionClient(
        providerRouter: router,
        appleFoundationModelsClient: AppleFoundationModelsTextClient(
          availabilityProvider: { appleFoundationModelsStatus }
        ),
        textProviderPreference: textProviderPreference.resolvedForHostRouting()
      )
      return (try? client.primaryRoute()) != nil
    }

    var sortedConfiguredProviderNames: [String] {
      var names = ProviderCredentialKey.allCases
        .filter { configuredProviders.contains($0) }
        .map(\.displayName)
      if appleFoundationModelsStatus.isAvailable {
        names.insert("Apple Foundation Models", at: 0)
      }
      return names
    }

    var selectedTextProviderNames: [String] {
      switch textProviderPreference {
      case .random:
        return sortedConfiguredProviderNames
      case .local:
        return appleFoundationModelsStatus.isAvailable ? ["Apple Foundation Models"] : []
      case .openAI, .anthropic, .google, .deepseek:
        guard let provider = textProviderPreference.credentialProvider,
              configuredProviders.contains(provider) else {
          return []
        }
        return [provider.displayName]
      }
    }

    var platform: String {
      #if os(macOS)
        return "macos"
      #elseif os(iOS)
        return "ios"
      #else
        return "unknown"
      #endif
    }

    var capabilities: [String] {
      let recognitionModelsAvailable = FaceRecognitionService.bundledModelsAvailable
      var values = EmbeddedProtocolContract.baseHostCapabilities.filter { capability in
        switch capability {
        case "face_identification":
          return biometricPolicy.canRecognize && recognitionModelsAvailable
        case "face_enrollment":
          return biometricPolicy.canEnroll && recognitionModelsAvailable
        default:
          return true
        }
      }
      if hasNetworkProviderRouting {
        values.append(contentsOf: EmbeddedProtocolContract.providerHostCapabilities)
      }
      return values.reduce(into: []) { uniqueValues, value in
        if !uniqueValues.contains(value) {
          uniqueValues.append(value)
        }
      }
    }

    var cameraIsEnabled: Bool {
      cameraStatus != "disabled"
    }

    var cameraCaptureStatus: String {
      cameraIsEnabled ? cameraStatus : "disabled"
    }

    var cameraDependentStatus: String {
      cameraIsEnabled ? "available" : "disabled"
    }

    func cameraDependentStatusWhenAvailable(_ fallback: String) -> String {
      cameraIsEnabled ? fallback : "disabled"
    }

    var senseCatalog: [PullSenseDescriptor] {
      [
        PullSenseDescriptor(
          senseID: "camera",
          direction: .pull,
          availability: cameraStatus == "available" ? "available" : cameraStatus,
          permissionState: cameraStatus,
          statusReason: "Host camera permission and hardware status."
        ),
        PullSenseDescriptor(
          senseID: "orientation",
          direction: .pull,
          availability: orientationStatus == "available" ? "available" : orientationStatus,
          permissionState: orientationStatus,
          statusReason: "Host orientation permission and Core Motion status."
        ),
        PullSenseDescriptor(
          senseID: "motion_gesture",
          direction: .push,
          availability: motionGestureStatus,
          permissionState: motionGestureStatus,
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

    func jsonString() -> String {
      let recognitionModelsAvailable = FaceRecognitionService.bundledModelsAvailable
      let identityRecognitionStatus = !biometricPolicy.canRecognize
        ? "disabled_by_policy"
        : cameraDependentStatusWhenAvailable(recognitionModelsAvailable ? "available" : "unavailable")
      let facePictureUpdateStatus = !biometricPolicy.canEnroll
        ? "disabled_by_policy"
        : cameraDependentStatusWhenAvailable(recognitionModelsAvailable ? "available" : "unavailable")
      let providerVisionStatus = hasNetworkProviderRouting
        ? cameraDependentStatus
        : "unavailable"
      let manifest: JSONValue = .object([
        "platform": .string(platform),
        "storage_provider": .string("file_backed_migration"),
        "capabilities": .array(capabilities.map(JSONValue.string)),
        "capability_status": .object([
          "camera": .string(cameraStatus),
          "camera_capture": .string(cameraCaptureStatus),
          "orientation": .string(orientationStatus),
          "motion_gesture": .string(motionGestureStatus),
          "time": .string(CoreConfigStorage.currentDateTimeCapabilityStatus()),
          "face_identification": .string(identityRecognitionStatus),
          "identity_recognition": .string(identityRecognitionStatus),
          "face_enrollment": .string(facePictureUpdateStatus),
          "face_picture_update": .string(facePictureUpdateStatus),
          "provider_routing": .string(hasTextRouting ? "available" : "unavailable"),
          "provider_vision_completion": .string(providerVisionStatus),
          "apple_foundation_models": .string(appleFoundationModelsStatus.rawValue),
        ]),
        "biometric_policy": .object([
          "owner_managed": .bool(true),
          "recognition_enabled": .bool(biometricPolicy.recognitionEnabled),
          "policy_acknowledged": .bool(biometricPolicy.policyAcknowledged),
          "enrollment_allowed": .bool(biometricPolicy.enrollmentAllowed),
          "retention_period": .string(biometricPolicy.retentionPeriod),
          "export_included": .bool(biometricPolicy.exportIncluded),
          "auto_delete_unconfirmed": .bool(biometricPolicy.autoDeleteUnconfirmed),
        ]),
        "sense_catalog": .array(senseCatalog.map(\.jsonValue)),
        "host_provider_routing": .object([
          "owner": .string("host"),
          "mode": .string(textProviderPreference.rawValue),
          "configured_providers": .array(sortedConfiguredProviderNames.map(JSONValue.string)),
        ]),
        "feature_flags": .object([
          "streaming_events": .bool(true),
          "logical_store": .bool(false),
        ]),
        "max_envelope_bytes": .number(64 * 1024),
        "max_event_count": .number(12),
        "max_event_text_bytes": .number(768),
        "raw_ref_ttl_seconds": .number(24 * 60 * 60),
      ])
      let data = (try? manifest.encodedData()) ?? Data("{}".utf8)
      return String(data: data, encoding: .utf8) ?? "{}"
    }
  }

  nonisolated enum EmbeddedProtocolContract {
    static let baseHostCapabilities: [String] = [
      "text_input",
      "speech_input",
      "speech_output",
      "camera_capture",
      "microphone_capture",
      "orientation_read",
      "orientation_query",
      "motion_gesture_read",
      "memory_read",
      "memory_write",
      "stored_memory_read",
      "stored_memory_write",
      "reminder_read",
      "reminder_write",
      "reminder_io",
      "notification_schedule",
      "uploaded_media_read",
      "stored_image_read",
      "face_identification",
      "identity_recognition",
      "face_enrollment",
      "face_picture_update",
      "facial_expression_output",
      "event_envelope",
      "event_drain",
      "sense_catalog",
      "sense_status",
      "sense_observation",
      "time_lookup",
      "power_status",
      "storage_fullness",
      "database_stats",
      "introspection",
      "local_process_io",
      "file_import",
      "file_export",
      "import_brain",
      "export_brain",
    ]

    static let providerHostCapabilities: [String] = [
      "image_generation",
      "provider_image_generation",
      "provider_vision_completion",
      "provider_text_completion",
    ]

    static let wrapperDispatchEventTypes: [String] = [
      "experience",
      "sense_observation",
      "sense_request",
      "capability_manifest",
      "capability_status",
      "action_result",
      "memory_result",
      "memory_mutation",
    ]

    static let eventTypesRequiringHostCapability: [String] = []

  }
#endif
