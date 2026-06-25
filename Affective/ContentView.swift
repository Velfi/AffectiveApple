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
        Group {
            if !didCompleteCredentialWelcome && !didBypassCredentialWelcome {
                APIKeyWelcomeView(
                    continueToApp: {
                        finishCredentialWelcome()
                    },
                    bypass: {
                        finishCredentialWelcome(bypassed: true)
                    }
                )
            } else if let selectedBrain {
                AffectiveShellView(brain: selectedBrain)
            } else {
                WelcomeView(library: library, syncManager: syncManager) { brain in
                    guard syncManager.canOpen(brain) else { return }
                    library.markOpened(brain)
                    selectedBrain = brain
                }
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .preferredColorScheme(.dark)
        .onAppear {
            if AffectiveViewModel.hasAnyProviderCredential() {
                didCompleteCredentialWelcome = true
            }
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
    @StateObject private var model: AffectiveViewModel
    @FocusState private var composerFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(brain: BrainDescriptor) {
        _model = StateObject(wrappedValue: AffectiveViewModel(brain: brain))
    }

    var body: some View {
        shell
            .background(AppTheme.background)
            .foregroundStyle(AppTheme.primaryText)
            .preferredColorScheme(.dark)
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
    }

    @ViewBuilder
    private var shell: some View {
        if horizontalSizeClass == .compact {
            VStack(spacing: 0) {
                WorkspaceDetail(model: model, composerFocused: $composerFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !composerFocused {
                    Divider()
                        .overlay(.white.opacity(0.06))

                    CompactWorkspaceBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.18), value: composerFocused)
        } else if verticalSizeClass == .compact {
            HStack(spacing: 0) {
                CompactWorkspaceRail(model: model)

                Divider()
                    .overlay(.white.opacity(0.06))

                WorkspaceDetail(model: model, composerFocused: $composerFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            desktopShell
        }
    }

    private var desktopShell: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(model: model)
                .frame(width: 260)

            Divider()
                .overlay(.white.opacity(0.05))

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

                        if section == .mailbox && model.unreadDreamReportCount > 0 {
                            Text("\(model.unreadDreamReportCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.black.opacity(0.86))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(AppTheme.accent, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.rawValue)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(AppTheme.sidebarBackground)
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

                        if section == .mailbox && model.unreadDreamReportCount > 0 {
                            Text("\(model.unreadDreamReportCount)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.black.opacity(0.86))
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
            }
        }
        .padding(.horizontal, 4)
        .background(AppTheme.sidebarBackground)
    }
}
