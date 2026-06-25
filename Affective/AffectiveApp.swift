//
//  AffectiveApp.swift
//  Affective
//
//  Created by Zelda Hessler on 6/24/26.
//

import SwiftUI

@main
struct AffectiveApp: App {
    var body: some Scene {
        mainWindow
        #if os(macOS)
        avatarEditorWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .configureWindow(minSize: NSSize(width: 900, height: 620))
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 860)
        .commands {
            AvatarEditorCommands()
        }
        #endif
    }

    #if os(macOS)
    private var avatarEditorWindow: some Scene {
        WindowGroup("Avatar Editor", id: "avatar-editor", for: String.self) { $brainID in
            AvatarEditorWindow(brainID: brainID?.isEmpty == false ? brainID : nil)
                .configureWindow(minSize: NSSize(width: 1060, height: 760))
        }
        .defaultSize(width: 1120, height: 780)
    }
    #endif
}

#if os(macOS)
private struct WindowConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(view.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.minSize = minSize
        window.contentMinSize = minSize
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
}

private extension View {
    func configureWindow(minSize: NSSize) -> some View {
        background(WindowConfigurator(minSize: minSize))
    }
}

private struct AvatarEditorCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AffectiveViewModel.lastOpenedBrainIDKey) private var lastOpenedBrainID = ""

    var body: some Commands {
        CommandMenu("View") {
            Button("Avatar Editor") {
                openWindow(id: "avatar-editor", value: lastOpenedBrainID)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
#endif
