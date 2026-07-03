//
//  ContentView.swift
//  Affective
//
//  Created by Zelda Hessler on 6/24/26.
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

struct ContentView: View {
    @StateObject private var library = BrainLibrary()
    @StateObject private var syncManager = BrainSyncManager()
    @State private var selectedBrain: BrainDescriptor?
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCompleteCredentialWelcome = AffectiveViewModel.hasAnyProviderCredential()
    @AppStorage("Affective.didBypassCredentialWelcome") private var didBypassCredentialWelcome = false

    var body: some View {
        rootContent
        .animation(.smooth(duration: 0.25), value: selectedBrain?.id)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear {
            if AffectiveViewModel.hasAnyProviderCredential() {
                didCompleteCredentialWelcome = true
            }
            #if DEBUG
            if let uiTestBrain = AffectiveUITestHarness.brainToOpenIfNeeded(from: library.recencySortedBrains) {
                didCompleteCredentialWelcome = true
                library.markOpened(uiTestBrain)
                selectedBrain = uiTestBrain
                return
            }
            #endif
            syncManager.syncOnAppStart(brains: library.recencySortedBrains)
            openPendingAppIntentBrain()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                syncManager.uploadOnCloseIfNeeded(selectedBrain)
            } else {
                openPendingAppIntentBrain()
            }
        }
        .onChange(of: selectedBrain?.id) { oldValue, newValue in
            if newValue == nil, let oldValue, let brain = library.brains.first(where: { $0.id == oldValue }) {
                syncManager.uploadOnCloseIfNeeded(brain)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AffectiveAppIntentBridge.requestNotification)) { _ in
            openPendingAppIntentBrain()
        }
        .onReceive(NotificationCenter.default.publisher(for: BrainLibrary.avatarDidUpdateNotification)) { notification in
            reloadAvatarIfNeeded(from: notification)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if !didCompleteCredentialWelcome && !didBypassCredentialWelcome {
            APIKeyWelcomeView(
                continueToApp: {
                    finishCredentialWelcome()
                },
                bypass: {
                    finishCredentialWelcome(bypassed: true)
                }
            )
        } else if let brain = selectedBrain {
            AffectiveShellView(brain: brain) {
                selectedBrain = nil
            }
            .transition(.opacity)
        } else {
            WelcomeView(library: library, syncManager: syncManager) { brain in
                guard syncManager.canOpen(brain) else { return }
                library.markOpened(brain)
                selectedBrain = brain
            }
            .transition(.opacity)
        }
    }

    private func reloadAvatarIfNeeded(from notification: Notification) {
        guard let brainID = notification.userInfo?[BrainLibrary.avatarDidUpdateBrainIDKey] as? String else {
            return
        }
        library.refresh()
        guard selectedBrain?.id == brainID else { return }
        selectedBrain = library.brains.first { $0.id == brainID }
    }

    private func finishCredentialWelcome(bypassed: Bool = false) {
        if bypassed {
            didBypassCredentialWelcome = true
        }
        didCompleteCredentialWelcome = true
        openPendingAppIntentBrain(credentialWelcomeIsComplete: true)
    }

    private func openPendingAppIntentBrain() {
        openPendingAppIntentBrain(
            credentialWelcomeIsComplete: Self.canConsumePendingAppIntent(
                didCompleteCredentialWelcome: didCompleteCredentialWelcome,
                didBypassCredentialWelcome: didBypassCredentialWelcome
            )
        )
    }

    private func openPendingAppIntentBrain(credentialWelcomeIsComplete: Bool) {
        guard credentialWelcomeIsComplete else { return }
        library.refresh()
        guard let requestedID = AffectiveAppIntentBridge.pendingBrainID() else { return }
        guard
            let brain = AffectiveAppIntentBridge.requestedBrain(
                from: library.recencySortedBrains,
                requestedID: requestedID
            ),
            syncManager.canOpen(brain)
        else {
            return
        }
        library.markOpened(brain)
        AffectiveAppIntentBridge.recordOpenedBrain(id: brain.id)
        AffectiveAppIntentBridge.clearPendingBrainID()
        selectedBrain = brain
    }

    static func canConsumePendingAppIntent(
        didCompleteCredentialWelcome: Bool,
        didBypassCredentialWelcome: Bool
    ) -> Bool {
        didCompleteCredentialWelcome || didBypassCredentialWelcome
    }
}

