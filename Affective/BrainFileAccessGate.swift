//
//  BrainFileAccessGate.swift
//  Affective
//

import Foundation
import os

enum BrainFileAccessError: Error, LocalizedError, Equatable {
    case liveSessionActive(brainID: String)
    case duplicateLiveSession(brainID: String)

    var errorDescription: String? {
        switch self {
        case .liveSessionActive(let brainID):
            return "Brain \(brainID) has an active live core session; direct SQLite access is not allowed."
        case .duplicateLiveSession(let brainID):
            return "Brain \(brainID) already has a live core session."
        }
    }
}

nonisolated final class BrainFileAccessGateState: Sendable {
    nonisolated static let shared = BrainFileAccessGateState()

    private struct LockedState {
        var liveSessions: Set<String> = []
        var liveSessionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var exclusiveArchiveHolders: Set<String> = []
        var exclusiveArchiveWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    nonisolated func acquireLiveSession(brainID: String) throws {
        try state.withLock { locked in
            guard !locked.liveSessions.contains(brainID) else {
                throw BrainFileAccessError.duplicateLiveSession(brainID: brainID)
            }
            locked.liveSessions.insert(brainID)
        }
    }

    nonisolated func releaseLiveSession(brainID: String) {
        let waiters = state.withLock { locked -> [CheckedContinuation<Void, Never>] in
            locked.liveSessions.remove(brainID)
            return locked.liveSessionWaiters.removeValue(forKey: brainID) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    nonisolated func assertNoLiveSession(brainID: String) throws {
        try state.withLock { locked in
            if locked.liveSessions.contains(brainID) {
                throw BrainFileAccessError.liveSessionActive(brainID: brainID)
            }
        }
    }

    nonisolated func hasLiveSession(brainID: String) -> Bool {
        state.withLock { locked in
            locked.liveSessions.contains(brainID)
        }
    }

    nonisolated func waitForNoLiveSession(brainID: String) async {
        while true {
            let shouldWait = state.withLock { locked in
                locked.liveSessions.contains(brainID)
            }
            if !shouldWait { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.withLock { locked in
                    if !locked.liveSessions.contains(brainID) {
                        continuation.resume()
                        return
                    }
                    locked.liveSessionWaiters[brainID, default: []].append(continuation)
                }
            }
        }
    }

    nonisolated func acquireExclusiveArchive(brainID: String) async {
        while true {
            let acquired = state.withLock { locked -> Bool in
                if locked.exclusiveArchiveHolders.contains(brainID) {
                    return false
                }
                locked.exclusiveArchiveHolders.insert(brainID)
                return true
            }
            if acquired { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.withLock { locked in
                    if !locked.exclusiveArchiveHolders.contains(brainID) {
                        locked.exclusiveArchiveHolders.insert(brainID)
                        continuation.resume()
                        return
                    }
                    locked.exclusiveArchiveWaiters[brainID, default: []].append(continuation)
                }
            }
        }
    }

    nonisolated func releaseExclusiveArchive(brainID: String) {
        let waiters = state.withLock { locked -> [CheckedContinuation<Void, Never>] in
            locked.exclusiveArchiveHolders.remove(brainID)
            return locked.exclusiveArchiveWaiters.removeValue(forKey: brainID) ?? []
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

nonisolated enum BrainFileAccessGate {
    nonisolated static func acquireLiveSession(brainID: String) throws {
        try BrainFileAccessGateState.shared.acquireLiveSession(brainID: brainID)
    }

    nonisolated static func releaseLiveSession(brainID: String) {
        BrainFileAccessGateState.shared.releaseLiveSession(brainID: brainID)
    }

    nonisolated static func assertNoLiveSession(brainID: String) throws {
        try BrainFileAccessGateState.shared.assertNoLiveSession(brainID: brainID)
    }

    nonisolated static func hasLiveSession(brainID: String) -> Bool {
        BrainFileAccessGateState.shared.hasLiveSession(brainID: brainID)
    }

    nonisolated static func runExclusive<T>(brainID: String, _ operation: () async throws -> T) async rethrows -> T {
        await BrainFileAccessGateState.shared.waitForNoLiveSession(brainID: brainID)
        await BrainFileAccessGateState.shared.acquireExclusiveArchive(brainID: brainID)
        defer { BrainFileAccessGateState.shared.releaseExclusiveArchive(brainID: brainID) }
        return try await operation()
    }
}
