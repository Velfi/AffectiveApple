//
//  SemanticEntities.swift
//  Affective
//

import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

nonisolated enum AffectiveSemanticSchema {
    static let brainDomainIdentifier = "com.zelda-built-this.AMBI.brain"
    static let conversationDomainIdentifier = "com.zelda-built-this.AMBI.conversation-entry"

    static func brainIdentifier(_ brainID: String) -> String {
        "affective-brain:\(brainID)"
    }

    static func conversationIdentifier(entryID: UUID, brainID: String) -> String {
        "affective-conversation-entry:\(brainID):\(entryID.uuidString)"
    }

    static func uniqueKeywords(_ values: [String], limit: Int = 20) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
nonisolated struct AffectiveBrainEntity: IndexedEntity, Identifiable, Equatable, Sendable {
    typealias DefaultQuery = AffectiveBrainEntityQuery

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Brain")
    static let defaultQuery = AffectiveBrainEntityQuery()

    let id: String
    let name: String
    let rootPath: String
    let modifiedAt: Date?
    let isRecent: Bool
    let avatarPath: String?

    init(
        id: String,
        name: String,
        rootPath: String,
        modifiedAt: Date?,
        isRecent: Bool,
        avatarPath: String?
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.modifiedAt = modifiedAt
        self.isRecent = isRecent
        self.avatarPath = avatarPath
    }

    init(brain: BrainDescriptor) {
        self.init(
            id: brain.id,
            name: brain.displayName,
            rootPath: brain.rootURL.path,
            modifiedAt: brain.modifiedAt,
            isRecent: brain.isRecent,
            avatarPath: brain.avatarURL?.path
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: isRecent ? "Recent Affective brain" : "Affective brain",
            synonyms: [LocalizedStringResource(stringLiteral: id)]
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(itemContentType: UTType.data.identifier)
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = "Affective brain named \(name)."
        attributes.identifier = AffectiveSemanticSchema.brainIdentifier(id)
        attributes.relatedUniqueIdentifier = id
        attributes.domainIdentifier = AffectiveSemanticSchema.brainDomainIdentifier
        attributes.keywords = ["Affective", "brain", name, id]
        attributes.contentModificationDate = modifiedAt
        if let avatarPath {
            attributes.thumbnailURL = URL(fileURLWithPath: avatarPath)
        }
        return attributes
    }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
nonisolated struct AffectiveBrainEntityQuery: EntityStringQuery, EnumerableEntityQuery, Sendable {
    init() {}

    func entities(for identifiers: [AffectiveBrainEntity.ID]) async throws -> [AffectiveBrainEntity] {
        let requested = Set(identifiers)
        return await Self.currentEntities().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AffectiveBrainEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return await Self.currentEntities()
        }
        return await Self.currentEntities().filter { entity in
            entity.name.localizedCaseInsensitiveContains(query)
                || entity.id.localizedCaseInsensitiveContains(query)
                || entity.rootPath.localizedCaseInsensitiveContains(query)
        }
    }

    func allEntities() async throws -> [AffectiveBrainEntity] {
        await Self.currentEntities()
    }

    @MainActor
    private static func currentEntities() -> [AffectiveBrainEntity] {
        BrainLibrary().recencySortedBrains.map(AffectiveBrainEntity.init(brain:))
    }
}

@available(macOS 15.0, iOS 18.0, visionOS 2.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
nonisolated struct AffectiveConversationEntryEntity: Identifiable, Equatable, Sendable {
    // Conversation entries are currently in-memory UI log items. Keep this as
    // Spotlight metadata until a persisted transcript contract can resolve IDs.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation Entry")

    let id: UUID
    let brainID: String
    let kind: String
    let title: String
    let body: String
    let createdAt: Date
    let metadata: [String: String]

    init(
        id: UUID,
        brainID: String,
        kind: String,
        title: String,
        body: String,
        createdAt: Date,
        metadata: [String: String]
    ) {
        self.id = id
        self.brainID = brainID
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.metadata = metadata
    }

    init(entry: LogEntry, brainID: String) {
        self.init(
            id: entry.id,
            brainID: brainID,
            kind: entry.kind.rawValue,
            title: entry.title,
            body: entry.body,
            createdAt: entry.createdAt,
            metadata: entry.metadata
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind.capitalized) in \(brainID)",
            synonyms: [LocalizedStringResource(stringLiteral: brainID)]
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(itemContentType: UTType.text.identifier)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = body
        attributes.identifier = AffectiveSemanticSchema.conversationIdentifier(entryID: id, brainID: brainID)
        attributes.relatedUniqueIdentifier = AffectiveSemanticSchema.brainIdentifier(brainID)
        attributes.domainIdentifier = AffectiveSemanticSchema.conversationDomainIdentifier
        attributes.contentCreationDate = createdAt
        attributes.contentModificationDate = createdAt
        attributes.keywords = conversationKeywords
        return attributes
    }

    var conversationKeywords: [String] {
        AffectiveSemanticSchema.uniqueKeywords(
            ["Affective", "conversation", "chat", brainID, kind, title] + metadata.values
        )
    }
}