private struct AffectiveShellView: View {
    let brain: BrainDescriptor
    let onCloseBrain: () -> Void
    @StateObject private var model: AffectiveViewModel
    @FocusState private var composerFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(brain: BrainDescriptor, onCloseBrain: @escaping () -> Void) {
        self.brain = brain
        self.onCloseBrain = onCloseBrain
        AppTheme.applyTheme(for: brain)
        #if DEBUG
        let viewModel = AffectiveViewModel(
            brain: brain,
            brainCore: AffectiveUITestHarness.brainCoreIfNeeded()
        )
        AffectiveUITestHarness.configure(viewModel)
        _model = StateObject(wrappedValue: viewModel)
        #else
        _model = StateObject(wrappedValue: AffectiveViewModel(brain: brain))
        #endif
    }

    var body: some View {
        ZStack {
            shell

            if model.showsCoreConnectingScreen {
                CoreConnectingScreen(model: model)
                    .transition(.opacity)
            }

            if model.showsHostPipelineDeadlockOverlay, let deadlock = model.hostPipelineDeadlock {
                HostPipelineDeadlockOverlay(deadlock: deadlock) {
                    model.dismissHostPipelineDeadlockOverlay()
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .animation(.smooth(duration: 0.2), value: model.showsCoreConnectingScreen)
        .animation(.smooth(duration: 0.2), value: model.showsHostPipelineDeadlockOverlay)
        .onChange(of: brain) { _, updated in
            AppTheme.applyTheme(for: updated)
            model.reloadBrain(updated)
        }
        .alert(item: $model.orientationPermissionPrompt) { prompt in
            Alert(
                title: Text("Allow Orientation Sense?"),
                message: Text(prompt.reason),
                primaryButton: .default(Text("Allow")) {
                    model.resolveOrientationPermission(true)
                },
                secondaryButton: .cancel(Text("Not Now")) {
                    model.resolveOrientationPermission(false)
                }
            )
        }
        .task {
            await model.connectToBrain()
        }
        .onAppear {
            model.refreshAppIsForeground()
            #if os(macOS)
            model.installMacForegroundObserversIfNeeded()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            model.setScenePhaseActive(phase == .active)
        }
    }

    @ViewBuilder
    private var shell: some View {
        if horizontalSizeClass == .compact {
            VStack(spacing: 0) {
                CompactShellHeader(closeBrain: closeBrain)

                Divider()
                    .overlay(AppTheme.softSeparator)

                WorkspaceDetail(model: model, composerFocused: $composerFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !composerFocused {
                    Divider()
                        .overlay(AppTheme.softSeparator)

                    CompactWorkspaceBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.18), value: composerFocused)
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                CompactWorkspaceRail(model: model)

                Divider()
                    .overlay(AppTheme.softSeparator)

                WorkspaceDetail(model: model, composerFocused: $composerFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            desktopShell
        }
    }

    func closeBrain() {
        Task {
            await model.disconnectFromBrain()
            onCloseBrain()
        }
    }

    private var desktopShell: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(model: model, closeBrain: closeBrain)
                .frame(width: 260)

            Divider()
                .overlay(AppTheme.softSeparator)

            WorkspaceDetail(model: model, composerFocused: $composerFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CompactWorkspaceRail: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(WorkspaceSection.allCases) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(model.selectedSection == section ? AppTheme.accent : AppTheme.secondaryText)
                            .background(model.selectedSection == section ? AppTheme.activePanelBackground : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        if section == .mailbox && model.unreadMailboxItemCount > 0 {
                            Text("\(model.unreadMailboxItemCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textOnAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AppTheme.accent, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(model.selectedSection == section ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(AppTheme.sidebarBackground)
    }
}

private struct CompactShellHeader: View {
    let closeBrain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: closeBrain) {
                Label("Projects", systemImage: "chevron.left")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Return to Projects")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppTheme.sidebarBackground.opacity(0.72))
    }
}

private struct CompactWorkspaceBar: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceSection.allCases) { section in
                Button {
                    model.selectedSection = section
                } label: {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            Image(systemName: section.symbolName)
                                .font(.system(size: 17, weight: .semibold))
                            Text(section.rawValue)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(model.selectedSection == section ? AppTheme.accent : AppTheme.secondaryText)

                        if section == .mailbox && model.unreadMailboxItemCount > 0 {
                            Text("\(model.unreadMailboxItemCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.textOnAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AppTheme.accent, in: Capsule())
                                .padding(.trailing, 8)
                                .padding(.top, 4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
                .accessibilityAddTraits(model.selectedSection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .background(AppTheme.sidebarBackground)
    }
}
