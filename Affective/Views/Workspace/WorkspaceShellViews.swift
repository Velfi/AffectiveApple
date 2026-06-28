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

struct WorkspaceSidebar: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LogHeader(model: model)

            Divider()
                .overlay(AppTheme.softSeparator)

            SidebarBrainPanel(model: model)

            Divider()
                .overlay(AppTheme.softSeparator)

            VStack(spacing: 6) {
                ForEach(WorkspaceSection.allCases) { section in
                    WorkspaceSidebarButton(
                        section: section,
                        isSelected: model.selectedSection == section,
                        badge: section == .mailbox && model.unreadMailboxItemCount > 0 ? "\(model.unreadMailboxItemCount)" : nil,
                        select: { model.selectedSection = section }
                    )
                }
            }
            .padding(.top, 2)

            Spacer()
        }
        .padding(18)
        .background(AppTheme.sidebarBackground)
    }
}

struct WorkspaceSidebarButton: View {
    let section: WorkspaceSection
    let isSelected: Bool
    var badge: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.rawValue)
                        .font(.callout.weight(.semibold))
                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let badge {
                    CompactStatusPill(text: badge)
                        .accessibilityLabel("\(badge) unread reports")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? AppTheme.activePanelBackground : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.45) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct WorkspaceDetail: View {
    @ObservedObject var model: AffectiveViewModel
    var composerFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            AppTheme.controlBackground

            switch model.selectedSection {
            case .chat:
                ChatWorkspace(model: model, composerFocused: composerFocused)
            case .mailbox:
                DreamMailboxWorkspace(model: model)
            case .developer:
                DeveloperWorkspace(model: model)
            case .knowledge:
                KnowledgeWorkspace(model: model)
            case .stats:
                BrainStatsWorkspace(model: model)
            case .settings:
                OptionsView(model: model)
            }
        }
        .onDrop(of: [.image, .fileURL, .url], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let name = provider.suggestedName ?? "dropped image"
        model.reportDroppedImage(name: name)
        return true
    }
}

struct ChatWorkspace: View {
    @ObservedObject var model: AffectiveViewModel
    var composerFocused: FocusState<Bool>.Binding
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            portraitBody
        } else if verticalSizeClass == .compact {
            landscapeBody
        } else {
            portraitBody
        }
    }

    var portraitBody: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                if !composerFocused.wrappedValue {
                    WorkspaceHeader(
                        title: model.workspaceBrainTitle,
                        subtitle: "Chat with the selected brain and choose how much autonomy it has.",
                        model: model
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Divider()
                    .overlay(AppTheme.softSeparator)
            }

            if horizontalSizeClass == .compact {
                ChatTranscriptView(
                    entries: model.chatEntries,
                    brainRootURL: model.brain.rootURL,
                    isResponding: model.isAwaitingChatResponse
                )
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    compactPortraitComposer
                }
            } else {
                ChatTranscriptView(
                    entries: model.chatEntries,
                    brainRootURL: model.brain.rootURL,
                    isResponding: model.isAwaitingChatResponse
                )
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ComposerPanel(model: model, composerFocused: composerFocused)
                    .padding(24)
                    .background(AppTheme.sidebarBackground.opacity(0.45))
            }
        }
    }

    var compactPortraitComposer: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.softSeparator)

            ComposerPanel(model: model, composerFocused: composerFocused, isCompact: true)
                .padding(.horizontal, 10)
                .padding(.top, composerFocused.wrappedValue ? 7 : 8)
                .padding(.bottom, composerFocused.wrappedValue ? 8 : 10)
                .background(AppTheme.sidebarBackground.opacity(0.86))
                .animation(.smooth(duration: 0.18), value: composerFocused.wrappedValue)
        }
    }

    var landscapeBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ChatTranscriptView(
                    entries: model.chatEntries,
                    brainRootURL: model.brain.rootURL,
                    isResponding: model.isAwaitingChatResponse
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(AppTheme.softSeparator)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HeaderStrip(model: model)
                        .panelStyle()
                    ComposerPanel(model: model, composerFocused: composerFocused)
                }
                .padding(12)
            }
            .frame(width: 320)
            .background(AppTheme.sidebarBackground.opacity(0.55))
        }
    }
}

