//
//  Split from ContentView.swift
//  Affective
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif

struct EventFilterBar: View {
    @ObservedObject var model: AffectiveViewModel
    @State private var didCopyLog = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                kindPicker
                sortPicker
                clearButton
                copyLogButton
            }

            VStack(alignment: .leading, spacing: 8) {
                searchField
                HStack(spacing: 10) {
                    kindPicker
                    sortPicker
                    clearButton
                    copyLogButton
                }
            }
        }
    }

    var searchField: some View {
        TextField("Search event log", text: $model.eventSearchText)
            .textFieldStyle(.plain)
            .optionFieldStyle(isDirty: !model.eventSearchText.isEmpty)
    }

    var kindPicker: some View {
        Picker("Kind", selection: $model.selectedEventKind) {
            Text("All").tag(LogKind?.none)
            Text("Process / reasoning").tag(LogKind?.some(.process))
            ForEach(LogKind.allCases.filter { $0 != .process }) { kind in
                Text(kind.rawValue.optionDisplayName).tag(LogKind?.some(kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(AppTheme.primaryText)
        .frame(width: 132)
        .optionFieldStyle(isDirty: model.selectedEventKind != nil)
    }

    var sortPicker: some View {
        Picker("Sort", selection: $model.developerEventSort) {
            ForEach(DeveloperEventSort.allCases) { sort in
                Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(AppTheme.primaryText)
        .frame(width: 116)
        .optionFieldStyle(isDirty: model.developerEventSort != .newestFirst)
        .help("Change event order")
    }

    @ViewBuilder
    var clearButton: some View {
        if model.selectedEventKind != nil || !model.eventSearchText.isEmpty {
            Button {
                model.eventSearchText = ""
                model.selectedEventKind = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 17, height: 17)
                    .hitTarget(34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryText)
            .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.separator)
            )
            .help("Clear event filters")
            .accessibilityLabel("Clear event filters")
        }
    }

    var copyLogButton: some View {
        Button {
            copyEntireLog()
        } label: {
            Label(didCopyLog ? "Copied" : "Copy log", systemImage: didCopyLog ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(minWidth: 104)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(didCopyLog ? AppTheme.accent : AppTheme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(didCopyLog ? AppTheme.accent.opacity(0.72) : .white.opacity(0.07))
        )
        .disabled(model.eventEntries.isEmpty)
        .opacity(model.eventEntries.isEmpty ? 0.55 : 1)
        .help("Copy the entire event log")
        .accessibilityLabel(didCopyLog ? "Copied event log" : "Copy entire event log")
    }

    func copyEntireLog() {
        let text = model.eventEntries.eventLogCopyText
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        didCopyLog = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopyLog = false
        }
    }
}

struct KnowledgeFilterBar: View {
    @ObservedObject var model: AffectiveViewModel
    var filteredCount: Int?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                countPill
            }

            VStack(alignment: .leading, spacing: 8) {
                searchField
                countPill
            }
        }
    }

    var searchField: some View {
        TextField("Search memory, reminders, dreams, attention", text: $model.knowledgeSearchText)
            .textFieldStyle(.plain)
            .optionFieldStyle(isDirty: !model.knowledgeSearchText.isEmpty)
    }

    var countPill: some View {
        let count = filteredCount ?? model.filteredKnowledgeEntries.count
        return CompactIconStatusPill(
            text: "\(count)",
            systemImage: "line.3.horizontal.decrease.circle"
        )
        .accessibilityLabel("\(count) filtered knowledge entries")
    }
}

struct LogHeader: View {
    let model: AffectiveViewModel
    var closeBrain: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Affective")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("Memory-Based Intelligence")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let closeBrain {
                    Button(action: closeBrain) {
                        Label("Projects", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Return to Projects")
                }

                Spacer(minLength: 0)

                CompactStatusPill(text: countText)
            }
        }
    }

    var countText: String {
        if model.selectedSection == .settings {
            return "runtime options"
        }
        let count = model.visibleEntryCount
        return "\(count) \(count == 1 ? "entry" : "entries")"
    }
}

struct LogEntryCardModel {
    struct Fact: Identifiable, Equatable {
        let key: String
        let value: String

        var id: String { "\(key)=\(value)" }
    }

    let entry: LogEntry
    let headline: String
    let badgeText: String
    let preview: String
    let primaryFacts: [Fact]
    let relatedFacts: [Fact]
    let detailFacts: [Fact]

