//
//  CoreLoadPerformance.swift
//  Affective
//

import Foundation
import os

struct CoreLoadPhaseMetric: Sendable, Equatable {
  let id: String
  let label: String
  let durationMs: Int
}

struct CoreLoadMetricsReport: Sendable, Equatable {
  let phases: [CoreLoadPhaseMetric]
  let totalMs: Int

  nonisolated var summaryText: String {
    var lines = ["Core load \(totalMs)ms total"]
    for phase in phases {
      lines.append("  \(phase.label) \(phase.durationMs)ms")
    }
    return lines.joined(separator: "\n")
  }

  nonisolated var eventLogBody: String {
    phases.map { "\($0.label): \($0.durationMs)ms" }.joined(separator: ", ")
      + " (total \(totalMs)ms)"
  }
}

final class CoreLoadPerformanceSession: @unchecked Sendable {
  typealias ProgressHandler = @Sendable @MainActor (_ label: String, _ detail: String?) -> Void

  nonisolated private static let logger = Logger(
    subsystem: "com.zelda-built-this.AMBI",
    category: "core-load-performance"
  )

  private let lock = NSLock()
  nonisolated(unsafe) private var phases: [CoreLoadPhaseMetric] = []
  nonisolated(unsafe) private var activeStarts: [String: ContinuousClock.Instant] = [:]
  private let onProgress: ProgressHandler?
  private let startedAt: ContinuousClock.Instant

  nonisolated init(onProgress: ProgressHandler? = nil) {
    self.onProgress = onProgress
    self.startedAt = ContinuousClock.now
  }

  nonisolated func begin(id: String, label: String, detail: String? = nil) {
    lock.lock()
    activeStarts[id] = ContinuousClock.now
    lock.unlock()
    emit(label: label, detail: detail)
    logConsolePhase(event: "begin", id: id, label: label, detail: detail, durationMs: nil)
    Self.logger.info("Core load begin id=\(id, privacy: .public) label=\(label, privacy: .public)")
  }

  nonisolated func end(id: String, label: String) {
    let durationMs: Int
    lock.lock()
    let start = activeStarts.removeValue(forKey: id) ?? startedAt
    durationMs = Self.milliseconds(from: start.duration(to: ContinuousClock.now))
    phases.append(.init(id: id, label: label, durationMs: durationMs))
    lock.unlock()
    logConsolePhase(event: "end", id: id, label: label, detail: nil, durationMs: durationMs)
    Self.logger.info(
      "Core load end id=\(id, privacy: .public) label=\(label, privacy: .public) durationMs=\(durationMs, privacy: .public)"
    )
  }

  nonisolated func measureSync<T>(
    id: String,
    label: String,
    detail: String? = nil,
    _ body: () throws -> T
  ) rethrows -> T {
    begin(id: id, label: label, detail: detail)
    defer { end(id: id, label: label) }
    return try body()
  }

  nonisolated func measure<T>(
    id: String,
    label: String,
    detail: String? = nil,
    _ body: () async throws -> T
  ) async rethrows -> T {
    begin(id: id, label: label, detail: detail)
    defer { end(id: id, label: label) }
    return try await body()
  }

  nonisolated func report() -> CoreLoadMetricsReport {
    lock.lock()
    defer { lock.unlock() }
    let totalMs = Self.milliseconds(from: startedAt.duration(to: ContinuousClock.now))
    return CoreLoadMetricsReport(phases: phases, totalMs: totalMs)
  }

  nonisolated func ingestDispatchTimings(from response: BrainToolResponse) {
    guard let envelope = try? BrainDispatchEnvelope.decode(from: response.rawText) else { return }
    ingestDispatchTimings(from: envelope)
  }