struct DreamMailboxWorkspace: View {
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            if verticalSizeClass == .compact {
                HStack(spacing: 0) {
                    mailboxList
                        .frame(width: 310)
                        .frame(maxHeight: .infinity)

                    Divider()
                        .overlay(AppTheme.softSeparator)

                    mailboxDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        mailboxList
                            .frame(maxHeight: compactMailboxListHeight(for: proxy.size.height))

                        Divider()
                            .overlay(AppTheme.softSeparator)

                        mailboxDetail
                            .frame(maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                }
            }
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                mailboxList
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                    .overlay(AppTheme.softSeparator)

                mailboxDetail
                    .frame(width: 360)
                    .background(AppTheme.sidebarBackground.opacity(0.52))
            }
        } else {
            HStack(spacing: 0) {
                mailboxList
                    .frame(width: 390)

                Divider()
                    .overlay(AppTheme.softSeparator)

                mailboxDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func compactMailboxListHeight(for availableHeight: CGFloat) -> CGFloat {
        min(300, max(220, availableHeight * 0.38))
    }

    var mailboxList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                WorkspaceHeader(
                    title: "Mailbox",
                    subtitle: "Brain-owned mailbox items with local read and archive state.",
                    model: model
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        archiveToggle
                        refreshButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        archiveToggle
                        refreshButton
                    }
                }
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? 14 : 24)
            .padding(.top, horizontalSizeClass == .compact ? 14 : 24)
            .padding(.bottom, 14)

            Divider()
                .overlay(AppTheme.softSeparator)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.visibleMailboxItems.isEmpty {
                        EmptyStateCard(
                            title: model.showsArchivedMailboxItems ? "Archived mailbox items will appear here." : "New mailbox items will appear here.",
                            systemImage: "tray.full"
                        )
                        .padding(.top, 36)
                    } else {
                        ForEach(model.visibleMailboxItems) { item in
                            MailboxItemRow(
                                item: item,
                                brainRootURL: model.brain.rootURL,
                                isSelected: model.selectedMailboxItem?.id == item.id
                            ) {
                                model.selectMailboxItem(item)
                            }
                        }
                    }
                }
                .padding(horizontalSizeClass == .compact ? 12 : 18)
            }
        }
    }

    var mailboxDetail: some View {
        ScrollView {
            if let item = model.selectedMailboxItem {
                MailboxItemDetail(model: model, item: item)
                    .padding(horizontalSizeClass == .compact ? 14 : 24)
            } else {
                EmptyStateCard(title: "Select a mailbox item to read it.", systemImage: "envelope.open")
                    .padding(.top, 48)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    var archiveToggle: some View {
        SegmentedControl(
            selection: $model.showsArchivedMailboxItems,
            options: [
                .init(value: false, title: "Inbox", systemImage: "tray"),
                .init(value: true, title: "Archived", systemImage: "archivebox"),
            ]
        )
        .frame(width: 190)
    }

    var refreshButton: some View {
        Button {
            model.refreshMailboxItems()
        } label: {
            Label("Scan", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Refresh mailbox items from the selected brain")
    }
}

struct MailboxItemRow: View {
    let item: MailboxItem
    let brainRootURL: URL
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                MailboxItemImage(
                    path: item.imagePath,
                    mimeType: item.imageMimeType,
                    brainRootURL: brainRootURL
                )
                .frame(width: 74, height: 74, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)

                        if !item.isRead {
                            Text("UNREAD")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textOnAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(AppTheme.accent, in: Capsule())
                        }

                        Spacer(minLength: 4)
                    }

                    Text(item.summary)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    MailboxItemMetricLine(item: item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.activePanelBackground : AppTheme.panelBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.45) : .white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

struct MailboxItemDetail: View {
    @ObservedObject var model: AffectiveViewModel
    let item: MailboxItem

    var body: some View {
        MailboxItemDetailContent(
            item: item,
            brainRootURL: model.brain.rootURL
        ) {
            model.setMailboxItem(item.id, isRead: !item.isRead)
        } toggleArchived: {
            model.setMailboxItem(item.id, isArchived: !item.isArchived)
        }
    }
}

struct MailboxItemDetailContent: View {
    let item: MailboxItem
    let brainRootURL: URL
    let toggleRead: () -> Void
    let toggleArchived: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.createdAt, format: .dateTime.month().day().year().hour().minute())
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)

                    CompactStatusPill(text: item.summarySource.optionDisplayName)

                    Spacer(minLength: 8)
                }

                Text(item.summary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MailboxItemImage(
                path: item.imagePath,
                mimeType: item.imageMimeType,
                brainRootURL: brainRootURL
            )
            .frame(maxWidth: 560, minHeight: 220, maxHeight: 420)

            MailboxItemMetricLine(item: item)

            MailboxItemSection(title: "Waking Thought", text: item.reflection)
            MailboxItemSection(title: "Image Spec", text: item.imageSpec ?? "No spec recovered.")
            MailboxItemSection(title: "Source Events", text: item.sourceEventIDs.isEmpty ? "None recorded." : item.sourceEventIDs.joined(separator: "\n"))
            MailboxItemSection(title: "DreamMail Body", text: item.bodyText)

            HStack(spacing: 10) {
                Button {
                    toggleRead()
                } label: {
                    Label(item.isRead ? "Mark Unread" : "Mark Read", systemImage: item.isRead ? "envelope.badge" : "envelope.open")
                }
                .buttonStyle(.bordered)

                Button {
                    toggleArchived()
                } label: {
                    Label(item.isArchived ? "Unarchive" : "Archive", systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

struct MailboxItemMetricLine: View {
    let item: MailboxItem

    var body: some View {
        FlowLayout(spacing: 6) {
            if let heat = item.heat {
                MailboxItemChip(text: "heat \(heat.formatted(.number.precision(.fractionLength(2))))")
            }
            if let style = item.style {
                MailboxItemChip(text: style.optionDisplayName)
            }
            if let confidence = item.confidence {
                MailboxItemChip(text: "confidence \(confidence.formatted(.number.precision(.fractionLength(2))))")
            }
            MailboxItemChip(text: "\(item.sourceEventIDs.count) events")
        }
    }
}

struct MailboxItemChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AppTheme.editorBackground, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.separator))
    }
}

struct MailboxItemSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)
            Text(text)
                .font(title == "DreamMail Body" ? .system(size: 12, weight: .regular, design: .monospaced) : .callout)
                .foregroundStyle(AppTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.panelBackground.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }
}