    init(entry: LogEntry) {
        self.entry = entry
        badgeText = entry.kind.rawValue.uppercased()
        headline = Self.headline(for: entry)
        preview = Self.preview(for: entry)
        primaryFacts = Self.facts(for: entry, keys: Self.primaryFactKeys, limit: 5)
        relatedFacts = Self.facts(for: entry, keys: Self.relatedFactKeys, limit: nil)
        let promotedKeys = Set(Self.primaryFactKeys + Self.relatedFactKeys + Self.mediaFactKeys)
        detailFacts = entry.metadata
            .filter { key, value in
                !promotedKeys.contains(key) && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { Fact(key: $0.key, value: $0.value) }
    }

    var bodyText: String {
        let trimmed = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No payload body." : entry.body
    }

    var rowFactSummary: String {
        let facts = primaryFacts.prefix(3)
        guard !facts.isEmpty else { return entry.kind.rawValue.optionDisplayName }
        return facts.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")
    }

    var mediaFacts: [Fact] {
        Self.facts(for: entry, keys: Self.mediaFactKeys, limit: nil)
    }

    static let primaryFactKeys = [
        "event_type",
        "kind",
        "capability",
        "sense",
        "status",
        "presentation",
        "visibility",
        "role",
    ]

    static let relatedFactKeys = [
        "event_id",
        "request_id",
        "turn_id",
        "expression_id",
        "sense_id",
    ]

    static let mediaFactKeys = [
        "media_kind",
        "image_path",
        "image_url",
        "audio_path",
        "audio_url",
        "path",
        "url",
        "mime_type",
    ]

    static func headline(for entry: LogEntry) -> String {
        let eventType = entry.metadata["event_type"] ?? ""
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if eventType == "developer_log", title.hasPrefix("turn.") {
            let step = title.dropFirst("turn.".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: " ")
            return step.isEmpty ? "Turn process update" : "Turn: \(step.optionDisplayName)"
        }

        switch eventType {
        case "sense_request":
            let sense = entry.metadata["sense"] ?? entry.metadata["sense_id"]
            return sense.map { "\($0.optionDisplayName) sense requested" } ?? "Host sense requested"
        case "capability_request":
            let capability = entry.metadata["capability"] ?? title
            return "\(capability.optionDisplayName) requested"
        case "attention_state":
            return "Attention state updated"
        case "memory_mutation":
            return "Memory updated"
        case "memory_result":
            return "Memory result"
        case "expression":
            if let modality = entry.metadata["modality"], !modality.isEmpty {
                return "\(modality.optionDisplayName) expression emitted"
            }
            return "Expression emitted"
        case "control":
            return "Control state changed"
        case "mise_en_scene":
            return "Scene updated"
        case "error":
            return title.isEmpty ? "Core error" : title
        default:
            if !title.isEmpty {
                return title
            }
            if !eventType.isEmpty {
                return eventType.optionDisplayName
            }
            return entry.kind.rawValue.optionDisplayName
        }
    }

    static func preview(for entry: LogEntry) -> String {
        let body = entry.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            return body
        }

        for key in ["reason", "status", "capability", "sense", "request_id"] {
            if let value = entry.metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return "\(key)=\(value)"
            }
        }
        return "No payload preview."
    }

    static func facts(for entry: LogEntry, keys: [String], limit: Int?) -> [Fact] {
        var facts: [Fact] = []
        for key in keys {
            guard let value = entry.metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            facts.append(Fact(key: key, value: value))
            if let limit, facts.count >= limit {
                break
            }
        }
        return facts
    }
}

