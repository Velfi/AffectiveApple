//
//  BrainCoreEventSink.swift
//  Affective
//

import Foundation

/// Receives pushed host events from the core via BSP `events.push` frames.
nonisolated final class BrainCoreEventSink: @unchecked Sendable {
  typealias Handler = @Sendable ([BrainEvent]) -> Void

  private let lock = NSLock()
  private var handler: Handler?

  func setHandler(_ handler: Handler?) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  func ingest(eventsJSON: String) {
    guard !eventsJSON.isEmpty else { return }
    let data = Data(eventsJSON.utf8)
    let events: [BrainEvent]
    do {
      events = try BrainCoreEventSink.decodeEvents(from: data)
    } catch {
      return
    }
    guard !events.isEmpty else { return }
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(events)
  }

  private static func decodeEvents(from data: Data) throws -> [BrainEvent] {
    let decoder = JSONDecoder()
    var container = try decoder.decode(UnkeyedDecodingContainerBox.self, from: data).container
    var events: [BrainEvent] = []
    while !container.isAtEnd {
      if let event = try? container.decode(BrainEvent.self) {
        events.append(event)
      } else {
        _ = try? container.decode(IgnoredHostEvent.self)
      }
    }
    return events
  }

  private struct UnkeyedDecodingContainerBox: Decodable {
    let container: UnkeyedDecodingContainer

    init(from decoder: Decoder) throws {
      container = try decoder.unkeyedContainer()
    }
  }

  private struct IgnoredHostEvent: Decodable {}
}
