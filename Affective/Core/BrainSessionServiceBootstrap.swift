//
//  BrainSessionServiceBootstrap.swift
//  Affective
//

import Foundation
import os

#if os(iOS) || os(macOS)
  actor BrainSessionServiceBootstrap {
    static let shared = BrainSessionServiceBootstrap()

    private static let logger = Logger(
      subsystem: "com.zelda-built-this.AMBI",
      category: "BrainSessionBootstrap"
    )

    private var inProcessPort: UInt16?

    func resolvePort(config: BrainSessionConfig, configuredPort: UInt16?) async throws -> UInt16 {
      if let configuredPort {
        return configuredPort
      }
      if let environmentPort = Self.environmentPort() {
        return environmentPort
      }
      if let inProcessPort {
        return inProcessPort
      }
      let port = try startInProcessSession(config: config)
      inProcessPort = port
      return port
    }

    func stop() {
      if inProcessPort != nil {
        affective_session_stop()
      }
      inProcessPort = nil
    }

    private func startInProcessSession(config: BrainSessionConfig) throws -> UInt16 {
      let configData = try config.createMessage.encodedData()
      guard let configJSON = String(data: configData, encoding: .utf8) else {
        throw BrainTransportError.bootstrapFailed("could not encode BSP session config as UTF-8 JSON")
      }
      let rawPort = configJSON.withCString { pointer in
        affective_session_start(pointer)
      }
      guard rawPort > 0, rawPort <= Int32(UInt16.max) else {
        throw BrainTransportError.bootstrapFailed("affective_session_start returned invalid port \(rawPort)")
      }
      Self.logger.info("Started in-process BSP session service on port \(rawPort, privacy: .public)")
      return UInt16(rawPort)
    }

    private static func environmentPort() -> UInt16? {
      guard let raw = ProcessInfo.processInfo.environment["AFFECTIVE_BSP_PORT"],
            let value = UInt16(raw),
            value > 0
      else {
        return nil
      }
      return value
    }
  }
#endif