struct EntriesList: View {
    let entries: [LogEntry]
    let emptyTitle: String
    var brainRootURL: URL?
    var showsCopyButton = false
    var showsMessageLabels = true
    var showsMetadata = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        EmptyStateCard(title: emptyTitle, systemImage: "tray")
                            .padding(.top, 48)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(entries) { entry in
                            LogEntryView(
                                entry: entry,
                                brainRootURL: brainRootURL,
                                showsCopyButton: showsCopyButton,
                                showsMessageLabels: showsMessageLabels,
                                showsMetadata: showsMetadata
                            )
                                .id(entry.id)
                        }
                    }
                }
                .padding(horizontalSizeClass == .compact ? 14 : 24)
            }
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation(.smooth(duration: 0.25)) {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = entries.last {
                    reader.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct DeveloperConsoleList: View {
    let entries: [LogEntry]
    let emptyTitle: String
    var selectedEntryID: LogEntry.ID?
    var onSelect: (LogEntry) -> Void = { _ in }

    var body: some View {
        CompactActivityList(
            entries: entries,
            emptyTitle: emptyTitle,
            emptySystemImage: "terminal",
            selectedEntryID: selectedEntryID,
            onSelect: onSelect
        )
    }
}

struct CompactActivityList: View {
    let entries: [LogEntry]
    let emptyTitle: String
    var emptySystemImage = "tray"
    var selectedEntryID: LogEntry.ID?
    var displayLimit = AffectiveViewModel.visibleLogEntryLimit
    var onSelect: (LogEntry) -> Void = { _ in }

    var body: some View {
        let visibleEntries = entries.prefix(displayLimit)

        ScrollView {
            LazyVStack(spacing: 1) {
                if entries.isEmpty {
                    EmptyStateCard(title: emptyTitle, systemImage: emptySystemImage)
                        .padding(.top, 48)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(visibleEntries) { entry in
                        CompactActivityRow(
                            entry: entry,
                            isSelected: selectedEntryID == entry.id,
                            onSelect: { onSelect(entry) }
                        )
                    }

                    if visibleEntries.count < entries.count {
                        LogListLimitRow(shownCount: visibleEntries.count, totalCount: entries.count)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

struct LogListLimitRow: View {
    let shownCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
            Text("\(shownCount) of \(totalCount) shown")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(AppTheme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityLabel("\(shownCount) of \(totalCount) log entries shown")
    }
}

struct CompactActivityRow: View {
    let entry: LogEntry
    let card: LogEntryCardModel
    var isSelected = false
    var onSelect: () -> Void = {}

    init(
        entry: LogEntry,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.card = LogEntryCardModel(entry: entry)
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.createdAt, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 58, alignment: .leading)

                    Text(card.badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.kind.badgeForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(entry.kind.badgeBackground, in: Capsule())

                    Text(card.headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    Image(systemName: "sidebar.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.secondaryText.opacity(0.75))
                }

                Text(card.rowFactSummary)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(card.preview)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? AppTheme.activePanelBackground : entry.kind.entryBackground.opacity(0.74),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.5) : .white.opacity(0.055))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.rawValue) \(entry.title)")
        .accessibilityHint("Inspect this log entry")
    }
}

struct LogEntryInspector: View {
    let entry: LogEntry?
    var brainRootURL: URL?
    var emptyTitle = "Select an entry to inspect it."
    @State private var didCopy = false

    var body: some View {
        Group {
            if let entry {
                inspectorContent(entry)
            } else {
                EmptyStateCard(title: emptyTitle, systemImage: "sidebar.right")
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(AppTheme.controlBackground)
    }

    func inspectorContent(_ entry: LogEntry) -> some View {
        let card = LogEntryCardModel(entry: entry)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                eventSummarySection(card)

                eventPayloadSection(card)

                if let attachment = thumbnailAttachment(for: entry) {
                    EventImageThumbnailView(attachment: attachment)
                        .panelStyle()
                }

                if !card.relatedFacts.isEmpty {
                    eventFactSection(title: "Related IDs", facts: card.relatedFacts)
                }

                if !card.mediaFacts.isEmpty {
                    eventFactSection(title: "Media", facts: card.mediaFacts)
                }

                if !card.detailFacts.isEmpty {
                    DisclosureGroup {
                        eventFactFlow(card.detailFacts)
                            .padding(.top, 8)
                    } label: {
                        Text("Raw Metadata")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .textCase(.uppercase)
                    }
                    .panelStyle()
                }
            }
            .padding(16)
        }
    }

    func eventSummarySection(_ card: LogEntryCardModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(card.badgeText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(card.entry.kind.badgeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(card.entry.kind.badgeBackground, in: Capsule())

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.headline)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.entry.createdAt, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Button {
                    copyEntry(card.entry)
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(didCopy ? AppTheme.accent : AppTheme.secondaryText)
            }

            Text(card.preview)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(AppTheme.primaryText.opacity(0.9))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !card.primaryFacts.isEmpty {
                eventFactFlow(card.primaryFacts)
            }
        }
        .panelStyle()
    }

    func eventPayloadSection(_ card: LogEntryCardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payload")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
                .textCase(.uppercase)

            Text(card.bodyText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(AppTheme.primaryText)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .panelStyle()
    }

    func eventFactSection(title: String, facts: [LogEntryCardModel.Fact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.secondaryText)
                .textCase(.uppercase)

            eventFactFlow(facts)
        }
        .panelStyle()
    }

    func eventFactFlow(_ facts: [LogEntryCardModel.Fact]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(facts) { fact in
                MetadataChip(key: fact.key, value: fact.value)
            }
        }
    }

    func thumbnailAttachment(for entry: LogEntry) -> ChatMediaAttachment? {
        guard let brainRootURL else { return nil }
        return ChatMediaAttachment.attachments(for: entry, brainRootURL: brainRootURL)
            .first { attachment in
                guard attachment.kind == .image, let url = attachment.url else { return false }
                return !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
            }
    }

    func copyEntry(_ entry: LogEntry) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.copyText, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = entry.copyText
        #endif
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

struct ChatTranscriptView: View {
    let entries: [LogEntry]
    let brainRootURL: URL
    var isResponding = false
    var statusText = "Thinking"
    var onReactToBrainUtterance: ((UUID, String) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let typingIndicatorID = "chat-typing-indicator"

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if entries.isEmpty {
                        EmptyStateCard(title: "Start a conversation", systemImage: "bubble.left.and.bubble.right")
                            .padding(.top, 48)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(entries) { entry in
                            ChatBubbleView(
                                entry: entry,
                                brainRootURL: brainRootURL,
                                onReact: onReactToBrainUtterance
                            )
                                .id(entry.id)
                        }
                    }

                    if isResponding {
                        TypingIndicatorBubble(statusText: statusText)
                            .id(typingIndicatorID)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 24)
                .padding(.vertical, 16)
            }
            .chatKeyboardDismissMode()
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation(.smooth(duration: 0.25)) {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: isResponding) { _, isResponding in
                guard isResponding else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    reader.scrollTo(typingIndicatorID, anchor: .bottom)
                }
            }
            .onAppear {
                scrollToBottom(reader: reader)
            }
        }
    }

    func scrollToBottom(reader: ScrollViewProxy) {
        if isResponding {
            withAnimation(.smooth(duration: 0.25)) {
                reader.scrollTo(typingIndicatorID, anchor: .bottom)
            }
        } else if let last = entries.last {
            reader.scrollTo(last.id, anchor: .bottom)
        }
    }
}

struct TypingIndicatorBubble: View {
    let statusText: String
    @State private var isAnimating = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text(displayStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)
                    .animation(.smooth(duration: 0.2), value: displayStatusText)

                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(AppTheme.secondaryText.opacity(0.92))
                            .frame(width: 6, height: 6)
                            .scaleEffect(isAnimating ? 1.0 : 0.62)
                            .opacity(isAnimating ? 1.0 : 0.42)
                            .animation(
                                .easeInOut(duration: 0.62)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.16),
                                value: isAnimating
                            )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(AppTheme.messageIncoming, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayStatusText)
            }
            .frame(maxWidth: horizontalSizeClass == .compact ? nil : 560, alignment: .leading)

            Spacer(minLength: horizontalSizeClass == .compact ? 42 : 110)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }

    var displayStatusText: String {
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Thinking" : trimmed
    }

    var avatar: some View {
        Circle()
            .fill(AppTheme.panelBackground)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            .overlay(Circle().stroke(AppTheme.separator))
    }
}

