//
//  BrainHostHTTPService.swift
//  Affective
//

import Foundation

#if os(iOS) || os(macOS)
  nonisolated protocol BrainHostHTTPServicing: Sendable {
    func postJSON(url: String, headersJSON: String, body: Data) async throws -> Data
    func ingestHostEvents(eventsJSON: String)
  }

  nonisolated final class BrainHostHTTPService: BrainHostHTTPServicing, @unchecked Sendable {
    private let hostRoutes: BrainHostServiceRoutes
    private let eventSink: BrainCoreEventSink?

    init(
      textProviderPreference: HostTextProviderPreference,
      credentialProvider: @escaping BrainHostServiceRoutes.CredentialProvider = CoreConfigStorage.providerCredentials,
      providerPicker: @escaping BrainHostServiceRoutes.ProviderPicker = { $0.randomElement() },
      textRoutePicker: @escaping BrainHostServiceRoutes.TextRoutePicker = { $0.randomElement() },
      jsonLoader: BrainHostServiceRoutes.JSONLoader? = nil,
      faceRecognizer: FaceRecognizing = FaceRecognitionService(),
      eventSink: BrainCoreEventSink? = nil
    ) {
      self.hostRoutes = BrainHostServiceRoutes(
        credentialProvider: credentialProvider,
        providerPicker: providerPicker,
        textProviderPreference: textProviderPreference,
        textRoutePicker: textRoutePicker,
        jsonLoader: jsonLoader,
        faceRecognizer: faceRecognizer
      )
      self.eventSink = eventSink
    }

    var hostServiceRoutes: BrainHostServiceRoutes {
      hostRoutes
    }

    func syncConversationDispatchGeneration(_ generation: Int) {
      hostRoutes.syncConversationDispatchGeneration(generation)
    }

    func beginUserTextDispatchFromCurrentConversationGeneration() {
      hostRoutes.beginUserTextDispatchFromCurrentConversationGeneration()
    }

    func postJSON(url: String, headersJSON: String, body: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        Task.detached(priority: .userInitiated) {
          do {
            continuation.resume(returning: try self.hostRoutes.postJSON(
              url: url,
              headersJSON: headersJSON,
              body: body
            ))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    func ingestHostEvents(eventsJSON: String) {
      eventSink?.ingest(eventsJSON: eventsJSON)
    }
  }
#endif
