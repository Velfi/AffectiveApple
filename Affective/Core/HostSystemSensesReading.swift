//
//  HostSystemSensesReading.swift
//  Affective
//

import Foundation
#if canImport(UIKit)
  import UIKit
#endif
#if canImport(IOKit)
  import IOKit.ps
#endif

enum HostSystemSenseError: Error {
  case powerSourcesUnavailable
  case storageVolumeUnavailable(String)
}

nonisolated struct HostPowerSupply: Encodable, Equatable, Sendable {
  let name: String
  let kind: String
  let capacityPercent: Int?
  let status: String?
  let online: Bool?

  enum CodingKeys: String, CodingKey {
    case name
    case kind
    case capacityPercent = "capacity_percent"
    case status
    case online
  }
}

nonisolated struct HostPowerSnapshot: Encodable, Equatable, Sendable {
  let supplies: [HostPowerSupply]
}

nonisolated struct HostStorageVolume: Encodable, Equatable, Sendable {
  let name: String
  let mountPath: String
  let totalBytes: Int64
  let availableBytes: Int64
  let usedPercent: Int

  enum CodingKeys: String, CodingKey {
    case name
    case mountPath = "mount_path"
    case totalBytes = "total_bytes"
    case availableBytes = "available_bytes"
    case usedPercent = "used_percent"
  }
}

nonisolated struct HostStorageSnapshot: Encodable, Equatable, Sendable {
  let volumes: [HostStorageVolume]
}

nonisolated enum HostSystemSensesReading {
  #if os(iOS)
    static let defaultStorageMountPath = NSHomeDirectory()
  #else
    static let defaultStorageMountPath = "/"
  #endif

  static func powerSnapshot() throws -> HostPowerSnapshot {
    #if os(iOS)
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          iosPowerSnapshot()
        }
      }
    #elseif canImport(IOKit)
      return try macPowerSnapshot()
    #else
      return HostPowerSnapshot(supplies: [])
    #endif
  }

  #if os(iOS)
    @MainActor private static func iosPowerSnapshot() -> HostPowerSnapshot {
      UIDevice.current.isBatteryMonitoringEnabled = true
      defer { UIDevice.current.isBatteryMonitoringEnabled = false }

      let level = UIDevice.current.batteryLevel
      let capacityPercent: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
      let status: String = {
        switch UIDevice.current.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "discharging"
        default: "unknown"
        }
      }()
      let externalOnline = UIDevice.current.batteryState == .charging
        || UIDevice.current.batteryState == .full

      return HostPowerSnapshot(
        supplies: [
          HostPowerSupply(
            name: "InternalBattery",
            kind: "Battery",
            capacityPercent: capacityPercent,
            status: status,
            online: nil
          ),
          HostPowerSupply(
            name: "External",
            kind: "Mains",
            capacityPercent: nil,
            status: nil,
            online: externalOnline
          ),
        ])
    }
  #endif

  #if canImport(IOKit) && !os(iOS)
    private static func macPowerSnapshot() throws -> HostPowerSnapshot {
      guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
        throw HostSystemSenseError.powerSourcesUnavailable
      }
      guard let sourceList = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        throw HostSystemSenseError.powerSourcesUnavailable
      }

      var supplies: [HostPowerSupply] = []
      var externalOnline = false

      for source in sourceList {
        // takeUnretainedValue: caller does not release IOPSGetPowerSourceDescription results.
        guard
          let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
            as? [String: Any]
        else {
          continue
        }

        let powerSourceState = description[kIOPSPowerSourceStateKey as String] as? String
        if powerSourceState == (kIOPSACPowerValue as String) {
          externalOnline = true
        }

        let type = description[kIOPSTypeKey as String] as? String ?? ""
        let isInternalBattery = type == (kIOPSInternalBatteryType as String)
          || type.localizedCaseInsensitiveContains("battery")
        guard isInternalBattery else {
          continue
        }

        let name = description[kIOPSNameKey as String] as? String ?? "InternalBattery"
        let capacity = description[kIOPSCurrentCapacityKey as String] as? Int
        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let status: String
        if isCharging {
          status = "charging"
        } else if powerSourceState == (kIOPSACPowerValue as String) {
          status = "AC attached"
        } else {
          status = "discharging"
        }

        supplies.append(
          HostPowerSupply(
            name: name,
            kind: "Battery",
            capacityPercent: capacity,
            status: status,
            online: nil
          ))
      }

      if supplies.isEmpty {
        return HostPowerSnapshot(supplies: [])
      }

      supplies.append(
        HostPowerSupply(
          name: "AC",
          kind: "Mains",
          capacityPercent: nil,
          status: nil,
          online: externalOnline
        ))

      return HostPowerSnapshot(supplies: supplies)
    }
  #endif

  static func storageSnapshot(mountPath: String = defaultStorageMountPath) throws -> HostStorageSnapshot {
    let url = URL(fileURLWithPath: mountPath, isDirectory: true)
    let values = try url.resourceValues(forKeys: [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeLocalizedNameKey,
    ])

    guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage else {
      throw HostSystemSenseError.storageVolumeUnavailable(mountPath)
    }

    let totalBytes = Int64(total)
    let availableBytes = Int64(available)
    let used = max(Int64(0), totalBytes - availableBytes)
    let usedPercent = totalBytes > 0 ? Int((used * 100) / totalBytes) : 0
    let name = values.volumeLocalizedName ?? mountPath

    return HostStorageSnapshot(
      volumes: [
        HostStorageVolume(
          name: name,
          mountPath: mountPath,
          totalBytes: totalBytes,
          availableBytes: availableBytes,
          usedPercent: usedPercent
        )
      ])
  }

  static func encodedPowerSnapshot() throws -> Data {
    try JSONEncoder().encode(try powerSnapshot())
  }

  static func encodedStorageSnapshot() throws -> Data {
    try JSONEncoder().encode(try storageSnapshot())
  }
}
