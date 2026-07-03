//
//  BrainCoreMessageBus.swift
//  Affective
//

import Foundation

nonisolated enum BrainCoreDispatchMode: String, Sendable {
  case concurrent
  case parallel

  static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
    guard let raw = environment["AFFECTIVE_BSP_DISPATCH_MODE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !raw.isEmpty
    else {
      return .concurrent
    }
    switch raw {
    case "serial", "single", "single_lane", "single-lane":
      return .concurrent
    case "parallel":
      return .parallel
    case "concurrent", "queueable", "multiplexed":
      return .concurrent
    default:
      return .concurrent
    }
  }

  var allowsParallelQueueableDispatch: Bool {
    switch self {
    case .concurrent:
      return false
    case .parallel:
      return true
    }
  }
}

/// Host-side routing for core dispatches. Queueable input/status dispatches are always coalesced
/// by operation key. In concurrent mode, the BSP session keeps one active dispatch. In parallel
/// mode, different queueable keys may overlap the command lane for hosts that support multiplexed
/// dispatch, while repeated updates for the same key still collapse to the latest pending update.
actor BrainCoreMessageBus {
  private struct CoalescedQueueableDispatch {
    var operation: @Sendable () async throws -> BrainDispatchEnvelope
    var continuations: [CheckedContinuation<BrainDispatchEnvelope, Error>]
  }

  private let mode: BrainCoreDispatchMode
  private var isDispatchRunning = false
  private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
  private var coalescedQueueableDispatches: [String: CoalescedQueueableDispatch] = [:]
  private var coalescedQueueableOrder: [String] = []
  private var activeParallelQueueableKeys: Set<String> = []

  init(mode: BrainCoreDispatchMode = .fromEnvironment()) {
    self.mode = mode
  }

  func submitQueueable(
    key: String,
    _ operation: @Sendable @escaping () async throws -> BrainDispatchEnvelope
  )
    async throws -> BrainDispatchEnvelope
  {
    if mode.allowsParallelQueueableDispatch {
      return try await submitParallelQueueable(key: key, operation)
    } else {
      return try await submitConcurrentQueueable(key: key, operation)
    }
  }

  func submitSerial<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T)
    async throws -> T
  {
    await acquireDispatchLane()
    defer { releaseDispatchLane() }
    return try await operation()
  }

  private func acquireDispatchLane() async {
    if !isDispatchRunning {
      isDispatchRunning = true
      return
    }
    await withCheckedContinuation { continuation in
      dispatchWaiters.append(continuation)
    }
  }

  private func releaseDispatchLane() {
    if let key = coalescedQueueableOrder.first,
       let dispatch = coalescedQueueableDispatches.removeValue(forKey: key)
    {
      coalescedQueueableOrder.removeFirst()
      Task {
        await self.runCoalescedQueueable(dispatch)
      }
      return
    }
    if dispatchWaiters.isEmpty {
      isDispatchRunning = false
      return
    }
    dispatchWaiters.removeFirst().resume()
  }

  private func submitConcurrentQueueable(
    key: String,
    _ operation: @Sendable @escaping () async throws -> BrainDispatchEnvelope
  ) async throws -> BrainDispatchEnvelope {
    if !isDispatchRunning, dispatchWaiters.isEmpty, coalescedQueueableOrder.isEmpty {
      return try await submitSerial(operation)
    }
    return try await coalesceQueueable(key: key, operation)
  }

  private func runCoalescedQueueable(_ dispatch: CoalescedQueueableDispatch) async {
    do {
      let envelope = try await dispatch.operation()
      for continuation in dispatch.continuations {
        continuation.resume(returning: envelope)
      }
    } catch {
      for continuation in dispatch.continuations {
        continuation.resume(throwing: error)
      }
    }
    releaseDispatchLane()
  }

  private func submitParallelQueueable(
    key: String,
    _ operation: @Sendable @escaping () async throws -> BrainDispatchEnvelope
  ) async throws -> BrainDispatchEnvelope {
    if !activeParallelQueueableKeys.contains(key) {
      activeParallelQueueableKeys.insert(key)
      return try await runParallelQueueable(key: key, operation: operation)
    }
    return try await coalesceQueueable(key: key, operation)
  }

  private func runParallelQueueable(
    key: String,
    operation: @Sendable () async throws -> BrainDispatchEnvelope
  ) async throws -> BrainDispatchEnvelope {
    do {
      let envelope = try await operation()
      await finishParallelQueueable(key: key)
      return envelope
    } catch {
      await finishParallelQueueable(key: key)
      throw error
    }
  }

  private func finishParallelQueueable(key: String) async {
    if let dispatch = coalescedQueueableDispatches.removeValue(forKey: key) {
      coalescedQueueableOrder.removeAll { $0 == key }
      Task {
        await self.runCoalescedParallelQueueable(key: key, dispatch: dispatch)
      }
      return
    }
    activeParallelQueueableKeys.remove(key)
  }

  private func runCoalescedParallelQueueable(key: String, dispatch: CoalescedQueueableDispatch) async {
    do {
      let envelope = try await dispatch.operation()
      for continuation in dispatch.continuations {
        continuation.resume(returning: envelope)
      }
    } catch {
      for continuation in dispatch.continuations {
        continuation.resume(throwing: error)
      }
    }
    await finishParallelQueueable(key: key)
  }

  private func coalesceQueueable(
    key: String,
    _ operation: @Sendable @escaping () async throws -> BrainDispatchEnvelope
  ) async throws -> BrainDispatchEnvelope {
    try await withCheckedThrowingContinuation { continuation in
      if var dispatch = coalescedQueueableDispatches[key] {
        dispatch.operation = operation
        dispatch.continuations.append(continuation)
        coalescedQueueableDispatches[key] = dispatch
      } else {
        coalescedQueueableDispatches[key] = CoalescedQueueableDispatch(
          operation: operation,
          continuations: [continuation]
        )
        coalescedQueueableOrder.append(key)
      }
    }
  }
}
