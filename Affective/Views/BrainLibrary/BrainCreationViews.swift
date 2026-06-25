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

struct BrainCreationSheet: View {
    let createBrain: (BrainCreationRequest) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var name = ""
    @State private var wants = [BrainSeedCard()]
    @State private var goals = [BrainSeedCard()]
    @State private var initialThoughts = [BrainSeedCard()]
    @State private var notes = [BrainSeedCard()]
    @State private var errorText = ""

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Brain")
                        .font(.title2.weight(.semibold))
                    Text("Seed the first shape of what this brain wants, where it is going, and what it should keep in mind.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(24)

            Divider()
                .overlay(.white.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrainCreationTextField(title: "Name", text: $name, prompt: "Avery, Studio Brain, Research Partner")

                    BrainCreationCardStack(
                        title: "Wants",
                        subtitle: "What should this brain care about or seek more of?",
                        prompt: "Add a want",
                        cards: $wants
                    )

                    BrainCreationCardStack(
                        title: "Goals",
                        subtitle: "Concrete outcomes, habits, projects, or directions.",
                        prompt: "Add a goal",
                        cards: $goals
                    )

                    BrainCreationCardStack(
                        title: "Initial Thoughts",
                        subtitle: "A first note, premise, self-description, or orientation.",
                        prompt: "Add an initial thought",
                        cards: $initialThoughts,
                        minHeight: 88
                    )

                    BrainCreationCardStack(
                        title: "Notes",
                        subtitle: "Anything else: boundaries, tone, reminders, context.",
                        prompt: "Add a note",
                        cards: $notes
                    )

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }
                .padding(24)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif

            Divider()
                .overlay(.white.opacity(0.06))

            ViewThatFits(in: .horizontal) {
                footerButtons(isStacked: false)
                footerButtons(isStacked: true)
            }
            .padding(24)
        }
        .frame(
            minWidth: horizontalSizeClass == .compact ? nil : 560,
            idealWidth: horizontalSizeClass == .compact ? nil : 620,
            maxWidth: horizontalSizeClass == .compact ? .infinity : nil,
            minHeight: 660,
            idealHeight: 760
        )
        .background(AppTheme.controlBackground)
        .foregroundStyle(AppTheme.primaryText)
        .keyboardDoneToolbar()
    }

    func footerButtons(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(spacing: 10) {
                    createButton
                    cancelButton
                }
            } else {
                HStack {
                    Spacer()
                    cancelButton
                    createButton
                }
            }
        }
    }

    var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        .buttonStyle(.bordered)
    }

    var createButton: some View {
        Button {
            #if canImport(UIKit)
            UIApplication.shared.dismissKeyboard()
            #endif
            do {
                try createBrain(.init(
                    name: name,
                    wants: wants.seedText,
                    goals: goals.seedText,
                    initialThoughts: initialThoughts.seedText,
                    notes: notes.seedText
                ))
            } catch {
                errorText = error.localizedDescription
            }
        } label: {
            Label("Create Brain", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canCreate)
    }
}

struct BrainRenameSheet: View {
    let brain: BrainDescriptor
    let renameBrain: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var name: String
    @State private var errorText = ""

    init(brain: BrainDescriptor, renameBrain: @escaping (String) throws -> Void) {
        self.brain = brain
        self.renameBrain = renameBrain
        _name = State(initialValue: brain.displayName)
    }

    var canRename: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rename Brain")
                        .font(.title2.weight(.semibold))
                    Text("This updates the display name and the brain folder id.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(24)

            Divider()
                .overlay(.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 18) {
                BrainCreationTextField(title: "Name", text: $name, prompt: brain.displayName)

                Text("Current folder id: \(brain.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.secondaryText)

                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
            .padding(24)

            Divider()
                .overlay(.white.opacity(0.06))

            ViewThatFits(in: .horizontal) {
                footerButtons(isStacked: false)
                footerButtons(isStacked: true)
            }
            .padding(24)
        }
        .frame(
            minWidth: horizontalSizeClass == .compact ? nil : 440,
            idealWidth: horizontalSizeClass == .compact ? nil : 500,
            maxWidth: horizontalSizeClass == .compact ? .infinity : nil
        )
        .background(AppTheme.controlBackground)
        .foregroundStyle(AppTheme.primaryText)
        .keyboardDoneToolbar()
    }

    func footerButtons(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(spacing: 10) {
                    renameButton
                    cancelButton
                }
            } else {
                HStack {
                    Spacer()
                    cancelButton
                    renameButton
                }
            }
        }
    }

    var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        .buttonStyle(.bordered)
    }

    var renameButton: some View {
        Button {
            do {
                try renameBrain(name)
            } catch {
                errorText = error.localizedDescription
            }
        } label: {
            Label("Rename", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canRename)
    }
}