struct ChatBubbleView: View {
    let entry: LogEntry
    let brainRootURL: URL
    var onReact: ((UUID, String) -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingReactionPicker = false
    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOutgoing {
                Spacer(minLength: horizontalSizeClass == .compact ? 42 : 110)
            } else if !isSystem {
                avatar
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                if !isSystem {
                    Text(labelText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.horizontal, 4)
                }

                ZStack(alignment: .topTrailing) {
                    Text(messageText)
                        .font(entry.kind == .emote ? .body.italic() : .body)
                        .foregroundStyle(textColor)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .padding(.horizontal, isSystem ? 10 : 13)
                        .padding(.vertical, isSystem ? 7 : 10)
                        .background(bubbleBackground, in: bubbleShape)
                        .overlay {
                            bubbleShape.stroke(borderColor, lineWidth: isSystem ? 1 : 0)
                        }
                        .opacity(entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? 0 : 1)
                        .frame(height: entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? 0 : nil)
                        .contextMenu {
                            if canReact {
                                Button("Add reaction…") {
                                    showingReactionPicker = true
                                }
                            }
                        }

                    if canReact, showsReactionAffordance {
                        AddReactionButton {
                            showingReactionPicker = true
                        }
                        .offset(x: 6, y: -6)
                    }
                }

                if let reaction = entry.userReaction {
                    Button {
                        showingReactionPicker = true
                    } label: {
                        Text(reaction)
                            .font(.title3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(AppTheme.panelBackground.opacity(0.85), in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.separator))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change reaction")
                }

                ForEach(attachments) { attachment in
                    ChatAttachmentView(attachment: attachment, isOutgoing: isOutgoing)
                }

                Text(entry.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.78))
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: isSystem ? .infinity : maxBubbleWidth, alignment: isOutgoing ? .trailing : .leading)

            if !isOutgoing {
                Spacer(minLength: isSystem ? 0 : (horizontalSizeClass == .compact ? 42 : 110))
            }
        }
        .frame(maxWidth: .infinity, alignment: isSystem ? .center : (isOutgoing ? .trailing : .leading))
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .sheet(isPresented: $showingReactionPicker) {
            EmojiReactionPickerSheet { emoji in
                guard !emoji.isEmpty, let onReact else { return }
                onReact(entry.id, emoji)
            }
        }
    }

    var showsReactionAffordance: Bool {
        #if os(macOS)
        isHovered
        #else
        false
        #endif
    }

    var isOutgoing: Bool {
        entry.kind == .user || entry.kind == .sent
    }

    var isSystem: Bool {
        entry.kind == .state || entry.kind == .error
    }

    var canReact: Bool {
        !isOutgoing && !isSystem && (entry.kind == .brain || entry.kind == .emote)
    }

    var messageText: String {
        if entry.kind == .emote {
            return "*\(entry.body)*"
        }
        return entry.body
    }

    var labelText: String {
        isOutgoing ? "You" : entry.title
    }

    var maxBubbleWidth: CGFloat? {
        horizontalSizeClass == .compact ? nil : 560
    }

    var avatar: some View {
        Circle()
            .fill(AppTheme.panelBackground)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: entry.kind == .error ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(entry.kind == .error ? AppTheme.danger : AppTheme.accent)
            }
            .overlay(Circle().stroke(AppTheme.separator))
    }

    var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isSystem ? 12 : 18, style: .continuous)
    }

    var bubbleBackground: Color {
        switch entry.kind {
        case .user, .sent:
            return AppTheme.messageOutgoing
        case .brain, .result:
            return AppTheme.messageIncoming
        case .emote, .process:
            return AppTheme.messageIncoming.opacity(0.82)
        case .state:
            return AppTheme.panelBackground.opacity(0.72)
        case .error:
            return AppTheme.messageError
        }
    }

    var borderColor: Color {
        isSystem ? .white.opacity(0.08) : .clear
    }

    var textColor: Color {
        isOutgoing ? .white : AppTheme.primaryText
    }

    var attachments: [ChatMediaAttachment] {
        ChatMediaAttachment.attachments(for: entry, brainRootURL: brainRootURL)
    }
}