struct MailboxItemImage: View {
    let path: String?
    let mimeType: String?
    let brainRootURL: URL

    var body: some View {
        Group {
            if let url = ChatMediaAttachment.resolvedURL(from: path, brainRootURL: brainRootURL),
               ChatMediaAttachment.isImage(url: url, mimeType: mimeType) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .accessibilityLabel("Mailbox item image")
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
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title3.weight(.semibold))
            Text("No image")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(AppTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.editorBackground)
    }
}

#if DEBUG
private enum MailboxItemPreviewData {
    static let rootURL = URL(fileURLWithPath: "/tmp/Affective-MailboxItemPreview", isDirectory: true)

    static let unread = MailboxItem(
        mailboxID: "dreammail-2026-06-25-dream-01",
        sourceDreamID: "dream-01",
        dayKey: "2026-06-25",
        createdAt: Date(timeIntervalSinceReferenceDate: 804_492_000),
        summary: "A warm, high-heat dream linked the workshop light, a half-finished promise, and the image of a door opening into rain.",
        summarySource: "preview_mailbox",
        bodyText: """
        DreamMail

        Dream ID: dream-01
        Day: 2026-06-25
        Heat: 0.84
        Style: vivid
        Confidence: 0.82

        Waking Thought:
        The dream circled around unfinished repair work and turned it into a threshold image.

        Connection:
        The generated artifact held the same threshold motif, with a blue door, rain, and warm interior light.
        """,
        reflection: "The dream circled around unfinished repair work and turned it into a threshold image.",
        heat: 0.84,
        style: "vivid",
        confidence: 0.82,
        sourceEventIDs: ["memory:workshop-light", "artifact:door-rain", "event:dream-image-01"],
        artifactID: "artifact-door-rain",
        imagePath: nil,
        imageMimeType: "image/png",
        imageSpec: "A blue door opening into rain, with warm workshop light spilling from inside.",
        isRead: false,
        isArchived: false
    )

