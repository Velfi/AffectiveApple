//
//  EmojiReactionPickerViews.swift
//  Affective
//

import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum EmojiReactionValidation {
    static func normalizedReaction(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16, trimmed.containsEmojiCharacter else { return nil }
        return trimmed
    }
}

private extension String {
    var containsEmojiCharacter: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmoji && (scalar.value > 0x238C || scalar.properties.isEmojiPresentation)
        }
    }
}

struct EmojiReactionPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        MacEmojiPickerRepresentable { emoji in
            onPick(emoji)
        }
        .padding(12)
        #else
        IOSEmojiReactionPicker(onPick: { emoji in
            onPick(emoji)
            dismiss()
        })
        #endif
    }
}

#if os(macOS)
private struct MacEmojiReactionPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick any emoji from the character palette or paste one below.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)

            TextField("", text: $draft)
                .font(.system(size: 28))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .frame(height: 52)
                .padding(.horizontal, 14)
                .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.separator)
                )

            Button("Open Emoji & Symbols") {
                NSApplication.shared.orderFrontCharacterPalette(nil)
            }
            .buttonStyle(.bordered)

            if let preview = EmojiReactionValidation.normalizedReaction(from: draft) {
                HStack(spacing: 8) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(preview)
                        .font(.largeTitle)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(EmojiReactionValidation.normalizedReaction(from: draft) == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        guard let normalized = EmojiReactionValidation.normalizedReaction(from: draft) else { return }
        onPick(normalized)
        dismiss()
    }
}

private struct MacEmojiPickerRepresentable: View {
    let onPick: (String) -> Void

    var body: some View {
        MacEmojiReactionPicker(onPick: onPick)
    }
}
#endif

#if canImport(UIKit) && !os(macOS)
private struct IOSEmojiReactionPicker: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose any emoji from the keyboard.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)

                EmojiTextField(text: $draft)
                    .frame(height: 52)
                    .padding(.horizontal, 14)
                    .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.separator)
                    )

                if let preview = EmojiReactionValidation.normalizedReaction(from: draft) {
                    HStack(spacing: 8) {
                        Text("Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text(preview)
                            .font(.largeTitle)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Add Reaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        submit()
                    }
                    .disabled(EmojiReactionValidation.normalizedReaction(from: draft) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard let normalized = EmojiReactionValidation.normalizedReaction(from: draft) else { return }
        onPick(normalized)
        dismiss()
    }
}

private struct EmojiTextField: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 28)
        field.textAlignment = .center
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if !context.coordinator.didBecomeFirstResponder {
            context.coordinator.didBecomeFirstResponder = true
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var didBecomeFirstResponder = false

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
#endif

struct AddReactionButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "face.smiling")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 24, height: 24)
                .background(AppTheme.panelBackground.opacity(0.92), in: Circle())
                .overlay(Circle().stroke(AppTheme.separator))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add reaction")
    }
}
