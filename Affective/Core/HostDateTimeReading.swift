//
//  HostDateTimeReading.swift
//  Affective
//

import Foundation

nonisolated struct HostDateTimeReading: Equatable, Sendable {
  static let iso8601LocalFormat = "ISO-8601 local"
  static let friendlyFormat = "local long date and time"

  let datetime: String
  let datetimeFormat: String
  let friendlyDatetime: String
  let friendlyDatetimeFormat: String
  let unixSeconds: Int64

  static func now(_ date: Date = Date()) -> HostDateTimeReading {
    HostDateTimeReading(
      datetime: iso8601LocalFormatter.string(from: date),
      datetimeFormat: iso8601LocalFormat,
      friendlyDatetime: friendlyFormatter.string(from: date),
      friendlyDatetimeFormat: friendlyFormat,
      unixSeconds: Int64(date.timeIntervalSince1970.rounded(.down))
    )
  }

  var observationLines: String {
    """
    time:
    - datetime: \(datetime) (\(datetimeFormat))
    - friendly: \(friendlyDatetime) (\(friendlyDatetimeFormat))
    """
  }

  private static let iso8601LocalFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
    return formatter
  }()

  private static let friendlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeZone = .current
    formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
    return formatter
  }()
}
