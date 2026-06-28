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

struct ComposerPanel: View {
    @ObservedObject var model: AffectiveViewModel
    var composerFocused: FocusState<Bool>.Binding
    var isCompact = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    var body: some View {
        VStack(spacing: isCompact ? 6 : 8) {
            if showsInlineAutonomy {
                InlineAutonomyControls(model: model, isCompact: isCompact)
            }

            HStack(alignment: .center, spacing: isCompact ? 6 : 8) {
                if isCompact {
                    PokeButton(model: model)
                } else {
                    WakeButton(model: model, size: controlSize)
                }

                BrainVoiceToggleButton(model: model)

                photoButton

                composerInput

                interruptButton

                sendButton
            }
        }
        .padding(isCompact ? 6 : 7)
        .background(AppTheme.composerBackground, in: RoundedRectangle(cornerRadius: isCompact ? 22 : 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isCompact ? 22 : 24, style: .continuous)
                .stroke(composerFocused.wrappedValue ? AppTheme.accent.opacity(0.34) : AppTheme.separator, lineWidth: 1)
        )
        .shadow(color: AppTheme.ambientShadow, radius: 18, y: 8)
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await loadPickedPhoto(item)
            }
        }
        #endif
    }

    @ViewBuilder
    var photoButton: some View {
        #if canImport(PhotosUI)
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: isCompact ? 17 : 18, weight: .bold))
                .frame(width: controlSize, height: controlSize)
                .background(AppTheme.panelBackground, in: Circle())
                .foregroundStyle(AppTheme.secondaryText)
                .overlay(Circle().stroke(AppTheme.separator))
                .hitTarget()
        }
        .accessibilityLabel("Send picture")
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    var composerInput: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            MacComposerTextView(
                text: $model.messageText,
                isFocused: composerFocused,
                onSubmit: submitMessage,
                onTextChanged: markInputActivity
            )

            if model.messageText.isEmpty {
                Text("Message Affective")
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.72))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 7 : 9)
        .frame(minHeight: isCompact ? 34 : 40, maxHeight: isCompact ? 76 : 96, alignment: .topLeading)
        .layoutPriority(1)
        #else
        TextField("Message Affective", text: $model.messageText, axis: .vertical)
            .lineLimit(1...(isCompact ? 3 : 4))
            .submitLabel(.send)
            .onSubmit(submitMessage)
            .font(.body)
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, isCompact ? 8 : 10)
            .padding(.vertical, isCompact ? 7 : 9)
            .frame(minHeight: isCompact ? 34 : 40, maxHeight: isCompact ? 76 : 96, alignment: .topLeading)
            .focused(composerFocused)
            .layoutPriority(1)
            .onChange(of: model.messageText) { _, _ in
                markInputActivity()
            }
        #endif
    }

    @ViewBuilder
    var interruptButton: some View {
        if model.canInterruptUserMessage {
            Button {
                submitInterruptMessage()
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: controlSize, height: controlSize)
                    .background(canSubmit ? AppTheme.activePanelBackground : AppTheme.panelBackground, in: Circle())
                    .foregroundStyle(canSubmit ? AppTheme.accent : AppTheme.secondaryText)
                    .overlay(Circle().stroke(AppTheme.separator))
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .accessibilityLabel("Interrupt with message")
            .help("Interrupt current work with this message")
        }
    }

    var sendButton: some View {
        Button {
            submitMessage()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: isCompact ? 16 : 17, weight: .bold))
                .frame(width: controlSize, height: controlSize)
                .background(canSubmit ? AppTheme.accent : AppTheme.panelBackground, in: Circle())
                .foregroundStyle(canSubmit ? AppTheme.textOnAccent : AppTheme.secondaryText)
                .hitTarget()
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel("Send message")
    }

    var canSubmit: Bool {
        model.canSend &&
            !model.isBrainUnavailableForConversation &&
            !model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var controlSize: CGFloat {
        isCompact ? 34 : 36
    }

    var showsInlineAutonomy: Bool {
        !isCompact || !composerFocused.wrappedValue
    }

    func submitMessage() {
        guard canSubmit else { return }
        model.sendText()
        composerFocused.wrappedValue = false
    }

    func submitInterruptMessage() {
        guard canSubmit else { return }
        model.sendText(interrupt: true)
        composerFocused.wrappedValue = false
    }

    func markInputActivity() {
        DispatchQueue.main.async {
            model.markInputActivity()
        }
    }

    #if canImport(PhotosUI)
    func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer {
            Task { @MainActor in
                selectedPhotoItem = nil
            }
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            await MainActor.run {
                model.sendImage(data: data, suggestedName: "photo-\(UUID().uuidString)")
            }
        } catch {
            await MainActor.run {
                model.reportImageSendFailure(error.localizedDescription)
            }
        }
    }
    #endif
}

#if os(macOS)
private struct MacComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onTextChanged: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }

        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }

        if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerTextView
        weak var textView: NSTextView?

        init(parent: MacComposerTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChanged()
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            insertNewlineIgnoringFieldEditor(self)
        } else {
            onSubmit?()
        }
    }
}
#endif

struct PokeButton: View {
    @ObservedObject var model: AffectiveViewModel
    @State private var isTouching = false

    var body: some View {
        pokeIcon
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .gesture(pokeGesture)
            .opacity(!model.canSend && !model.isPoking ? 0.56 : 1)
            .animation(.smooth(duration: 0.18), value: model.isPoking)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.isPoking ? "Release poke" : "Poke Affective")
            .accessibilityAction {
                if model.isPoking {
                    endTouch()
                } else {
                    beginTouch()
                    endTouch()
                }
            }
    }

    var pokeIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 17, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 36, height: 36)
            .background(backgroundColor, in: Circle())
            .foregroundStyle(foregroundColor)
            .overlay(Circle().stroke(.white.opacity(model.isPoking ? 0.22 : 0.08)))
    }

    var iconName: String {
        if model.isPoking { return "hand.tap.fill" }
        if isTouching { return "hand.point.up.left.fill" }
        return "hand.point.up.left"
    }

    var backgroundColor: Color {
        model.isPoking ? AppTheme.activePanelBackground : AppTheme.panelBackground
    }

    var foregroundColor: Color {
        model.isPoking ? AppTheme.accent : AppTheme.secondaryText
    }

    var pokeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard model.canSend || model.isPoking else { return }
                beginTouch()
            }
            .onEnded { _ in
                endTouch()
            }
    }

    func beginTouch() {
        guard !isTouching else { return }
        isTouching = true
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        model.beginPoke()
    }

    func endTouch() {
        guard isTouching else { return }
        isTouching = false
        model.endPoke()
    }
}
