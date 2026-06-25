//
//  Split from BrainLibrary.swift
//  Affective
//

import Foundation

struct BrainDescriptor: Identifiable, Equatable {
    let id: String
    let displayName: String
    let rootURL: URL
    let avatarURL: URL?
    let avatarManifest: BrainAvatarManifest?
    let modifiedAt: Date?
    let isRecent: Bool

    nonisolated var memoryDatabaseURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("people.sqlite")
    }

    nonisolated var graphDatabaseURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("relationships.sqlite")
    }

    nonisolated var eventsURL: URL {
        rootURL.appendingPathComponent("events.jsonl")
    }

    nonisolated var scheduleURL: URL {
        rootURL.appendingPathComponent("maintenance.md")
    }

    nonisolated var maintenanceStateURL: URL {
        rootURL.appendingPathComponent("maintenance_state.json")
    }

    nonisolated var runtimeOptionsURL: URL {
        rootURL.appendingPathComponent("runtime_options.json")
    }

    nonisolated var statsJournalURL: URL {
        rootURL.appendingPathComponent("brain_stats.json")
    }

    nonisolated var dreamReportsURL: URL {
        rootURL.appendingPathComponent("dream_reports.json")
    }

    nonisolated var faceEmbeddingsURL: URL {
        rootURL.appendingPathComponent("memory", isDirectory: true).appendingPathComponent("face_embeddings", isDirectory: true)
    }

    nonisolated func validateForCoreConnection(fileManager: FileManager = .default) throws {
        try Self.requireDirectory(rootURL, relativePath: rootURL.lastPathComponent, fileManager: fileManager)
        try Self.requireFile(rootURL.appendingPathComponent("brain_profile.json"), relativePath: "brain_profile.json", fileManager: fileManager)
        try Self.requireFile(eventsURL, relativePath: "events.jsonl", fileManager: fileManager)
        try Self.requireFile(scheduleURL, relativePath: "maintenance.md", fileManager: fileManager)
        try Self.requireFile(runtimeOptionsURL, relativePath: "runtime_options.json", fileManager: fileManager)
        try Self.requireDirectory(rootURL.appendingPathComponent("memory", isDirectory: true), relativePath: "memory/", fileManager: fileManager)
        try Self.requireDirectory(faceEmbeddingsURL, relativePath: "memory/face_embeddings/", fileManager: fileManager)

        let profileObject = try Self.loadJSONObject(at: rootURL.appendingPathComponent("brain_profile.json"), relativePath: "brain_profile.json")
        guard !profileObject.isEmpty else {
            throw BrainValidationError.invalidJSON("brain_profile.json", detail: "expected a non-empty JSON object")
        }
        _ = try Self.loadJSONObject(at: runtimeOptionsURL, relativePath: "runtime_options.json", allowsEmptyFile: true)
        try Self.validateJSONLines(at: eventsURL, relativePath: "events.jsonl")
    }

    nonisolated static func requireFile(_ url: URL, relativePath: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BrainValidationError.missingFile(relativePath)
        }
    }

    nonisolated static func requireDirectory(_ url: URL, relativePath: String, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BrainValidationError.missingDirectory(relativePath)
        }
    }

    nonisolated static func loadJSONObject(
        at url: URL,
        relativePath: String,
        allowsEmptyFile: Bool = false
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if data.isEmpty, allowsEmptyFile {
            return [:]
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw BrainValidationError.invalidJSON(relativePath, detail: "expected a JSON object")
            }
            return dictionary
        } catch let error as BrainValidationError {
            throw error
        } catch {
            throw BrainValidationError.invalidJSON(relativePath, detail: error.localizedDescription)
        }
    }

    nonisolated static func validateJSONLines(at url: URL, relativePath: String) throws {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BrainValidationError.invalidJSON(relativePath, detail: "expected UTF-8 JSON Lines")
        }

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else {
                throw BrainValidationError.invalidJSON(relativePath, detail: "line \(index + 1) is not UTF-8")
            }
            do {
                _ = try JSONSerialization.jsonObject(with: lineData)
            } catch {
                throw BrainValidationError.invalidJSON(relativePath, detail: "line \(index + 1): \(error.localizedDescription)")
            }
        }
    }
}

enum BrainValidationError: Error, LocalizedError, Equatable {
    case missingFile(String)
    case missingDirectory(String)
    case invalidJSON(String, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            "This brain is incomplete. Missing required file: \(path)."
        case .missingDirectory(let path):
            "This brain is incomplete. Missing required folder: \(path)."
        case .invalidJSON(let path, let detail):
            "This brain contains invalid data in \(path): \(detail)."
        }
    }
}

struct BrainCreationRequest: Equatable {
    var name: String
    var wants: String
    var goals: String
    var initialThoughts: String
    var notes: String
}

@MainActor
extension String {
    var brainDisplayName: String {
        split(separator: "-")
            .flatMap { $0.split(separator: "_") }
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    var sanitizedBrainID: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let sanitized = String(map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return sanitized.isEmpty ? "imported-brain" : sanitized
    }

    var seedLines: [String] {
        components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
            }
            .filter { !$0.isEmpty }
    }

    var seedMarkdownList: String {
        let lines = seedLines
        guard !lines.isEmpty else { return "- None provided yet." }
        return lines.map { "- \($0)" }.joined(separator: "\n")
    }

    var seedParagraph: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "None provided yet." : trimmed
    }
}

extension Dictionary where Key == String, Value == Any {
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: self, options: [.prettyPrinted, .sortedKeys])
    }
}