    static let read = MailboxItem(
        mailboxID: "dreammail-2026-06-24-dream-02",
        sourceDreamID: "dream-02",
        dayKey: "2026-06-24",
        createdAt: Date(timeIntervalSinceReferenceDate: 804_405_600),
        summary: "A quieter dream compared two remembered rooms and resolved them into a small, steady image of continuity.",
        summarySource: "openai",
        bodyText: "DreamMail\n\nA quieter mailbox item for opened/read mailbox coverage.",
        reflection: "Two remembered rooms folded into one continuous place.",
        heat: 0.41,
        style: "quiet",
        confidence: 0.58,
        sourceEventIDs: ["memory:room-a", "memory:room-b"],
        artifactID: nil,
        imagePath: nil,
        imageMimeType: nil,
        imageSpec: nil,
        isRead: true,
        isArchived: false
    )

    static let archived = MailboxItem(
        mailboxID: "dreammail-2026-06-23-dream-03",
        sourceDreamID: "dream-03",
        dayKey: "2026-06-23",
        createdAt: Date(timeIntervalSinceReferenceDate: 804_319_200),
        summary: "Archived DreamMail preview with a recovered image prompt and reversible archive state.",
        summarySource: "preview_mailbox",
        bodyText: "DreamMail\n\nArchived mailbox item fixture.",
        reflection: "A completed waking thought that has been moved out of the active inbox.",
        heat: 0.62,
        style: "symbolic",
        confidence: 0.70,
        sourceEventIDs: ["event:dream-image-archived"],
        artifactID: "artifact-archived",
        imagePath: nil,
        imageMimeType: "image/png",
        imageSpec: "A neatly folded letter beside a glowing image frame.",
        isRead: true,
        isArchived: true
    )
}

#Preview("Mailbox Empty") {
    EmptyStateCard(title: "New mailbox items will appear here.", systemImage: "tray.full")
        .padding(24)
        .frame(width: 390)
        .background(AppTheme.background)
}

#Preview("Mailbox Unread Item") {
    MailboxItemRow(
        item: MailboxItemPreviewData.unread,
        brainRootURL: MailboxItemPreviewData.rootURL,
        isSelected: true
    ) {}
    .padding(18)
    .frame(width: 390)
    .background(AppTheme.background)
}

#Preview("Mailbox Opened Item") {
    ScrollView {
        MailboxItemDetailContent(
            item: MailboxItemPreviewData.read,
            brainRootURL: MailboxItemPreviewData.rootURL
        ) {} toggleArchived: {}
        .padding(24)
    }
    .frame(width: 760, height: 720)
    .background(AppTheme.background)
}

#Preview("Mailbox Archived Item") {
    MailboxItemRow(
        item: MailboxItemPreviewData.archived,
        brainRootURL: MailboxItemPreviewData.rootURL,
        isSelected: false
    ) {}
    .padding(18)
    .frame(width: 390)
    .background(AppTheme.background)
}
#endif

