//
//  AppForegroundMonitor.swift
//  Affective
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum AppForegroundMonitor {
    #if os(macOS)
    static var macAppIsActive: Bool {
        NSApplication.shared.isActive
    }

    static func installMacActiveStateHandler(_ handler: @escaping (Bool) -> Void) -> [any NSObjectProtocol] {
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler(true)
        }
        let inactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler(false)
        }
        let observers: [any NSObjectProtocol] = [activeObserver, inactiveObserver]
        return observers
    }

    static func isForeground(scenePhaseActive: Bool) -> Bool {
        scenePhaseActive && macAppIsActive
    }
    #else
    static func isForeground(scenePhaseActive: Bool) -> Bool {
        scenePhaseActive
    }
    #endif
}
