//
//  Split from BrainCore.swift
//  Affective
//

import Foundation
#if canImport(AVFoundation)
  import AVFoundation
#endif
#if canImport(CoreMotion)
  import CoreMotion
#endif

#if os(iOS) || os(macOS)
  typealias AffectiveCoreHandle = OpaquePointer

  nonisolated struct AffectiveCoreCopiedResult {
    var status: Int32
    var data: String
    var errorMessage: String
    var dataBytes: Int
    var errorBytes: Int
  }

  nonisolated final class EmbeddedHostServices {
    private struct Header: Decodable {
      let name: String
      let value: String
    }

    func withHostServices<Result>(_ body: (AffectiveCoreEmbeddedHostServices) -> Result)
      -> Result
    {
      body(
        AffectiveCoreEmbeddedHostServices(
          ctx: Unmanaged.passUnretained(self).toOpaque(),
          http_post_json: embeddedHostHttpPostJSON,
          free_string: embeddedHostFreeString
        ))
    }

    func httpPostJSON(
      url: AffectiveCoreEmbeddedString,
      headersJSON: AffectiveCoreEmbeddedString,
      body: AffectiveCoreEmbeddedString,
      outData: UnsafeMutablePointer<AffectiveCoreEmbeddedString>?,
      outError: UnsafeMutablePointer<AffectiveCoreEmbeddedString>?
    ) -> Int32 {
      do {
        let response = try performPostJSON(
          url: try Self.requiredString(url, label: "url"),
          headersJSON: try Self.requiredString(headersJSON, label: "headers_json"),
          body: Self.data(from: body)
        )
        Self.copy(response, to: outData)
        Self.copy(Data(), to: outError)
        return 0
      } catch {
        Self.copy(Data(String(describing: error).utf8), to: outError)
        Self.copy(Data(), to: outData)
        return 1
      }
    }

    private func performPostJSON(url urlString: String, headersJSON: String, body: Data)
      throws -> Data
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

      let semaphore = DispatchSemaphore(value: 0)
      var result: Result<(Data, URLResponse), Error>?
      let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
          result = .failure(error)
        } else if let response {
          result = .success((data ?? Data(), response))
        } else {
          result = .failure(HostHTTPError.missingResponse)
        }
        semaphore.signal()
      }
      task.resume()
      guard semaphore.wait(timeout: .now() + 65) == .success else {
        task.cancel()
        throw HostHTTPError.timeout
      }

      let (data, response) = try result?.get() ?? {
        throw HostHTTPError.missingResponse
      }()
      guard let httpResponse = response as? HTTPURLResponse else {
        throw HostHTTPError.missingHTTPResponse
      }
      guard 200..<300 ~= httpResponse.statusCode else {
        throw HostHTTPError.badStatus(httpResponse.statusCode, String(decoding: data, as: UTF8.self))
      }
      return data
    }

    private static func requiredString(_ value: AffectiveCoreEmbeddedString, label: String)
      throws -> String
    {
      guard let ptr = value.ptr, value.len > 0 else {
        if value.len == 0 { return "" }
        throw HostHTTPError.invalidString(label)
      }
      let buffer = UnsafeBufferPointer(start: ptr, count: value.len)
      return String(decoding: buffer, as: UTF8.self)
    }

    private static func data(from value: AffectiveCoreEmbeddedString) -> Data {
      guard let ptr = value.ptr, value.len > 0 else {
        return Data()
      }
      return Data(bytes: ptr, count: value.len)
    }

    static func copy(
      _ data: Data,
      to outString: UnsafeMutablePointer<AffectiveCoreEmbeddedString>?
    ) {
      guard let outString else { return }
      guard !data.isEmpty else {
        outString.pointee = AffectiveCoreEmbeddedString(ptr: nil, len: 0)
        return
      }
      let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
      _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: pointer, count: data.count))
      outString.pointee = AffectiveCoreEmbeddedString(ptr: UnsafePointer(pointer), len: data.count)
    }

    func free(_ string: AffectiveCoreEmbeddedString) {
      guard let ptr = string.ptr, string.len > 0 else { return }
      UnsafeMutablePointer(mutating: ptr).deallocate()
    }
  }

  private enum HostHTTPError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidString(String)
    case missingResponse
    case missingHTTPResponse
    case badStatus(Int, String)
    case timeout

    var description: String {
      switch self {
      case .invalidURL(let url): return "invalid HTTP URL: \(url)"
      case .invalidString(let label): return "invalid embedded HTTP string: \(label)"
      case .missingResponse: return "host HTTP request produced no response"
      case .missingHTTPResponse: return "host HTTP request produced a non-HTTP response"
      case .badStatus(let status, let body): return "host HTTP request failed with HTTP \(status): \(body)"
      case .timeout: return "host HTTP request timed out"
      }
    }
  }

  private let embeddedHostHttpPostJSON: AffectiveCoreEmbeddedHttpPostJsonFn = {
    ctx,
    url,
    headersJSON,
    body,
    outData,
    outError in
    guard let ctx else {
      EmbeddedHostServices.copy(Data("missing embedded host services context".utf8), to: outError)
      EmbeddedHostServices.copy(Data(), to: outData)
      return 1
    }
    let services = Unmanaged<EmbeddedHostServices>.fromOpaque(ctx).takeUnretainedValue()
    return services.httpPostJSON(
      url: url,
      headersJSON: headersJSON,
      body: body,
      outData: outData,
      outError: outError
    )
  }

  private let embeddedHostFreeString: AffectiveCoreEmbeddedFreeHostStringFn = { ctx, string in
    guard let ctx else { return }
    let services = Unmanaged<EmbeddedHostServices>.fromOpaque(ctx).takeUnretainedValue()
    services.free(string)
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
    let openAIAPIKey: [UInt8]
    let anthropicAPIKey: [UInt8]
    let googleAPIKey: [UInt8]
    let memoryPath: [UInt8]
    let graphPath: [UInt8]
    let schedulePath: [UInt8]
    let eventsPath: [UInt8]
    let maintenanceStatePath: [UInt8]
    let faceEmbeddingsDir: [UInt8]
    let hostManifestJSON: [UInt8]

    init(
      brain: BrainDescriptor,
      providerCredentials explicitProviderCredentials: [ProviderCredentialKey: String]? = nil
    ) {
      let providerCredentials = explicitProviderCredentials ?? Self.providerCredentials()
      brainID = Array(brain.id.utf8)
      brainRoot = Array(brain.rootURL.path.utf8)
      conversationModels = Array(Self.conversationModels(for: providerCredentials).utf8)
      conversationReasoningEffort = Array("auto".utf8)
      imageGenerationModel = Array("gemini-3.1-flash-image".utf8)
      imageGenerationOutputDir = Array(
        brain.rootURL.appendingPathComponent("generated/images", isDirectory: true).path.utf8)
      openAIAPIKey = Array((providerCredentials[.openAI] ?? "").utf8)
      anthropicAPIKey = Array((providerCredentials[.anthropic] ?? "").utf8)
      googleAPIKey = Array((providerCredentials[.google] ?? "").utf8)
      memoryPath = Array(brain.memoryDatabaseURL.path.utf8)
      graphPath = Array(brain.graphDatabaseURL.path.utf8)
      schedulePath = Array(brain.scheduleURL.path.utf8)
      eventsPath = Array(brain.eventsURL.path.utf8)
      maintenanceStatePath = Array(brain.maintenanceStateURL.path.utf8)
      faceEmbeddingsDir = Array(brain.faceEmbeddingsURL.path.utf8)
      hostManifestJSON = Array(Self.hostManifestJSON(
        hasProvider: !providerCredentials.isEmpty,
        cameraStatus: Self.currentCameraCapabilityStatus(),
        orientationStatus: Self.currentOrientationCapabilityStatus()
      ).utf8)
    }

    func withConfig<Result>(_ body: (AffectiveCoreEmbeddedConfig) -> Result) -> Result {
      brainID.withUnsafeBufferPointer { brainID in
        brainRoot.withUnsafeBufferPointer { brainRoot in
          conversationModels.withUnsafeBufferPointer { conversationModels in
            conversationReasoningEffort.withUnsafeBufferPointer { conversationReasoningEffort in
              imageGenerationModel.withUnsafeBufferPointer { imageGenerationModel in
                imageGenerationOutputDir.withUnsafeBufferPointer { imageGenerationOutputDir in
                  openAIAPIKey.withUnsafeBufferPointer { openAIAPIKey in
                    anthropicAPIKey.withUnsafeBufferPointer { anthropicAPIKey in
                      googleAPIKey.withUnsafeBufferPointer { googleAPIKey in
                        memoryPath.withUnsafeBufferPointer { memoryPath in
                          graphPath.withUnsafeBufferPointer { graphPath in
                            schedulePath.withUnsafeBufferPointer { schedulePath in
                              eventsPath.withUnsafeBufferPointer { eventsPath in
                                maintenanceStatePath.withUnsafeBufferPointer {
                                  maintenanceStatePath in
                                  faceEmbeddingsDir.withUnsafeBufferPointer { faceEmbeddingsDir in
                                    hostManifestJSON.withUnsafeBufferPointer { hostManifestJSON in
                                      body(
                                        AffectiveCoreEmbeddedConfig(
                                          brain_id: Self.string(brainID),
                                          brain_root: Self.string(brainRoot),
                                          conversation_models: Self.string(conversationModels),
                                          conversation_reasoning_effort: Self.string(
                                            conversationReasoningEffort),
                                          image_generation_model: Self.string(imageGenerationModel),
                                          image_generation_output_dir: Self.string(
                                            imageGenerationOutputDir),
                                          openai_api_key: Self.string(openAIAPIKey),
                                          anthropic_api_key: Self.string(anthropicAPIKey),
                                          google_api_key: Self.string(googleAPIKey),
                                          memory_path: Self.string(memoryPath),
                                          graph_path: Self.string(graphPath),
                                          schedule_path: Self.string(schedulePath),
                                          events_path: Self.string(eventsPath),
                                          maintenance_state_path: Self.string(maintenanceStatePath),
                                          face_embeddings_dir: Self.string(faceEmbeddingsDir),
                                          host_manifest_json: Self.string(hostManifestJSON)
                                        ))
                                    }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    static func string(_ buffer: UnsafeBufferPointer<UInt8>) -> AffectiveCoreEmbeddedString {
      AffectiveCoreEmbeddedString(ptr: buffer.baseAddress, len: buffer.count)
    }

    static func providerCredentials() -> [ProviderCredentialKey: String] {
      ProviderCredentialKey.allCases.reduce(into: [:]) { credentials, key in
        guard
          let value = try? BrainCore.credentialStore.credential(for: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
        else {
          return
        }
        credentials[key] = value
      }
    }

    static func conversationModels(for credentials: [ProviderCredentialKey: String])
      -> String
    {
      var models: [String] = []
      if credentials[.openAI] != nil {
        models.append("openai:gpt-4.1-nano")
      }
      if credentials[.anthropic] != nil {
        models.append("anthropic:claude-haiku-4-5-20251001")
      }
      if credentials[.google] != nil {
        models.append("google:gemini-3.1-flash-lite")
      }
      return models.joined(separator: ",")
    }

    static func hostManifestJSON(
      hasProvider: Bool,
      cameraStatus: String = "prompt_required",
      orientationStatus: String = "prompt_required"
    ) -> String {
      #if os(macOS)
        let platform = "macos"
      #elseif os(iOS)
        let platform = "ios"
      #else
        let platform = "unknown"
      #endif
      var capabilities = EmbeddedProtocolContract.baseHostCapabilities.map(JSONValue.string)
      if Self.shouldAdvertiseOrientationQuery(orientationStatus: orientationStatus) {
        capabilities.append(.string("orientation_query"))
        capabilities.append(.string("sense_observation"))
      }
      if hasProvider {
        capabilities.append(contentsOf: EmbeddedProtocolContract.providerHostCapabilities(excludingCamera: !Self.shouldAdvertiseLiveCamera(cameraStatus: cameraStatus)).map(JSONValue.string))
      }
      let manifest: JSONValue = .object([
        "api_version": .number(Double(EmbeddedProtocolContract.apiVersion)),
        "platform": .string(platform),
        "storage_provider": .string("file_backed_migration"),
        "capabilities": .array(capabilities),
        "capability_status": .object([
          "camera": .string(cameraStatus),
          "orientation": .string(orientationStatus),
        ]),
        "feature_flags": .object([
          "streaming_events": .bool(true),
          "logical_store": .bool(false),
        ]),
        "max_envelope_bytes": .number(16 * 1024),
        "max_event_count": .number(12),
        "max_event_text_bytes": .number(768),
        "raw_ref_ttl_seconds": .number(24 * 60 * 60),
      ])
      let data = (try? manifest.encodedData()) ?? Data("{}".utf8)
      return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func shouldAdvertiseLiveCamera(cameraStatus: String) -> Bool {
      cameraStatus == "available" || cameraStatus == "prompt_required"
    }

    static func shouldAdvertiseOrientationQuery(orientationStatus: String) -> Bool {
      orientationStatus == "available" || orientationStatus == "prompt_required"
    }

    static func currentCameraCapabilityStatus() -> String {
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
  }

  nonisolated enum EmbeddedProtocolContract {
    static let apiVersion = 2

    static let baseHostCapabilities: [String] = [
      "typed_text",
      "poke_sequence",
      "short_touch",
      "long_touch",
      "tool_call",
      "speech_output",
      "uploaded_media_read",
      "stored_memory_read",
      "stored_memory_write",
      "stored_image_read",
      "identity_recognition",
      "introspection",
      "time_lookup",
      "power_status",
      "storage_fullness",
      "database_stats",
      "reminder_io",
      "image_generation",
      "face_picture_update",
      "local_process_io",
      "facial_expression_output",
    ]

    static let providerHostCapabilities: [String] = [
      "visual_description",
      "visual_comparison",
    ]

    static func providerHostCapabilities(excludingCamera: Bool) -> [String] {
      excludingCamera ? providerHostCapabilities : ["live_camera"] + providerHostCapabilities
    }

    static let wrapperDispatchEventTypes: [String] = [
      "typed_text",
      "short_touch",
      "long_touch",
      "poke_sequence",
      "tool_call",
      "sense_observation",
    ]

    static let eventTypesRequiringHostCapability: [String] = [
      "typed_text",
      "short_touch",
      "long_touch",
      "poke_sequence",
      "tool_call",
      "sense_observation",
    ]

  }
#endif
