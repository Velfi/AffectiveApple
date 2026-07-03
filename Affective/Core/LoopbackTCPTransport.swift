//
//  LoopbackTCPTransport.swift
//  Affective
//

import Foundation
import Network
import os

#if os(iOS) || os(macOS)
  actor LoopbackTCPTransport: BrainTransport {
    nonisolated private static let logger = Logger(
      subsystem: "com.zelda-built-this.AMBI",
      category: "BrainSessionProtocol"
    )

    private let host: NWEndpoint.Host
    private let configuredPort: UInt16?
    private let hostHTTPService: BrainHostHTTPServicing
    private let queue = DispatchQueue(label: "com.zelda-built-this.AMBI.brain-session.tcp")
    private let eventContinuation: AsyncStream<[BrainEvent]>.Continuation
    private let responseTimeoutNanoseconds: UInt64

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isReceiveLoopRunning = false
    private var pendingResponses: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var activeHandle: BrainSessionHandle?

    nonisolated let eventStream: AsyncStream<[BrainEvent]>

    init(
      port: UInt16? = LoopbackTCPTransport.environmentPort(),
      host: NWEndpoint.Host = "127.0.0.1",
      hostHTTPService: BrainHostHTTPServicing,
      responseTimeoutNanoseconds: UInt64 = 120_000_000_000
    ) {
      self.configuredPort = port
      self.host = host
      self.hostHTTPService = hostHTTPService
      self.responseTimeoutNanoseconds = responseTimeoutNanoseconds
      var continuation: AsyncStream<[BrainEvent]>.Continuation!
      self.eventStream = AsyncStream { streamContinuation in
        continuation = streamContinuation
      }
      self.eventContinuation = continuation
    }

    func connect(config: BrainSessionConfig) async throws -> BrainSessionHandle {
      if let activeHandle {
        return activeHandle
      }
      let configuredPort = try await BrainSessionServiceBootstrap.shared.resolvePort(
        config: config,
        configuredPort: configuredPort
      )
      let nwPort = NWEndpoint.Port(rawValue: configuredPort) ?? 0
      let connection = NWConnection(host: host, port: nwPort, using: .tcp)
      self.connection = connection
      try await start(connection)
      startReceiveLoopIfNeeded()
      let response = try await sendRequest(config.createMessage, expecting: "session.ready")
      let object = response.objectValue ?? [:]
      let sessionID = object["session_id"]?.stringValue ?? UUID().uuidString
      let responsePort = UInt16(object["port"]?.bspNumberValue ?? Double(configuredPort))
      let handle = BrainSessionHandle(sessionID: sessionID, port: responsePort)
      activeHandle = handle
      return handle
    }

    func dispatch(_ requestJSON: Data) async throws -> BrainDispatchEnvelope {
      let requestValue = try JSONDecoder().decode(JSONValue.self, from: requestJSON)
      guard let requestID = requestValue.objectValue?["request_id"]?.stringValue, !requestID.isEmpty else {
        throw BrainTransportError.malformedFrame("dispatch request missing request_id")
      }
      guard let requestText = String(data: requestJSON, encoding: .utf8) else {
        throw BrainTransportError.malformedFrame("dispatch request was not UTF-8 JSON")
      }
      let response = try await sendRequest(.object([
        "type": .string("dispatch"),
        "request_json": .string(requestText),
      ]), expecting: "dispatch.result", requestID: requestID)
      return try Self.dispatchEnvelope(from: response)
    }

    func drainEvents() async throws -> BrainDispatchEnvelope {
      let response = try await sendRequest(.object([
        "type": .string("drain"),
      ]), expecting: "drain.result")
      return try Self.dispatchEnvelope(from: response)
    }

    func tryDrainEvents() async throws -> BrainDispatchEnvelope {
      let response = try await sendRequest(.object([
        "type": .string("drain.try"),
      ]), expecting: "drain.result")
      return try Self.dispatchEnvelope(from: response)
    }

    func disconnect() async {
      if connection != nil {
        try? await sendFireAndForget(.object([
          "type": .string("session.destroy"),
          "request_id": .string(UUID().uuidString),
        ]))
      }
      connection?.cancel()
      connection = nil
      activeHandle = nil
      await BrainSessionServiceBootstrap.shared.stop()
      eventContinuation.finish()
      for continuation in pendingResponses.values {
        continuation.resume(throwing: BrainTransportError.disconnected)
      }
      pendingResponses.removeAll()
    }

    private func start(_ connection: NWConnection) async throws {
      try await withCheckedThrowingContinuation { continuation in
        final class ResumeBox: @unchecked Sendable {
          private let lock = NSLock()
          private var didResume = false

          func resume(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            body()
          }
        }

        let box = ResumeBox()
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            box.resume { continuation.resume() }
          case .failed(let error):
            box.resume {
              continuation.resume(throwing: BrainTransportError.connectionFailed(error.localizedDescription))
            }
          case .cancelled:
            box.resume { continuation.resume(throwing: BrainTransportError.disconnected) }
          default:
            break
          }
        }
        connection.start(queue: queue)
      }
    }

    private func sendRequest(_ message: JSONValue, expecting responseType: String) async throws -> JSONValue {
      try await sendRequest(message, expecting: responseType, requestID: UUID().uuidString)
    }

    private func sendRequest(
      _ message: JSONValue,
      expecting responseType: String,
      requestID: String
    ) async throws -> JSONValue {
      guard !requestID.isEmpty else {
        throw BrainTransportError.malformedFrame("request_id must not be empty")
      }
      var object = message.objectValue ?? [:]
      object["request_id"] = .string(requestID)
      let framed = try Self.frame(.object(object))
      let responseTask = Task { () throws -> JSONValue in
        try await withCheckedThrowingContinuation { continuation in
          pendingResponses[requestID] = continuation
          write(framed) { error in
            if let error {
              Task {
                await self.failPendingResponse(
                  requestID: requestID,
                  error: BrainTransportError.connectionFailed(error.localizedDescription)
                )
              }
            }
          }
        }
      }
      let timeoutTask = Task { () throws -> JSONValue in
        try await Task.sleep(nanoseconds: responseTimeoutNanoseconds)
        throw BrainTransportError.timeout(responseType)
      }
      do {
        let response = try await Self.firstCompleted(responseTask, timeoutTask)
        if response.objectValue?["type"]?.stringValue == "dispatch.error" {
          throw Self.transportCoreError(from: response)
        }
        guard response.objectValue?["type"]?.stringValue == responseType else {
          let type = response.objectValue?["type"]?.stringValue ?? "missing"
          throw BrainTransportError.malformedFrame("expected \(responseType), got \(type)")
        }
        return response
      } catch {
        pendingResponses.removeValue(forKey: requestID)
        responseTask.cancel()
        timeoutTask.cancel()
        throw error
      }
    }

    private func sendFireAndForget(_ message: JSONValue) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        do {
          let framed = try Self.frame(message)
          write(framed) { error in
            if let error {
              continuation.resume(throwing: BrainTransportError.connectionFailed(error.localizedDescription))
            } else {
              continuation.resume()
            }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    private func write(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
      guard let connection else {
        completion(.posix(.ENOTCONN))
        return
      }
      connection.send(content: data, completion: .contentProcessed(completion))
    }

    private func startReceiveLoopIfNeeded() {
      guard !isReceiveLoopRunning, let connection else { return }
      isReceiveLoopRunning = true
      receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        Task {
          await self.handleReceive(data: data, isComplete: isComplete, error: error, connection: connection)
        }
      }
    }

    private func handleReceive(
      data: Data?,
      isComplete: Bool,
      error: NWError?,
      connection: NWConnection
    ) {
      if let data, !data.isEmpty {
        receiveBuffer.append(data)
        consumeBufferedFrames()
      }
      if error != nil || isComplete {
        for continuation in pendingResponses.values {
          continuation.resume(throwing: BrainTransportError.disconnected)
        }
        pendingResponses.removeAll()
        return
      }
      receiveNext(on: connection)
    }

    private func consumeBufferedFrames() {
      while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
        let line = receiveBuffer[..<newlineIndex]
        receiveBuffer.removeSubrange(...newlineIndex)
        guard !line.isEmpty else { continue }
        do {
          let value = try JSONDecoder().decode(JSONValue.self, from: Data(line))
          handleFrame(value)
        } catch {
          Self.logger.error("Malformed BSP frame: \(error.localizedDescription, privacy: .public)")
        }
      }
    }

    private func handleFrame(_ value: JSONValue) {
      guard let object = value.objectValue, let type = object["type"]?.stringValue else { return }
      switch type {
      case "host.http.begin":
        Task { await self.fulfillHostHTTPBegin(object) }
      case "events.push":
        ingestEventsPush(object)
      case "dispatch.result", "dispatch.error", "drain.result", "session.ready":
        guard let requestID = object["request_id"]?.stringValue, !requestID.isEmpty else {
          Self.logger.warning("Dropping BSP response without request_id type=\(type, privacy: .public)")
          return
        }
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else {
          Self.logger.warning("Dropping unmatched BSP response type=\(type, privacy: .public)")
          return
        }
        continuation.resume(returning: value)
      default:
        Self.logger.debug("Ignoring BSP frame type=\(type, privacy: .public)")
      }
    }

    private func fulfillHostHTTPBegin(_ object: [String: JSONValue]) async {
      let requestID = object["request_id"]?.stringValue ?? UUID().uuidString
      do {
        guard let url = object["url"]?.stringValue else {
          throw BrainTransportError.malformedFrame("host.http.begin missing url")
        }
        let headersJSON = object["headers_json"]?.stringValue ?? "[]"
        let body = Data(base64Encoded: object["body_b64"]?.stringValue ?? "") ?? Data()
        let data = try await hostHTTPService.postJSON(url: url, headersJSON: headersJSON, body: body)
        try await sendFireAndForget(.object([
          "type": .string("host.http.complete"),
          "request_id": .string(requestID),
          "status": .string("complete"),
          "data_b64": .string(data.base64EncodedString()),
        ]))
      } catch {
        try? await sendFireAndForget(.object([
          "type": .string("host.http.complete"),
          "request_id": .string(requestID),
          "status": .string("failed"),
          "error": .string(error.localizedDescription),
        ]))
      }
    }

    private func ingestEventsPush(_ object: [String: JSONValue]) {
      if let eventsJSON = object["events_json"]?.stringValue {
        hostHTTPService.ingestHostEvents(eventsJSON: eventsJSON)
        yieldEvents(fromJSON: eventsJSON)
        return
      }
      guard let events = object["events"] else { return }
      if let data = try? events.encodedData(),
         let eventsJSON = String(data: data, encoding: .utf8)
      {
        hostHTTPService.ingestHostEvents(eventsJSON: eventsJSON)
        yieldEvents(fromJSON: eventsJSON)
      }
    }

    private func yieldEvents(fromJSON eventsJSON: String) {
      guard let data = eventsJSON.data(using: .utf8) else { return }
      if let events = try? JSONDecoder().decode([BrainEvent].self, from: data) {
        eventContinuation.yield(events)
        return
      }
      if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
         let eventsValue = value.objectValue?["events"],
         let eventsData = try? eventsValue.encodedData(),
         let events = try? JSONDecoder().decode([BrainEvent].self, from: eventsData)
      {
        eventContinuation.yield(events)
      }
    }

    private func failPendingResponse(requestID: String, error: Error) {
      pendingResponses.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private static func frame(_ value: JSONValue) throws -> Data {
      var data = try value.encodedData()
      data.append(0x0A)
      return data
    }

    private static func dispatchEnvelope(from response: JSONValue) throws -> BrainDispatchEnvelope {
      guard var object = response.objectValue else {
        throw BrainTransportError.malformedFrame("response was not an object")
      }
      if let envelope = object["envelope"] {
        let data = try envelope.encodedData()
        guard let text = String(data: data, encoding: .utf8) else {
          throw BrainCoreError.malformedResponse
        }
        return try BrainDispatchEnvelope.decode(from: text)
      }
      object.removeValue(forKey: "type")
      let data = try JSONValue.object(object).encodedData()
      guard let text = String(data: data, encoding: .utf8) else {
        throw BrainCoreError.malformedResponse
      }
      return try BrainDispatchEnvelope.decode(from: text)
    }

    private static func transportCoreError(from response: JSONValue) -> BrainTransportError {
      let object = response.objectValue ?? [:]
      let code = object["code"]?.stringValue
      let message = object["message"]?.stringValue ?? "core dispatch failed"
      if let code, !code.isEmpty {
        return .coreError("\(code): \(message)")
      }
      return .coreError(message)
    }

    private static func firstCompleted<T>(
      _ lhs: Task<T, Error>,
      _ rhs: Task<T, Error>
    ) async throws -> T {
      try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await lhs.value }
        group.addTask { try await rhs.value }
        guard let value = try await group.next() else {
          throw BrainTransportError.disconnected
        }
        group.cancelAll()
        lhs.cancel()
        rhs.cancel()
        return value
      }
    }

    private static func environmentPort() -> UInt16? {
      guard let raw = ProcessInfo.processInfo.environment["AFFECTIVE_BSP_PORT"],
            let value = UInt16(raw)
      else {
        return nil
      }
      return value
    }
  }

  private nonisolated extension JSONValue {
    var bspNumberValue: Double? {
      if case .number(let value) = self { value } else { nil }
    }
  }
#endif
