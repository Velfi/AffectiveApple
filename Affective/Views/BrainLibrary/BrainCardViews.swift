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

struct BrainSection: View {
    let title: String
    let emptyText: String
    let brains: [BrainDescriptor]
    @Binding var selectedBrainID: BrainDescriptor.ID?
    @ObservedObject var syncManager: BrainSyncManager
    let openBrain: (BrainDescriptor) -> Void
    let syncBrain: (BrainDescriptor) -> Void
    let useICloudBrain: (BrainDescriptor) -> Void
    let renameBrain: (BrainDescriptor) -> Void
    let chooseAvatar: (BrainDescriptor) -> Void
    let relocateBrain: (BrainDescriptor) -> Void
    let exportBrain: (BrainDescriptor) -> Void
    let exportBrainZip: (BrainDescriptor) -> Void
    let deleteBrain: (BrainDescriptor) -> Void

    init(
        title: String,
        emptyText: String,
        brains: [BrainDescriptor],
        selectedBrainID: Binding<BrainDescriptor.ID?>,
        syncManager: BrainSyncManager,
        openBrain: @escaping (BrainDescriptor) -> Void,
        syncBrain: @escaping (BrainDescriptor) -> Void,
        useICloudBrain: @escaping (BrainDescriptor) -> Void,
        renameBrain: @escaping (BrainDescriptor) -> Void,
        chooseAvatar: @escaping (BrainDescriptor) -> Void,
        relocateBrain: @escaping (BrainDescriptor) -> Void,
        exportBrain: @escaping (BrainDescriptor) -> Void,
        exportBrainZip: @escaping (BrainDescriptor) -> Void,
        deleteBrain: @escaping (BrainDescriptor) -> Void
    ) {
        self.title = title
        self.emptyText = emptyText
        self.brains = brains
        _selectedBrainID = selectedBrainID
        self.syncManager = syncManager
        self.openBrain = openBrain
        self.syncBrain = syncBrain
        self.useICloudBrain = useICloudBrain
        self.renameBrain = renameBrain
        self.chooseAvatar = chooseAvatar
        self.relocateBrain = relocateBrain
        self.exportBrain = exportBrain
        self.exportBrainZip = exportBrainZip
        self.deleteBrain = deleteBrain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                CompactStatusPill(text: "\(brains.count)")
                    .accessibilityLabel("\(brains.count) projects")
            }