struct DeveloperWorkspace: View {
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    compactDeveloperMain(horizontalPadding: 14, topPadding: 14)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)

                    Divider()
                        .overlay(AppTheme.softSeparator)

                    compactDeveloperTools(maxHeight: compactToolsHeight(for: proxy.size.height))
                }
            }
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                compactDeveloperMain(horizontalPadding: 16, topPadding: 12)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HeaderStrip(model: model)
                            .panelStyle()
                        ReminderToolsPanel(model: model)
                    }
                    .padding(12)
                }
                .frame(width: 300)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        } else {
            HStack(spacing: 0) {
                developerMain(horizontalPadding: 32, topPadding: 28)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HeaderStrip(model: model)
                        ReminderToolsPanel(model: model)
                    }
                    .padding(24)
                }
                .frame(width: 360)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        }
    }

    func compactToolsHeight(for availableHeight: CGFloat) -> CGFloat {
        min(240, max(168, availableHeight * 0.26))
    }

    func compactDeveloperTools(maxHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                compactToolPanel(maxHeight: maxHeight) {
                    ReminderToolsPanel(model: model)
                }
            }
            .padding(14)
        }
        .frame(height: maxHeight)
        .background(AppTheme.sidebarBackground.opacity(0.6))
    }

    func compactToolPanel<Content: View>(
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(width: 340)
        }
        .frame(width: 340, height: max(maxHeight - 28, 1), alignment: .top)
    }

    func compactDeveloperMain(horizontalPadding: CGFloat, topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HeaderStrip(model: model)
                    .panelStyle()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Developer")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    CompactStatusPill(text: "\(model.filteredEventEntries.count)")
                        .accessibilityLabel("\(model.filteredEventEntries.count) event entries")
                }

                EventFilterBar(model: model)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, 12)

            Divider()
                .overlay(AppTheme.softSeparator)

            DeveloperConsoleList(
                entries: model.filteredEventEntries,
                emptyTitle: "Brain events and capability results will appear here."
            )
        }
    }

    func developerMain(horizontalPadding: CGFloat, topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                title: "Developer",
                subtitle: "Inspect Brain events, filter by kind, and observe capability results.",
                model: model
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, 16)

            EventFilterBar(model: model)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 16)

            Divider()
                .overlay(AppTheme.softSeparator)

            EntriesList(
                entries: model.filteredEventEntries,
                emptyTitle: "Brain events and capability results will appear here.",
                brainRootURL: model.brain.rootURL,
                showsCopyButton: true
            )
        }
    }
}

struct KnowledgeWorkspace: View {
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    compactKnowledgeMain(horizontalPadding: 14, topPadding: 14)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)

                    Divider()
                        .overlay(AppTheme.softSeparator)

                    compactKnowledgeTools(maxHeight: compactToolsHeight(for: proxy.size.height))
                }
            }
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                compactKnowledgeMain(horizontalPadding: 16, topPadding: 12)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        MemoryToolsPanel(model: model)
                        ReminderToolsPanel(model: model)
                    }
                    .padding(12)
                }
                .frame(width: 300)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        } else {
            HStack(spacing: 0) {
                knowledgeMain(horizontalPadding: 32, topPadding: 28)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        MemoryToolsPanel(model: model)
                        ReminderToolsPanel(model: model)
                    }
                    .padding(24)
                }
                .frame(width: 380)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        }
    }

    func compactToolsHeight(for availableHeight: CGFloat) -> CGFloat {
        min(240, max(168, availableHeight * 0.26))
    }

    func compactKnowledgeTools(maxHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                compactToolPanel(maxHeight: maxHeight) {
                    MemoryToolsPanel(model: model)
                }
                compactToolPanel(maxHeight: maxHeight) {
                    ReminderToolsPanel(model: model)
                }
            }
            .padding(14)
        }
        .frame(height: maxHeight)
        .background(AppTheme.sidebarBackground.opacity(0.6))
    }

    func compactToolPanel<Content: View>(
        maxHeight: CGFloat,
        width: CGFloat = 340,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(width: width)
        }
        .frame(width: width, height: max(maxHeight - 28, 1), alignment: .top)
    }

    func compactKnowledgeMain(horizontalPadding: CGFloat, topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HeaderStrip(model: model)
                    .panelStyle()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Knowledge")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    CompactStatusPill(text: "\(model.filteredKnowledgeEntries.count)")
                        .accessibilityLabel("\(model.filteredKnowledgeEntries.count) knowledge entries")
                }

                KnowledgeFilterBar(model: model)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, 12)

            Divider()
                .overlay(AppTheme.softSeparator)

            CompactActivityList(
                entries: model.filteredKnowledgeEntries,
                emptyTitle: "Memory and knowledge activity will appear here.",
                emptySystemImage: "tray.full"
            )
        }
    }

    func knowledgeMain(horizontalPadding: CGFloat, topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                title: "Knowledge",
                subtitle: "Search and group memory, reminders, dreams, and attention-related output.",
                model: model
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, 16)

            KnowledgeFilterBar(model: model)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 16)

            Divider()
                .overlay(AppTheme.softSeparator)

            EntriesList(
                entries: model.filteredKnowledgeEntries,
                emptyTitle: "Memory and knowledge activity will appear here.",
                brainRootURL: model.brain.rootURL
            )
        }
    }
}