  nonisolated func ingestDispatchTimings(from envelope: BrainDispatchEnvelope) {
    var ingestedSpanIDs = Set<String>()
    if let timings = envelope.timings?.objectValue,
       let spans = timings["spans"]?.arrayValue {
      for entry in spans {
        guard
          let object = entry.objectValue,
          let spanID = object["span_id"]?.stringValue,
          let label = object["label"]?.stringValue,
          let durationMs = Self.milliseconds(from: object["duration_ms"])
        else {
          continue
        }
        ingestedSpanIDs.insert(spanID)
        var detailParts: [String] = []
        if let kind = object["kind"]?.stringValue {
          detailParts.append(kind)
        }
        if let processID = object["process_id"]?.stringValue {
          detailParts.append("process=\(processID)")
        }
        if let actionID = object["action_id"]?.stringValue {
          detailParts.append("action=\(actionID)")
        }
        if let llmCallID = object["llm_call_id"]?.stringValue {
          detailParts.append("llm=\(llmCallID)")
        }
        if let operationID = object["operation_id"]?.stringValue {
          detailParts.append("operation=\(operationID)")
        }
        recordCompletedPhase(
          id: spanID,
          label: label,
          durationMs: durationMs,
          detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " ")
        )
      }
    }
    ingestHostCapabilityManifestTimings(from: envelope, excludingSpanIDs: ingestedSpanIDs)
  }

  nonisolated func ingestHostCapabilityManifestTimings(from response: BrainToolResponse) {
    guard let envelope = try? BrainDispatchEnvelope.decode(from: response.rawText) else { return }
    ingestHostCapabilityManifestTimings(from: envelope)
  }

  nonisolated func ingestHostCapabilityManifestTimings(from envelope: BrainDispatchEnvelope) {
    ingestHostCapabilityManifestTimings(from: envelope, excludingSpanIDs: [])
  }

  nonisolated func ingestHostCapabilityManifestTimings(
    from envelope: BrainDispatchEnvelope,
    excludingSpanIDs: Set<String>
  ) {
    guard let value = envelope.result?.objectValue?["value"]?.objectValue else { return }
    guard let timings = value["manifest_timings"]?.arrayValue else { return }
    for entry in timings {
      guard
        let object = entry.objectValue,
        let capabilityID = object["capability_id"]?.stringValue,
        let durationMs = Self.milliseconds(from: object["duration_ms"])
      else {
        continue
      }
      let spanID = object["span_id"]?.stringValue ?? "host_capability_manifest.\(capabilityID)"
      if excludingSpanIDs.contains(spanID) {
        continue
      }
      recordCompletedPhase(
        id: spanID,
        label: "Publishing host capability: \(capabilityID)",
        durationMs: durationMs,
        detail: capabilityID
      )
    }
  }

  nonisolated func recordCompletedPhase(
    id: String,
    label: String,
    durationMs: Int,
    detail: String? = nil
  ) {
    lock.lock()
    phases.append(.init(id: id, label: label, durationMs: durationMs))
    lock.unlock()
    logConsolePhase(event: "manifest", id: id, label: label, detail: detail, durationMs: durationMs)
    Self.logger.info(
      "Core load manifest id=\(id, privacy: .public) label=\(label, privacy: .public) durationMs=\(durationMs, privacy: .public)"
    )
  }

  nonisolated func logReportToConsole(outcome: String, brainID: String? = nil, error: String? = nil) {
    let report = report()
    var headline = outcome
    if let brainID, !brainID.isEmpty {
      headline += " brain=\(brainID)"
    }
    headline += " total=\(report.totalMs)ms"
    if let error, !error.isEmpty {
      headline += " error=\(error)"
    }
    Self.writeConsole(headline)
    for phase in report.phases {
      Self.writeConsole("  \(phase.label): \(phase.durationMs)ms")
    }
    Self.logger.info("Core load \(outcome, privacy: .public) totalMs=\(report.totalMs, privacy: .public)")
  }

  nonisolated static func writeStartupToConsole(brainID: String) {
    writeConsole("startup brain=\(brainID)")
  }

  nonisolated private func logConsolePhase(
    event: String,
    id: String,
    label: String,
    detail: String?,
    durationMs: Int?
  ) {
    var message = "\(event) \(label)"
    if let detail, !detail.isEmpty {
      message += " (\(detail))"
    }
    if let durationMs {
      message += " \(durationMs)ms"
    }
    message += " [\(id)]"
    Self.writeConsole(message)
  }

  nonisolated private static func writeConsole(_ message: String) {
    fputs("[core-load] \(message)\n", stderr)
  }

  nonisolated private func emit(label: String, detail: String?) {
    guard let onProgress else { return }
    Task { @MainActor in
      onProgress(label, detail)
    }
  }

  nonisolated private static func milliseconds(from duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }

  nonisolated private static func milliseconds(from value: JSONValue?) -> Int? {
    guard let value else { return nil }
    if case .number(let number) = value {
      return Int(number.rounded())
    }
    return nil
  }
}
