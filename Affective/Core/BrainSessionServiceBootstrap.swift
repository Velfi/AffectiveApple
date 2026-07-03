//
//  BrainSessionServiceBootstrap.swift
//  Affective
//

import Foundation
import os

#if canImport(Darwin)
  import Darwin
#endif

#if os(iOS) || os(macOS)
  actor BrainSessionServiceBootstrap {
    static let shared = BrainSessionServiceBootstrap()

    private static let logger = Logger(
      subsystem: "com.zelda-built-this.AMBI",
      category: "BrainSessionBootstrap"
    )

    private var launchedProcess: Process?
    private var launchedPort: UInt16?
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
      if let port = try startInProcessSession(config: config) {
        inProcessPort = port
        return port
      }

      #if os(macOS)
        if let launchedPort, launchedProcess?.isRunning == true {
          return launchedPort
        }
        if let executableURL = Self.sessionExecutableURL() {
          let port = try await launchSessionProcess(executableURL: executableURL)
          launchedPort = port
          return port
        }
      #endif

      throw BrainTransportError.bootstrapUnavailable(
        "no affective_session_start boot shim is linked and no affective-core-session executable was found. Build/bundle the BSP session target or set AFFECTIVE_BSP_PORT for an already-running service."
      )
    }

    func stop() {
      launchedProcess?.terminate()
      launchedProcess = nil
      launchedPort = nil

      #if canImport(Darwin)
        if inProcessPort != nil, let stop = Self.lookupStopShim() {
          stop()
        }
      #endif
      inProcessPort = nil
    }

    private func startInProcessSession(config: BrainSessionConfig) throws -> UInt16? {
      #if canImport(Darwin)
        guard let start = Self.lookupStartShim() else {
          return nil
        }
        let configData = try config.createMessage.encodedData()
        guard let configJSON = String(data: configData, encoding: .utf8) else {
          throw BrainTransportError.bootstrapFailed("could not encode BSP session config as UTF-8 JSON")
        }
        let rawPort = configJSON.withCString { pointer in
          start(pointer)
        }
        guard rawPort > 0, rawPort <= Int32(UInt16.max) else {
          throw BrainTransportError.bootstrapFailed("affective_session_start returned invalid port \(rawPort)")
        }
        return UInt16(rawPort)
      #else
        return nil
      #endif
    }

    #if os(macOS)
      private func launchSessionProcess(executableURL: URL) async throws -> UInt16 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--port", "0"]
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
          try process.run()
        } catch {
          throw BrainTransportError.bootstrapFailed("could not launch \(executableURL.path): \(error.localizedDescription)")
        }

        launchedProcess = process
        do {
          let port = try await Self.readAdvertisedPort(from: outputPipe, process: process)
          Self.logger.info("Launched BSP session service on port \(port, privacy: .public)")
          return port
        } catch {
          process.terminate()
          launchedProcess = nil
          throw error
        }
      }

      private static func readAdvertisedPort(from pipe: Pipe, process: Process) async throws -> UInt16 {
        final class PortReadBox: @unchecked Sendable {
          private let lock = NSLock()
          private var didResume = false
          private var output = ""

          func append(_ string: String) -> UInt16? {
            lock.lock()
            defer { lock.unlock() }
            output.append(string)
            return BrainSessionServiceBootstrap.parseAdvertisedPort(from: output)
          }

          func resume(
            _ continuation: CheckedContinuation<UInt16, Error>,
            with result: Result<UInt16, Error>,
            pipe: Pipe
          ) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(with: result)
          }
        }

        return try await withCheckedThrowingContinuation { continuation in
          let box = PortReadBox()
          pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
              if !process.isRunning {
                box.resume(
                  continuation,
                  with: .failure(BrainTransportError.bootstrapFailed("session service exited before advertising a port")),
                  pipe: pipe
                )
              }
              return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            if let port = box.append(chunk) {
              box.resume(continuation, with: .success(port), pipe: pipe)
            }
          }

          DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            box.resume(
              continuation,
              with: .failure(BrainTransportError.bootstrapFailed("session service did not advertise a port within 5 seconds")),
              pipe: pipe
            )
          }
        }
      }

      private static func parseAdvertisedPort(from output: String) -> UInt16? {
        let pattern = #"(?i)(?:\bport\b|AFFECTIVE_BSP_PORT|bsp_port)\D+(\d{1,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges > 1,
              let portRange = Range(match.range(at: 1), in: output),
              let port = UInt16(output[portRange]),
              port > 0
        else {
          return nil
        }
        return port
      }

      private static func sessionExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AFFECTIVE_BSP_EXECUTABLE"], !path.isEmpty {
          let url = URL(fileURLWithPath: path)
          return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for name in ["affective-core-session", "affective-core-sessiond"] {
          if let url = Bundle.main.url(forResource: name, withExtension: nil),
             FileManager.default.isExecutableFile(atPath: url.path)
          {
            return url
          }
        }
        if environment["AFFECTIVE_USE_DEV_BSP_EXECUTABLE"] == "1" {
          let devURL = URL(fileURLWithPath: "/Users/zelda/Documents/AffectiveCore/zig-out/bin/affective-core-session")
          if FileManager.default.isExecutableFile(atPath: devURL.path) {
            return devURL
          }
        }
        return nil
      }
    #endif

    private static func environmentPort() -> UInt16? {
      guard let raw = ProcessInfo.processInfo.environment["AFFECTIVE_BSP_PORT"],
            let value = UInt16(raw),
            value > 0
      else {
        return nil
      }
      return value
    }

    #if canImport(Darwin)
      private typealias StartShim = @convention(c) (UnsafePointer<CChar>) -> Int32
      private typealias StopShim = @convention(c) () -> Void

      private static func lookupStartShim() -> StartShim? {
        lookupSymbol("affective_session_start", as: StartShim.self)
      }

      private static func lookupStopShim() -> StopShim? {
        lookupSymbol("affective_session_stop", as: StopShim.self)
      }

      private static func lookupSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, name)
        else {
          return nil
        }
        return unsafeBitCast(symbol, to: type)
      }
    #endif
  }
#endif