struct BrainStatsWorkspace: View {
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    statsMain(horizontalPadding: 14, topPadding: 14, isCompact: true)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)

                    Divider()
                        .overlay(AppTheme.softSeparator)

                    compactStatsTools(maxHeight: compactToolsHeight(for: proxy.size.height))
                }
            }
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                statsMain(horizontalPadding: 16, topPadding: 12, isCompact: true)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        BrainNoteComposer(model: model)
                        BrainProfileSnapshotComposer(model: model)
                    }
                    .padding(12)
                }
                .frame(width: 320)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        } else {
            HStack(spacing: 0) {
                statsMain(horizontalPadding: 32, topPadding: 28, isCompact: false)

                Divider()
                    .overlay(AppTheme.softSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BrainNoteComposer(model: model)
                        BrainProfileSnapshotComposer(model: model)
                    }
                    .padding(24)
                }
                .frame(width: 390)
                .background(AppTheme.sidebarBackground.opacity(0.6))
            }
        }
    }

    func compactToolsHeight(for availableHeight: CGFloat) -> CGFloat {
        min(240, max(168, availableHeight * 0.26))
    }

    func compactStatsTools(maxHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                compactToolPanel(maxHeight: maxHeight, width: 290) {
                    BrainNoteComposer(model: model)
                }
                compactToolPanel(maxHeight: maxHeight, width: 320) {
                    BrainProfileSnapshotComposer(model: model)
                }
            }
            .padding(14)
        }
        .frame(height: maxHeight)
        .background(AppTheme.sidebarBackground.opacity(0.6))
    }

    func compactToolPanel<Content: View>(
        maxHeight: CGFloat,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .frame(width: width)
        }
        .frame(width: width, height: max(maxHeight - 28, 1), alignment: .top)
    }

    func statsMain(horizontalPadding: CGFloat, topPadding: CGFloat, isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            if isCompact {
                VStack(alignment: .leading, spacing: 12) {
                    HeaderStrip(model: model)
                        .panelStyle()

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Stats")
                            .font(.system(size: 23, weight: .semibold, design: .rounded))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        CompactStatusPill(text: model.currentBrainSizeText)
                            .accessibilityLabel("Current brain size \(model.currentBrainSizeText)")
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, 12)
            } else {
                WorkspaceHeader(
                    title: "Stats",
                    subtitle: "Track growth, timestamp notes, and periodically capture personality traits, goals, and recent memories.",
                    model: model
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, 16)
            }

            Divider()
                .overlay(AppTheme.softSeparator)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BrainSizeSummaryGrid(model: model)
                    BrainProfileTimeline(model: model)
                    BrainNotesTimeline(model: model)
                }
                .padding(horizontalSizeClass == .compact ? 14 : 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct BrainSizeSummaryGrid: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                PanelHeader(title: "Size", subtitle: "\(model.brainStats.sizeSnapshots.count) snapshots stored in this brain.")
                Spacer()
                Button {
                    model.recordBrainSizeSnapshotIfNeeded(force: true)
                } label: {
                    Label("Snapshot", systemImage: "camera.metering.matrix")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                BrainSizeMetricCard(title: "Now", value: model.currentBrainSizeText, subtitle: latestSizeSubtitle)
                BrainSizeMetricCard(title: "Day", value: changeText(.day), subtitle: changeSubtitle(.day))
                BrainSizeMetricCard(title: "Month", value: changeText(.month), subtitle: changeSubtitle(.month))
                BrainSizeMetricCard(title: "Year", value: changeText(.year), subtitle: changeSubtitle(.year))
            }
        }
        .panelStyle()
    }

    var latestSizeSubtitle: String {
        guard let latest = model.brainStats.latestSizeSnapshot else { return "No snapshot yet" }
        return latest.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    func changeText(_ period: BrainStatsPeriod) -> String {
        guard let change = model.brainStats.sizeChange(since: period.dateComponents) else { return "No data" }
        return BrainStatsFormatter.signedBytes(change.deltaBytes)
    }

    func changeSubtitle(_ period: BrainStatsPeriod) -> String {
        guard let change = model.brainStats.sizeChange(since: period.dateComponents) else { return period.title }
        return "since \(change.baselineDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct BrainSizeMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(10)
        .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }
}