struct ChatAttachmentView: View {
    let attachment: ChatMediaAttachment
    let isOutgoing: Bool

    var body: some View {
        switch attachment.kind {
        case .image:
            ChatImageAttachmentView(attachment: attachment)
                .frame(maxWidth: 260)
        case .audio:
            ChatAudioAttachmentView(attachment: attachment, isOutgoing: isOutgoing)
        case .file:
            HStack(spacing: 8) {
                Image(systemName: "doc")
                Text(attachment.displayName)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOutgoing ? .white : AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background((isOutgoing ? Color.white.opacity(0.14) : AppTheme.editorBackground), in: Capsule())
        }
    }
}

struct ChatImageAttachmentView: View {
    let attachment: ChatMediaAttachment

    var body: some View {
        Group {
            if let url = attachment.url {
                if url.isFileURL {
                    LocalCachedFileImageView(url: url, missingContent: AnyView(missingImage))
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            missingImage
                        case .empty:
                            ProgressView()
                        @unknown default:
                            missingImage
                        }
                    }
                }
            } else {
                missingImage
            }
        }
        .frame(maxWidth: 260, minHeight: 120, maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .accessibilityLabel(attachment.caption ?? "Image attachment")
    }

    var missingImage: some View {
        VStack(spacing: 7) {
            Image(systemName: "photo")
                .font(.title3.weight(.semibold))
            Text("Image unavailable")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(AppTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }
}

struct ChatAudioAttachmentView: View {
    let attachment: ChatMediaAttachment
    let isOutgoing: Bool
    @State private var player: PlatformAudioPlayer?
    @State private var isPlaying = false
    #if canImport(AVFoundation)
    @State private var playerDelegate = ChatAudioPlayerDelegate()
    #endif

    var body: some View {
        Button {
            togglePlayback()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(isOutgoing ? Color.white.opacity(0.18) : AppTheme.panelBackground, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.caption ?? "Audio")
                        .font(.caption.weight(.semibold))
                    Text(attachment.displayName)
                        .font(.caption2)
                        .foregroundStyle(isOutgoing ? .white.opacity(0.72) : AppTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "waveform")
                    .foregroundStyle(isOutgoing ? .white.opacity(0.72) : AppTheme.secondaryText)
            }
            .foregroundStyle(isOutgoing ? .white : AppTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 260)
            .background((isOutgoing ? Color.white.opacity(0.12) : AppTheme.editorBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
    }

    func togglePlayback() {
        guard let url = attachment.url, url.isFileURL else { return }
        #if canImport(AVFoundation)
        do {
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else {
                let nextPlayer = try PlatformAudioPlayer(contentsOf: url)
                playerDelegate.onFinished = {
                    Task { @MainActor in
                        isPlaying = false
                        player = nil
                    }
                }
                nextPlayer.delegate = playerDelegate
                player = nextPlayer
                nextPlayer.play()
                isPlaying = true
            }
        } catch {
            isPlaying = false
            player = nil
        }
        #endif
    }
}

#if canImport(AVFoundation)
private final class ChatAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }
}
#endif

#if canImport(AVFoundation)
typealias PlatformAudioPlayer = AVAudioPlayer
#else
final class PlatformAudioPlayer {}
#endif

struct ChatMediaAttachment: Identifiable, Equatable {
    enum Kind {
        case image
        case audio
        case file
    }

    let id: String
    let kind: Kind
    let url: URL?
    let mimeType: String?
    let caption: String?

    var displayName: String {
        url?.lastPathComponent ?? mimeType ?? "attachment"
    }

    static func attachments(for entry: LogEntry, brainRootURL: URL) -> [ChatMediaAttachment] {
        var attachments: [ChatMediaAttachment] = []
        let mediaKind = entry.metadata["media_kind"]?.lowercased()
        if let imageURL = resolvedURL(from: firstValue(in: entry.metadata, keys: ["image_url", "image_path", "media_url", "media_path", "path", "file"]), brainRootURL: brainRootURL),
           mediaKind == "image" || isImage(url: imageURL, mimeType: entry.metadata["mime_type"]) {
            attachments.append(.init(
                id: "image-\(imageURL.absoluteString)",
                kind: .image,
                url: imageURL,
                mimeType: entry.metadata["mime_type"],
                caption: firstValue(in: entry.metadata, keys: ["caption", "alt", "title"])
            ))
        }
        if let audioURL = resolvedURL(from: firstValue(in: entry.metadata, keys: ["audio_url", "audio_path", "media_url", "media_path", "path"]), brainRootURL: brainRootURL),
           mediaKind == "audio" || isAudio(url: audioURL, mimeType: entry.metadata["mime_type"]) {
            attachments.append(.init(
                id: "audio-\(audioURL.absoluteString)",
                kind: .audio,
                url: audioURL,
                mimeType: entry.metadata["mime_type"],
                caption: firstValue(in: entry.metadata, keys: ["caption", "title"])
            ))
        }
        return attachments
    }

    static func firstValue(in metadata: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func resolvedURL(from rawValue: String?, brainRootURL: URL) -> URL? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        if let url = URL(string: rawValue), url.scheme == "http" || url.scheme == "https" || url.isFileURL {
            return url
        }
        let expanded = (rawValue as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return brainRootURL.appendingPathComponent(rawValue)
    }

    static func isImage(url: URL, mimeType: String?) -> Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("image/") {
            return true
        }
        return ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(url.pathExtension.lowercased())
    }

    static func isAudio(url: URL, mimeType: String?) -> Bool {
        if let mimeType, mimeType.lowercased().hasPrefix("audio/") {
            return true
        }
        return ["m4a", "mp3", "wav", "aac", "caf", "aiff"].contains(url.pathExtension.lowercased())
    }
}

struct LogEntryView: View {
    let entry: LogEntry
    var brainRootURL: URL?
    var showsCopyButton = false
    var showsMessageLabels = true
    var showsMetadata = true
    @State private var didCopy = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            entryHeader

            if showsMetadata && !entry.metadata.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(entry.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        MetadataChip(key: key, value: value)
                    }
                }
            }