            if brains.isEmpty {
                EmptyStateCard(title: emptyText, systemImage: "brain.head.profile")
                    .padding(.vertical, 34)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(brains) { brain in
                        BrainCard(
                            brain: brain,
                            isSelected: selectedBrainID == brain.id,
                            syncState: syncManager.state(for: brain),
                            canOpen: syncManager.canOpen(brain),
                            select: { selectedBrainID = brain.id },
                            open: { openBrain(brain) },
                            sync: { syncBrain(brain) },
                            syncNow: { syncManager.syncNow(brain) },
                            useLocal: { syncManager.resolveConflictUsingLocal(brain) },
                            useICloud: { useICloudBrain(brain) },
                            rename: { renameBrain(brain) },
                            chooseAvatar: { chooseAvatar(brain) },
                            relocate: { relocateBrain(brain) },
                            export: { exportBrain(brain) },
                            exportZip: { exportBrainZip(brain) },
                            delete: { deleteBrain(brain) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SharedBrainExport: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                completion()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

struct BrainCard: View {
    let brain: BrainDescriptor
    let isSelected: Bool
    let syncState: BrainSyncState
    let canOpen: Bool
    let select: () -> Void
    let open: () -> Void
    let sync: () -> Void
    let syncNow: () -> Void
    let useLocal: () -> Void
    let useICloud: () -> Void
    let rename: () -> Void
    let chooseAvatar: () -> Void
    let relocate: () -> Void
    let export: () -> Void
    let exportZip: () -> Void
    let delete: () -> Void

    var body: some View {
        ZStack {
            HStack(alignment: .center, spacing: 14) {
                BrainAvatar(brain: brain)

                VStack(alignment: .leading, spacing: 5) {
                    Text(brain.displayName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                    Text(brain.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(modifiedText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        if let syncLabel = syncState.label {
                            Label(syncLabel, systemImage: syncIconName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(syncForegroundStyle)
                                .lineLimit(1)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: open) {
                    Label("Open", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canOpen)
                .help(canOpen ? "Open \(brain.displayName)" : "Wait for iCloud sync to finish")

                Menu {
                    Button {
                        select()
                        sync()
                    } label: {
                        Label("Sync this brain with iCloud", systemImage: "icloud")
                    }
                    Button {
                        select()
                        syncNow()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    if syncState == .conflict {
                        Divider()
                        Button {
                            select()
                            useLocal()
                        } label: {
                            Label("Use Local Brain", systemImage: "macbook")
                        }
                        Button {
                            select()
                            useICloud()
                        } label: {
                            Label("Use iCloud Brain", systemImage: "icloud.and.arrow.down")
                        }
                    }
                    Divider()
                    Button {
                        select()
                        rename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        select()
                        chooseAvatar()
                    } label: {
                        Label("Change Avatar", systemImage: "photo")
                    }
                    Button {
                        select()
                        relocate()
                    } label: {
                        Label("Relocate", systemImage: "folder")
                    }
                    Divider()
                    #if os(macOS)
                    Button {
                        select()
                        export()
                    } label: {
                        Label("Export Folder", systemImage: "folder")
                    }
                    Button {
                        select()
                        exportZip()
                    } label: {
                        Label("Export ZIP", systemImage: "doc.zipper")
                    }
                    #else
                    Button {
                        select()
                        exportZip()
                    } label: {
                        Label("Share Export", systemImage: "square.and.arrow.up")
                    }
                    #endif
                    Divider()
                    Button(role: .destructive) {
                        select()
                        delete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .help("Project actions")
            }
            if syncState.showsLoader {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.42))
                ProgressView {
                    Text(syncState.label ?? "Syncing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(isSelected ? AppTheme.activePanelBackground : AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? AppTheme.accent.opacity(0.75) : .white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: select)
        .onTapGesture(count: 2) {
            select()
            if canOpen {
                open()
            }
        }
    }

    var modifiedText: String {
        guard let modifiedAt = brain.modifiedAt else {
            return "No modification date"
        }
        return "Updated \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var syncIconName: String {
        switch syncState {
        case .notSynced:
            return "icloud.slash"
        case .checking:
            return "arrow.triangle.2.circlepath.icloud"
        case .downloading:
            return "icloud.and.arrow.down"
        case .uploading:
            return "icloud.and.arrow.up"
        case .synced:
            return "checkmark.icloud"
        case .conflict:
            return "exclamationmark.icloud"
        case .failed:
            return "xmark.icloud"
        }
    }

    var syncForegroundStyle: Color {
        switch syncState {
        case .synced:
            return AppTheme.accent
        case .conflict, .failed:
            return .orange
        case .checking, .downloading, .uploading:
            return AppTheme.primaryText
        case .notSynced:
            return AppTheme.secondaryText
        }
    }
}

struct BrainAvatar: View {
    let brain: BrainDescriptor
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.editorBackground)
            avatarContent
        }
        .frame(width: avatarSize.width, height: avatarSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.10))
        )
        .accessibilityLabel("\(brain.displayName) avatar")
    }

    var avatarSize: CGSize {
        let aspectRatio = brain.avatarManifest.map { manifest in
            let clip = manifest.effectiveClip
            let rawRatio = clip.width / max(clip.height, 1)
            return rawRatio.isFinite && rawRatio > 0 ? rawRatio : 1
        } ?? 1
        let safeSize = size.isFinite && size > 0 ? size : 58
        return CGSize(width: safeSize * aspectRatio, height: safeSize)
    }

    @ViewBuilder
    var avatarContent: some View {
        if let manifest = brain.avatarManifest {
            LayeredAvatarView(manifest: manifest)
        } else if let avatarURL = brain.avatarURL {
            #if os(macOS)
            if let image = NSImage(contentsOf: avatarURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackAvatar
            }
            #else
            fallbackAvatar
            #endif
        } else {
            fallbackAvatar
        }
    }

    var fallbackAvatar: some View {
        Image(systemName: "brain.head.profile")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
    }
}