struct BrainCreationTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .optionFieldStyle(isDirty: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct BrainSeedCard: Identifiable, Equatable {
    let id = UUID()
    var text = ""
}

struct BrainCreationCardStack: View {
    let title: String
    let subtitle: String
    let prompt: String
    @Binding var cards: [BrainSeedCard]
    var minHeight: CGFloat = 72
    @State private var editingCardID: BrainSeedCard.ID?
    @FocusState private var focusedCardID: BrainSeedCard.ID?
    @FocusState private var focusedDeleteCardID: BrainSeedCard.ID?
    @FocusState private var isAddButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                Button {
                    addCard()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .focused($isAddButtonFocused)
                .help(prompt)
                .accessibilityLabel(prompt)
                .onKeyPress(keys: [.tab]) { press in
                    focusCard(press.modifiers.contains(.shift) ? cards.last?.id : cards.first?.id)
                    return cards.isEmpty ? .ignored : .handled
                }
            }

            VStack(spacing: 10) {
                if cards.isEmpty {
                    emptyCard
                } else {
                    ForEach(cards) { card in
                        cardView(card)
                    }
                }
            }
        }
    }

    var emptyCard: some View {
        Button {
            addCard()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(prompt)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.plain)
        .background(AppTheme.editorBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        )
    }

    func cardView(_ card: BrainSeedCard) -> some View {
        let isEditing = editingCardID == card.id

        return ZStack(alignment: .topTrailing) {
            Group {
                if isEditing {
                    TextEditor(text: textBinding(for: card))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .padding(.trailing, 30)
                        .frame(minHeight: minHeight)
                        .focused($focusedCardID, equals: card.id)
                        .onAppear {
                            focusedCardID = card.id
                        }
                        .onKeyPress(keys: [.tab]) { press in
                            if press.modifiers.contains(.shift) {
                                moveFocus(from: card.id, direction: .backward)
                            } else {
                                focusDeleteButton(card.id)
                            }
                            return .handled
                        }
                } else {
                    Button {
                        editingCardID = card.id
                        focusedCardID = card.id
                        focusedDeleteCardID = nil
                        isAddButtonFocused = false
                    } label: {
                        Text(card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? editPrompt : card.text)
                            .font(.body)
                            .foregroundStyle(card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppTheme.secondaryText : AppTheme.primaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                            .padding(12)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isEditing ? AppTheme.accent.opacity(0.72) : .white.opacity(0.08), lineWidth: isEditing ? 1.4 : 1)
            )

            if isEditing {
                Button {
                    deleteCard(card)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.9))
                .focused($focusedDeleteCardID, equals: card.id)
                .background(.black.opacity(0.24), in: Circle())
                .padding(8)
                .help("Delete card")
                .accessibilityLabel("Delete \(title) card")
                .onKeyPress(keys: [.tab]) { press in
                    if press.modifiers.contains(.shift) {
                        focusCard(card.id)
                    } else {
                        moveFocus(from: card.id, direction: .forward)
                    }
                    return .handled
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func addCard() {
        let card = BrainSeedCard()
        cards.append(card)
        editingCardID = card.id
        focusedCardID = card.id
        focusedDeleteCardID = nil
        isAddButtonFocused = false
    }

    func deleteCard(_ card: BrainSeedCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards.remove(at: index)
        editingCardID = cards.indices.contains(index) ? cards[index].id : cards.last?.id
        focusedCardID = editingCardID
        focusedDeleteCardID = nil
        isAddButtonFocused = editingCardID == nil
    }

    func textBinding(for card: BrainSeedCard) -> Binding<String> {
        Binding(
            get: {
                cards.first(where: { $0.id == card.id })?.text ?? ""
            },
            set: { newValue in
                guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
                cards[index].text = newValue
            }
        )
    }

    func moveFocus(from cardID: BrainSeedCard.ID, direction: FocusDirection) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let nextIndex: Int
        switch direction {
        case .forward:
            nextIndex = cards.index(after: index)
        case .backward:
            nextIndex = cards.index(before: index)
        }

        guard cards.indices.contains(nextIndex) else {
            editingCardID = nil
            focusedCardID = nil
            focusedDeleteCardID = nil
            isAddButtonFocused = true
            return
        }
        focusCard(cards[nextIndex].id)
    }

    func focusCard(_ cardID: BrainSeedCard.ID?) {
        guard let cardID else { return }
        editingCardID = cardID
        focusedCardID = cardID
        focusedDeleteCardID = nil
        isAddButtonFocused = false
    }

    func focusDeleteButton(_ cardID: BrainSeedCard.ID) {
        editingCardID = cardID
        focusedCardID = nil
        focusedDeleteCardID = cardID
        isAddButtonFocused = false
    }

    var editPrompt: String {
        #if os(iOS)
        "Tap to edit"
        #else
        "Click to edit"
        #endif
    }

    enum FocusDirection {
        case forward
        case backward
    }
}

struct BrainCreationEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.10))
                )
        }
    }
}
