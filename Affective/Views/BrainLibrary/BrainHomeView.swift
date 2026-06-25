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

struct WelcomeView: View {
    @ObservedObject var library: BrainLibrary
    @ObservedObject var syncManager: BrainSyncManager
    let openBrain: (BrainDescriptor) -> Void
    @State private var selectedBrainID: BrainDescriptor.ID?
    @State private var statusText = ""
    @State private var isCreatingBrain = false
    @State private var isImportingBrainFile = false
    @State private var brainBeingRenamed: BrainDescriptor?
    @State private var brainPendingDeletion: BrainDescriptor?
    @State private var brainPendingSyncSelection: BrainDescriptor?
    @State private var sharedBrainExport: SharedBrainExport?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var selectedBrain: BrainDescriptor? {
        library.brains.first { $0.id == selectedBrainID } ?? library.brains.first
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact && verticalSizeClass == .compact {
                compactLandscapeBody
            } else if horizontalSizeClass == .compact {
                compactBody
            } else {
                desktopBody
            }
        }
        .onAppear {
            refreshBrainManager(syncCloudBrain: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshBrainManager(syncCloudBrain: true)
            }
        }
        .fileImporter(
            isPresented: $isImportingBrainFile,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            importBrainFile(result)
        }
        #if canImport(UIKit)
        .sheet(item: $sharedBrainExport) { export in
            ActivityView(activityItems: [export.url]) {
                cleanupSharedBrainExport(at: export.url)
            }
                .ignoresSafeArea()
        }
        #endif
        .sheet(isPresented: $isCreatingBrain) {
            BrainCreationSheet { request in
                do {
                    let brain = try library.createBrain(request)
                    selectedBrainID = brain.id
                    statusText = "Created \(brain.displayName)."
                    isCreatingBrain = false
                } catch {
                    statusText = "Create failed: \(error.localizedDescription)"
                    throw error
                }
            }
        }
        .sheet(item: $brainBeingRenamed) { brain in
            BrainRenameSheet(brain: brain) { newName in
                do {
                    let renamed = try library.renameBrain(brain, to: newName)
                    selectedBrainID = renamed.id
                    statusText = "Renamed \(renamed.displayName)."
                    brainBeingRenamed = nil
                } catch {
                    statusText = "Rename failed: \(error.localizedDescription)"
                    throw error
                }
            }
        }
        .confirmationDialog(
            "Sync this brain with iCloud?",
            isPresented: Binding(
                get: { brainPendingSyncSelection != nil },
                set: { if !$0 { brainPendingSyncSelection = nil } }
            ),
            presenting: brainPendingSyncSelection
        ) { brain in
            Button("Sync \(brain.displayName)") {
                syncManager.selectBrainForSync(brain)
                selectedBrainID = brain.id
                brainPendingSyncSelection = nil
            }
            Button("Cancel", role: .cancel) {
                brainPendingSyncSelection = nil
            }
        } message: { brain in
            if let syncedBrainID = syncManager.syncedBrainID, syncedBrainID != brain.id {
                Text("Affective can sync one brain at a time. This will stop syncing the current brain and make \(brain.displayName) the iCloud brain.")
            } else {
                Text("Affective will keep this brain's experiential record in iCloud and sync it on app start.")
            }
        }
        .confirmationDialog(
            "Delete \(brainPendingDeletion?.displayName ?? "Brain")?",
            isPresented: Binding(
                get: { brainPendingDeletion != nil },
                set: { if !$0 { brainPendingDeletion = nil } }
            ),
            presenting: brainPendingDeletion
        ) { brain in
            Button("Delete \(brain.displayName)", role: .destructive) {
                deleteBrain(brain)
            }
            Button("Cancel", role: .cancel) {
                brainPendingDeletion = nil
            }
        } message: { brain in
            Text("This removes the local brain folder and cannot be undone. Export \(brain.displayName) first if you want a backup.")
        }
    }

    var desktopBody: some View {
        HStack(spacing: 0) {
            welcomeSidebar
            .padding(.horizontal, 44)
            .padding(.vertical, 44)
            .frame(width: 430, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(AppTheme.sidebarBackground)

            Divider()
                .overlay(.white.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    BrainSection(
                        title: "Projects",
                        emptyText: "Create a new brain or import an existing folder.",
                        brains: library.recencySortedBrains,
                        selectedBrainID: $selectedBrainID,
                        syncManager: syncManager,
                        openBrain: openBrain,
                        syncBrain: requestSyncSelection,
                        useICloudBrain: { syncManager.resolveConflictUsingICloud($0, library: library) },
                        renameBrain: { brainBeingRenamed = $0 },
                        chooseAvatar: chooseAvatar,
                        relocateBrain: relocateBrain,
                        exportBrain: exportBrain,
                        exportBrainZip: exportBrainZip,
                        deleteBrain: requestDeleteBrain
                    )
                }
                .padding(36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.controlBackground)
        }
    }

    var compactBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                welcomeSidebar

                BrainSection(
                    title: "Projects",
                    emptyText: "Create a new brain or import an existing folder.",
                    brains: library.recencySortedBrains,
                    selectedBrainID: $selectedBrainID,
                    syncManager: syncManager,
                    openBrain: openBrain,
                    syncBrain: requestSyncSelection,
                    useICloudBrain: { syncManager.resolveConflictUsingICloud($0, library: library) },
                    renameBrain: { brainBeingRenamed = $0 },
                    chooseAvatar: chooseAvatar,
                    relocateBrain: relocateBrain,
                    exportBrain: exportBrain,
                    exportBrainZip: exportBrainZip,
                    deleteBrain: requestDeleteBrain
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.controlBackground)
    }

    var compactLandscapeBody: some View {
        HStack(spacing: 0) {
            ScrollView {
                welcomeSidebar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 310)
            .background(AppTheme.sidebarBackground)

            Divider()
                .overlay(.white.opacity(0.06))

            ScrollView {
                BrainSection(
                    title: "Projects",
                    emptyText: "Create a new brain or import an existing folder.",
                    brains: library.recencySortedBrains,
                    selectedBrainID: $selectedBrainID,
                    syncManager: syncManager,
                    openBrain: openBrain,
                    syncBrain: requestSyncSelection,
                    useICloudBrain: { syncManager.resolveConflictUsingICloud($0, library: library) },
                    renameBrain: { brainBeingRenamed = $0 },
                    chooseAvatar: chooseAvatar,
                    relocateBrain: relocateBrain,
                    exportBrain: exportBrain,
                    exportBrainZip: exportBrainZip,
                    deleteBrain: requestDeleteBrain
                )
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.controlBackground)
        }
    }

    var welcomeSidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Affective")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("Choose a brain to wake or create a new one.")
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    isCreatingBrain = true
                } label: {
                    Label("New Brain", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                ViewThatFits(in: .horizontal) {
                    importActions(isStacked: false)
                    importActions(isStacked: true)
                }
            }
            .frame(maxWidth: 360)

            StatusNoteCard(
                text: statusText.isEmpty ? library.statusText : statusText,
                systemImage: statusSymbolName,
                tint: statusTint
            )
            .contentShape(Rectangle())
            .onTapGesture {
                copyStatusErrorToClipboard()
            }
            .help(canCopyStatusError ? "Copy error to clipboard" : "")
            .accessibilityAction(named: "Copy error") {
                copyStatusErrorToClipboard()
            }
            .frame(maxWidth: 360, alignment: .leading)

            if horizontalSizeClass != .compact {
                Spacer()
            }

            BuildBadgeView()
        }
    }

    func importActions(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    importBrainButton
                    importCloudBrainButton
                }
            } else {
                HStack(spacing: 10) {
                    importBrainButton
                    importCloudBrainButton
                }
            }
        }
    }

    var importBrainButton: some View {
        Button {
            importBrain()
        } label: {
            Label("Import Brain", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    var importCloudBrainButton: some View {
        if let cloudBrain = syncManager.importableCloudBrains.first {
            Button {
                importCloudBrain(cloudBrain)
            } label: {
                Label("Import Brain (iCloud)", systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(.bordered)
        } else if let cloudImport = syncManager.unavailableCloudImports.first {
            Button {
                explainUnavailableCloudImport(cloudImport)
            } label: {
                Label("Import Brain (iCloud)", systemImage: "exclamationmark.icloud")
            }
            .buttonStyle(.bordered)
            .help(cloudImport.state.statusTitle)
        }
    }

    var statusSymbolName: String {
        let text = statusText.isEmpty ? library.statusText : statusText
        if text.localizedCaseInsensitiveContains("failed") || text.localizedCaseInsensitiveContains("error") {
            return "exclamationmark.triangle"
        }
        if text.localizedCaseInsensitiveContains("importing") {
            return "icloud.and.arrow.down"
        }
        if text.localizedCaseInsensitiveContains("created") || text.localizedCaseInsensitiveContains("deleted") || text.localizedCaseInsensitiveContains("imported") || text.localizedCaseInsensitiveContains("exported") || text.localizedCaseInsensitiveContains("updated") {
            return "checkmark.circle"
        }
        return "info.circle"
    }

    var statusTint: Color {
        let text = statusText.isEmpty ? library.statusText : statusText
        if text.localizedCaseInsensitiveContains("failed") || text.localizedCaseInsensitiveContains("error") {
            return .orange
        }
        if text.localizedCaseInsensitiveContains("created") || text.localizedCaseInsensitiveContains("deleted") || text.localizedCaseInsensitiveContains("imported") || text.localizedCaseInsensitiveContains("exported") || text.localizedCaseInsensitiveContains("updated") {
            return AppTheme.accent
        }
        return AppTheme.secondaryText
    }

    var currentStatusText: String {
        statusText.isEmpty ? library.statusText : statusText
    }

    var canCopyStatusError: Bool {
        currentStatusText.localizedCaseInsensitiveContains("failed")
            || currentStatusText.localizedCaseInsensitiveContains("error")
    }

    func copyStatusErrorToClipboard() {
        guard canCopyStatusError else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentStatusText, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = currentStatusText
        #endif
    }

    func refreshBrainManager(syncCloudBrain: Bool = false) {
        library.refresh()
        if let selectedBrainID, !library.brains.contains(where: { $0.id == selectedBrainID }) {
            self.selectedBrainID = library.recencySortedBrains.first?.id
        } else {
            selectedBrainID = selectedBrainID ?? library.recencySortedBrains.first?.id
        }
        statusText = library.statusText

        if syncCloudBrain {
            syncManager.syncOnAppStart(brains: library.recencySortedBrains)
        }
        syncManager.refreshCloudImports(installedBrains: library.recencySortedBrains)
    }

    func requestSyncSelection(_ brain: BrainDescriptor) {
        if syncManager.syncedBrainID == brain.id || syncManager.syncedBrainID == nil {
            syncManager.selectBrainForSync(brain)
            selectedBrainID = brain.id
        } else {
            brainPendingSyncSelection = brain
        }
    }

    func requestDeleteBrain(_ brain: BrainDescriptor) {
        selectedBrainID = brain.id
        brainPendingDeletion = brain
    }

    func deleteBrain(_ brain: BrainDescriptor) {
        do {
            syncManager.stopSyncingDeletedBrain(brain)
            try library.deleteBrain(brain)
            if selectedBrainID == brain.id {
                selectedBrainID = library.recencySortedBrains.first?.id
            }
            brainPendingDeletion = nil
            statusText = "Deleted \(brain.displayName)."
            syncManager.refreshCloudImports(installedBrains: library.recencySortedBrains)
        } catch {
            brainPendingDeletion = nil
            statusText = "Delete failed: \(error.localizedDescription)"
        }
    }

    func importBrain() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import Brain"
        panel.prompt = "Import"
        panel.message = "Choose an exported Affective brain folder or zip archive."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let brain = try library.importBrain(from: url)
            selectedBrainID = brain.id
            statusText = "Imported \(brain.displayName)."
        } catch {
            statusText = "Import failed: \(error.localizedDescription)"
        }
        #else
        isImportingBrainFile = true
        #endif
    }

    func importBrainFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let brain = try library.importBrain(from: url)
            selectedBrainID = brain.id
            statusText = "Imported \(brain.displayName)."
        } catch {
            statusText = "Import failed: \(error.localizedDescription)"
        }
    }

    func importCloudBrain(_ manifest: BrainCloudManifest) {
        statusText = "Importing \(manifest.displayName) from iCloud..."
        Task {
            do {
                let brain = try await syncManager.importCloudBrain(manifest, library: library)
                selectedBrainID = brain.id
                statusText = "Imported \(brain.displayName) from iCloud."
                syncManager.refreshCloudImports(installedBrains: library.recencySortedBrains)
            } catch {
                statusText = cloudImportFailureStatus(for: error)
            }
        }
    }

    func explainUnavailableCloudImport(_ cloudImport: BrainCloudImport) {
        statusText = "\(cloudImport.manifest.displayName) is not ready to import from iCloud: \(cloudImport.state.statusTitle).\n\(cloudImport.state.explanation)"
        syncManager.refreshCloudImports(installedBrains: library.recencySortedBrains)
    }

    func cloudImportFailureStatus(for error: Error) -> String {
        let reason = error.localizedDescription
        let suggestion = (error as? LocalizedError)?.recoverySuggestion
            ?? "Check that iCloud Drive is enabled and has finished syncing, then try Import Brain (iCloud) again. You can also use Import Brain with a local export."
        return "iCloud import failed: \(reason)\n\(suggestion)"
    }

    func exportBrain(_ brain: BrainDescriptor) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Export Brain"
        panel.prompt = "Export Here"
        panel.message = "Choose a destination folder for \(brain.displayName)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            selectedBrainID = brain.id
            let exportedURL = try library.exportBrainFolder(brain, to: destination)
            statusText = "Exported to \(exportedURL.lastPathComponent)."
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
        #else
        statusText = "Brain folder export is macOS-only for this host."
        #endif
    }

    func exportBrainZip(_ brain: BrainDescriptor) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Brain ZIP"
        panel.prompt = "Export"
        panel.message = "Choose where to save a zipped export of \(brain.displayName)."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(brain.id).affectivebrain.zip"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            selectedBrainID = brain.id
            let exportedURL = try library.exportBrainZip(brain, to: destination)
            statusText = "Exported to \(exportedURL.lastPathComponent)."
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
        #else
        shareBrainZip(brain)
        #endif
    }

    func shareBrainZip(_ brain: BrainDescriptor) {
        do {
            selectedBrainID = brain.id
            let shareDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AffectiveBrainShare-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
            let destination = shareDirectory.appendingPathComponent("\(brain.id).affectivebrain.zip")
            let exportedURL = try library.exportBrainZip(brain, to: destination)
            sharedBrainExport = SharedBrainExport(url: exportedURL)
            statusText = "Prepared \(exportedURL.lastPathComponent) for sharing."
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
    }

    func cleanupSharedBrainExport(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        sharedBrainExport = nil
    }

    func chooseAvatar(for brain: BrainDescriptor) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Avatar"
        panel.prompt = "Use Avatar"
        panel.message = "Choose a PNG or JPEG image for \(brain.displayName)."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            selectedBrainID = brain.id
            let updated = try library.setAvatar(for: brain, from: url)
            selectedBrainID = updated.id
            statusText = "Updated \(updated.displayName)'s avatar."
        } catch {
            statusText = "Avatar failed: \(error.localizedDescription)"
        }
        #else
        statusText = "Avatar selection is macOS-only for this host."
        #endif
    }

    func relocateBrain(_ brain: BrainDescriptor) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Move Brain"
        panel.prompt = "Move Here"
        panel.message = "Choose a destination folder for \(brain.displayName). Moving outside Affective's managed brains folder removes it from the installed list."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            selectedBrainID = brain.id
            let movedURL = try library.relocateBrain(brain, to: destination)
            selectedBrainID = library.recencySortedBrains.first?.id
            statusText = "Moved to \(movedURL.path)."
        } catch {
            statusText = "Move failed: \(error.localizedDescription)"
        }
        #else
        statusText = "Brain relocation is macOS-only for this host."
        #endif
    }
}