struct BrainNoteComposer: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Note", subtitle: "Add a timestamped observation about this brain.")
            TextEditor(text: $model.brainNoteText)
                .font(.body)
                .foregroundStyle(AppTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 92)
                .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(model.brainNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.08) : AppTheme.accent.opacity(0.5))
                )

            Button {
                model.addBrainNote()
            } label: {
                Label("Post Note", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.brainNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .panelStyle()
        .keyboardDoneToolbar()
    }
}

struct BrainProfileSnapshotComposer: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Profile Snapshot", subtitle: "Periodically log traits, goals, and recent memories.")
            statsTextEditor("Major traits", text: $model.brainTraitsText)
            statsTextEditor("Goals", text: $model.brainGoalsText)
            statsTextEditor("Recent memories", text: $model.brainRecentMemoriesText)

            Button {
                model.addBrainProfileSnapshot()
            } label: {
                Label("Log Snapshot", systemImage: "person.text.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .panelStyle()
        .keyboardDoneToolbar()
    }

    var canSave: Bool {
        !model.brainTraitsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.brainGoalsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.brainRecentMemoriesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func statsTextEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            TextEditor(text: text)
                .font(.body)
                .foregroundStyle(AppTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(minHeight: 66)
                .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .white.opacity(0.08) : AppTheme.accent.opacity(0.5))
                )
        }
    }
}

struct BrainProfileTimeline: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Profile Log", subtitle: "\(model.brainStats.profileSnapshots.count) periodic snapshots")
            if model.brainStats.profileSnapshots.isEmpty {
                EmptyStateCard(title: "Log traits, goals, and recent memories from the side panel.", systemImage: "person.text.rectangle")
            } else {
                ForEach(model.brainStats.sortedProfileSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.createdAt, format: .dateTime.month().day().year().hour().minute())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        profileLine("Traits", snapshot.traits)
                        profileLine("Goals", snapshot.goals)
                        profileLine("Memories", snapshot.recentMemories)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .panelStyle()
    }

    func profileLine(_ title: String, _ value: String) -> some View {
        Group {
            if !value.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct BrainNotesTimeline: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Notes", subtitle: "\(model.brainStats.notes.count) timestamped notes")
            if model.brainStats.notes.isEmpty {
                EmptyStateCard(title: "Timestamped brain notes will appear here.", systemImage: "note.text")
            } else {
                ForEach(model.brainStats.sortedNotes) { note in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(note.createdAt, format: .dateTime.month().day().year().hour().minute())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(note.body)
                            .font(.callout)
                            .foregroundStyle(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .panelStyle()
    }
}

enum BrainStatsPeriod {
    case day
    case month
    case year

    var title: String {
        switch self {
        case .day: "past day"
        case .month: "past month"
        case .year: "past year"
        }
    }

    var dateComponents: DateComponents {
        switch self {
        case .day: DateComponents(day: -1)
        case .month: DateComponents(month: -1)
        case .year: DateComponents(year: -1)
        }
    }
}

struct WorkspaceHeader: View {
    let title: String
    let subtitle: String
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderStrip(model: model)

            titleText
        }
    }

    var titleText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: horizontalSizeClass == .compact ? 25 : 30, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SidebarBrainPanel: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidebarChatAvatar(
                brain: model.brain,
                eyeSprite: model.avatarEyeSprite,
                mouthSprite: model.avatarMouthSprite
            )
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.workspaceBrainTitle)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text("Chat with the selected brain and choose how much autonomy it has.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HeaderStrip(model: model)
        }
    }
}

struct SidebarChatAvatar: View {
    static let compactMaxHeight: CGFloat = 82

    let brain: BrainDescriptor
    var eyeSprite: String? = nil
    var mouthSprite: String? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Color.clear
            .aspectRatio(brain.avatarClipAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: maxAvatarHeight)
            .overlay {
                BrainAvatar(
                    brain: brain,
                    sizing: .fillContainer,
                    eyeSprite: eyeSprite,
                    mouthSprite: mouthSprite
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var maxAvatarHeight: CGFloat? {
        horizontalSizeClass == .compact ? Self.compactMaxHeight : nil
    }
}