            if let thumbnailAttachment {
                EventImageThumbnailView(attachment: thumbnailAttachment)
            }

            Text(entry.body)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(AppTheme.primaryText)
                .textSelection(.enabled)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(entry.kind.entryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .padding(entry.kind == .user || entry.kind == .sent ? .trailing : .leading, horizontalSizeClass == .compact ? 0 : 34)
    }

    @ViewBuilder
    var entryHeader: some View {
        if showsMessageLabels {
            ViewThatFits(in: .horizontal) {
                entryHeaderWithLabels(isStacked: false)
                entryHeaderWithLabels(isStacked: true)
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                timestamp
            }
        }
    }

    func entryHeaderWithLabels(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        kindBadge
                        timestamp
                    }
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    copyButton
                }
            } else {
                HStack(alignment: .top, spacing: 9) {
                    kindBadge
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    copyButton
                    timestamp
                }
            }
        }
    }

    var timestamp: some View {
        Text(entry.createdAt, format: .dateTime.hour().minute().second())
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
    }

    var kindBadge: some View {
        Text(entry.kind.rawValue.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(entry.kind.badgeForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(entry.kind.badgeBackground, in: Capsule())
    }

    @ViewBuilder
    var copyButton: some View {
        if showsCopyButton {
            Button {
                copyEntry()
            } label: {
                Label(didCopy ? "Copied" : "Copy this", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(didCopy ? AppTheme.accent : AppTheme.secondaryText)
            .help("Copy this event")
        }
    }

    var thumbnailAttachment: ChatMediaAttachment? {
        guard let brainRootURL else { return nil }
        return ChatMediaAttachment.attachments(for: entry, brainRootURL: brainRootURL)
            .first { attachment in
                guard attachment.kind == .image, let url = attachment.url else { return false }
                return !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
            }
    }

    func copyEntry() {
        let text = entry.copyText
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

struct EventImageThumbnailView: View {
    let attachment: ChatMediaAttachment

    var body: some View {
        Button {
            openAttachment()
        } label: {
            HStack(spacing: 10) {
                ChatImageAttachmentView(attachment: attachment)
                    .frame(width: 92, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Label("Open image", systemImage: "photo")
                        .font(.caption.weight(.semibold))
                    Text(attachment.displayName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .foregroundStyle(AppTheme.primaryText)
            .padding(8)
            .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.separator)
            )
        }
        .buttonStyle(.plain)
        .help("Open \(attachment.displayName)")
        .accessibilityLabel("Open image \(attachment.displayName)")
    }

    func openAttachment() {
        guard let url = attachment.url else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

struct MetadataChip: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text("\(key):")
                .fontWeight(.bold)
            Text(value)
                .lineLimit(1)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(AppTheme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(AppTheme.separator))
        .help("\(key): \(value)")
    }
}

extension LogEntry {
    var copyText: String {
        var lines = [
            "kind: \(kind.rawValue)",
            "title: \(title)",
            "time: \(createdAt.formatted(date: .numeric, time: .standard))",
        ]
        if !metadata.isEmpty {
            lines.append("metadata:")
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                lines.append("- \(key): \(value)")
            }
        }
        lines.append("body:")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}

extension Array where Element == LogEntry {
    var eventLogCopyText: String {
        var sections = [
            "Affective event log",
            "entries: \(count)",
            "copied: \(Date().formatted(date: .numeric, time: .standard))",
        ]

        if !isEmpty {
            sections.append("")
            sections.append(map(\.copyText).joined(separator: "\n\n---\n\n"))
        }

        return sections.joined(separator: "\n")
    }
}
