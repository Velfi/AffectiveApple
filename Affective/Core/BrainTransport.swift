//
//  BrainTransport.swift
//  Affective
//

import Foundation

#if os(iOS) || os(macOS)
  nonisolated struct BrainSessionConfig: Sendable {
    let brainID: String
    let brainRoot: String
    let conversationModels: String
    let conversationReasoningEffort: String
    let imageGenerationModel: String
    let imageGenerationOutputDirectory: String
    let memoryPath: String
    let graphPath: String
    let schedulePath: String
    let maintenanceStatePath: String
    let faceEmbeddingsDirectory: String
    let hostManifestJSON: String

    init(storage: CoreConfigStorage) {
      brainID = Self.string(storage.brainID)
      brainRoot = Self.string(storage.brainRoot)
      conversationModels = Self.string(storage.conversationModels)
      conversationReasoningEffort = Self.string(storage.conversationReasoningEffort)
      imageGenerationModel = Self.string(storage.imageGenerationModel)
      imageGenerationOutputDirectory = Self.string(storage.imageGenerationOutputDir)
      memoryPath = Self.string(storage.memoryPath)
      graphPath = Self.string(storage.graphPath)
      schedulePath = Self.string(storage.schedulePath)
      maintenanceStatePath = Self.string(storage.maintenanceStatePath)
      faceEmbeddingsDirectory = Self.string(storage.faceEmbeddingsDir)
      hostManifestJSON = Self.string(storage.hostManifestJSON)
    }

    var configJSONValue: JSONValue {
      .object([
        "brain_id": .string(brainID),
        "brain_root": .string(brainRoot),
        "conversation_models": .string(conversationModels),
        "conversation_reasoning_effort": .string(conversationReasoningEffort),
        "image_generation_model": .string(imageGenerationModel),
        "image_generation_output_dir": .string(imageGenerationOutputDirectory),
        "memory_path": .string(memoryPath),
        "graph_path": .string(graphPath),
        "schedule_path": .string(schedulePath),
        "maintenance_state_path": .string(maintenanceStatePath),
        "face_embeddings_dir": .string(faceEmbeddingsDirectory),
      ])
    }

    var createMessage: JSONValue {
      .object([
        "type": .string("session.create"),
        "config": configJSONValue,
        "host_manifest_json": .string(hostManifestJSON),
      ])
    }

    private static func string(_ bytes: [UInt8]) -> String {
      String(decoding: bytes, as: UTF8.self)
    }
  }

  nonisolated struct BrainSessionHandle: Sendable, Equatable {
    let sessionID: String
    let port: UInt16
  }

  nonisolated protocol BrainTransport: Sendable {
    var eventStream: AsyncStream<[BrainEvent]> { get }

    func connect(config: BrainSessionConfig) async throws -> BrainSessionHandle
    func dispatch(_ requestJSON: Data) async throws -> BrainDispatchEnvelope
    func drainEvents() async throws -> BrainDispatchEnvelope
    func tryDrainEvents() async throws -> BrainDispatchEnvelope
    func disconnect() async
  }

  nonisolated enum BrainTransportError: Error, LocalizedError, Equatable {
    case bootstrapUnavailable(String)
    case bootstrapFailed(String)
    case connectionFailed(String)
    case disconnected
    case malformedFrame(String)
    case coreError(String)
    case timeout(String)

    var errorDescription: String? {
      switch self {
      case .bootstrapUnavailable(let message):
        "Brain Session Protocol bootstrap is unavailable: \(message)"
      case .bootstrapFailed(let message):
        "Brain Session Protocol bootstrap failed: \(message)"
      case .connectionFailed(let message):
        "Brain Session Protocol connection failed: \(message)"
      case .disconnected:
        "Brain Session Protocol connection closed."
      case .malformedFrame(let message):
        "Brain Session Protocol returned a malformed frame: \(message)"
      case .coreError(let message):
        "Brain Session Protocol core error: \(message)"
      case .timeout(let operation):
        "Brain Session Protocol timed out waiting for \(operation)."
      }
    }
  }
#endif
