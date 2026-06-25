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

struct CommandFilterBar: View {
    @ObservedObject var model: AffectiveViewModel
    @State private var didCopyLog = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                kindPicker
                copyLogButton
            }

            VStack(alignment: .leading, spacing: 8) {
                searchField
                HStack(spacing: 10) {
                    kindPicker
                    copyLogButton
                }
            }
        }
    }

    var searchField: some View {
        TextField("Search command log", text: $model.commandSearchText)
            .textFieldStyle(.plain)
            .optionFieldStyle(isDirty: !model.commandSearchText.isEmpty)
    }

    var kindPicker: some View {
        Picker("Kind", selection: $model.selectedCommandKind) {
            Text("All").tag(LogKind?.none)
            ForEach(LogKind.allCases) { kind in
                Text(kind.rawValue.optionDisplayName).tag(LogKind?.some(kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(AppTheme.primaryText)
        .frame(width: 132)
        .optionFieldStyle(isDirty: model.selectedCommandKind != nil)
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
        .disabled(model.commandEntries.isEmpty)
        .opacity(model.commandEntries.isEmpty ? 0.55 : 1)
        .help("Copy the entire command log")
        .accessibilityLabel(didCopyLog ? "Copied command log" : "Copy entire command log")
    }

    func copyEntireLog() {
        let text = model.commandEntries.commandLogCopyText
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
        CompactIconStatusPill(
            text: "\(model.filteredKnowledgeEntries.count)",
            systemImage: "line.3.horizontal.decrease.circle"
        )
        .accessibilityLabel("\(model.filteredKnowledgeEntries.count) filtered knowledge entries")
    }
}

struct LogHeader: View {
    let model: AffectiveViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Affective")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Affective Memory-Based Intelligence")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 16)

            CompactStatusPill(text: countText)
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
        }
    }
}

struct DeveloperConsoleList: View {
    let entries: [LogEntry]
    let emptyTitle: String

    var body: some View {
        CompactActivityList(
            entries: entries,
            emptyTitle: emptyTitle,
            emptySystemImage: "terminal"
        )
    }
}

struct CompactActivityList: View {
    let entries: [LogEntry]
    let emptyTitle: String
    var emptySystemImage = "tray"

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 1) {
                    if entries.isEmpty {
                        EmptyStateCard(title: emptyTitle, systemImage: emptySystemImage)
                            .padding(.top, 48)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(entries) { entry in
                            CompactActivityRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: entries.count) { _, _ in
                guard let last = entries.last else { return }
                withAnimation(.smooth(duration: 0.22)) {
                    reader.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct CompactActivityRow: View {
    let entry: LogEntry
    @State private var didCopy = false

    var body: some View {
        Button {
            copyEntry()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.createdAt, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 58, alignment: .leading)

                    Text(entry.kind.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.kind.badgeForeground)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(entry.kind.badgeBackground, in: Capsule())

                    Text(entry.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)

                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(didCopy ? AppTheme.accent : AppTheme.secondaryText.opacity(0.75))
                }

                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.primaryText.opacity(0.88))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }

                if !entry.metadata.isEmpty {
                    Text(metadataSummary)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.secondaryText.opacity(0.82))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(entry.kind.entryBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.055))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.kind.rawValue) \(entry.title)")
        .accessibilityHint("Copies this log entry")
    }

    var metadataSummary: String {
        entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
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

struct ChatTranscriptView: View {
    let entries: [LogEntry]
    let brainRootURL: URL
    var isResponding = false
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
                            ChatBubbleView(entry: entry, brainRootURL: brainRootURL)
                                .id(entry.id)
                        }
                    }

                    if isResponding {
                        TypingIndicatorBubble()
                            .id(typingIndicatorID)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .compact ? 12 : 24)
                .padding(.vertical, 16)
            }
            .chatKeyboardDismissMode()
            .onChange(of: entries.count) { _, _ in
                guard let last = entries.last else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    reader.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: isResponding) { _, isResponding in
                guard isResponding else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    reader.scrollTo(typingIndicatorID, anchor: .bottom)
                }
            }
        }
    }
}

struct TypingIndicatorBubble: View {
    @State private var isAnimating = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text("Affective")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 4)

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
                .accessibilityLabel("Affective is thinking")
            }
            .frame(maxWidth: horizontalSizeClass == .compact ? nil : 560, alignment: .leading)

            Spacer(minLength: horizontalSizeClass == .compact ? 42 : 110)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
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
            .overlay(Circle().stroke(.white.opacity(0.08)))
    }
}

struct ChatBubbleView: View {
    let entry: LogEntry
    let brainRootURL: URL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

                Text(entry.body)
                    .font(.body)
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
    }

    var isOutgoing: Bool {
        entry.kind == .user || entry.kind == .sent
    }

    var isSystem: Bool {
        entry.kind == .state || entry.kind == .error
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
            .overlay(Circle().stroke(.white.opacity(0.08)))
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
                    localImage(url: url)
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
                .stroke(.white.opacity(0.10))
        )
        .accessibilityLabel(attachment.caption ?? "Image attachment")
    }

    @ViewBuilder
    func localImage(url: URL) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            missingImage
        }
        #elseif canImport(AppKit)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            missingImage
        }
        #else
        missingImage
        #endif
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
                player = nextPlayer
                nextPlayer.play()
                isPlaying = true
            }
        } catch {
            isPlaying = false
        }
        #endif
    }
}

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
                CommandImageThumbnailView(attachment: thumbnailAttachment)
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
                .stroke(.white.opacity(0.07))
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
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

struct CommandImageThumbnailView: View {
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
                    .stroke(.white.opacity(0.08))
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
        .overlay(Capsule().stroke(.white.opacity(0.08)))
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
    var commandLogCopyText: String {
        var sections = [
            "Affective command log",
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
