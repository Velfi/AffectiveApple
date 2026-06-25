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

struct LiveCorePanel: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Core", subtitle: "Send live tool calls to the selected Zig brain.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                ForEach(CoreToolAction.primary) { action in
                    Button {
                        model.runCoreAction(action)
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isToolRunning)
                }
            }
        }
        .panelStyle()
    }
}

struct MemoryToolsPanel: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Memory", subtitle: "Recall or write memories through brain storage.")

            TextField("query", text: $model.memoryQuery)
                .textFieldStyle(.plain)
                .optionFieldStyle(isDirty: !model.memoryQuery.isEmpty)

            TextField("tags, comma separated", text: $model.memoryTags)
                .textFieldStyle(.plain)
                .optionFieldStyle(isDirty: !model.memoryTags.isEmpty)

            TextEditor(text: $model.memoryText)
                .font(.body)
                .foregroundStyle(AppTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 74)
                .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(!model.memoryText.isEmpty ? AppTheme.accent.opacity(0.5) : .white.opacity(0.08))
                )

            HStack(spacing: 10) {
                Button {
                    model.recallMemory()
                } label: {
                    Label("Recall", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(model.isToolRunning)

                Button {
                    model.rememberMemory()
                } label: {
                    Label("Remember", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isToolRunning || model.memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
        }
        .panelStyle()
        .keyboardDoneToolbar()
    }
}

struct ReminderToolsPanel: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Reminders", subtitle: "Set timers or inspect the brain's maintenance schedule.")

            ViewThatFits(in: .horizontal) {
                reminderFields(isStacked: false)
                reminderFields(isStacked: true)
            }

            HStack(spacing: 10) {
                Button {
                    model.setReminder()
                } label: {
                    Label("Set", systemImage: "bell.badge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isToolRunning || model.reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    model.listReminders()
                } label: {
                    Label("List", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(model.isToolRunning)

                Spacer()
            }
        }
        .panelStyle()
        .keyboardDoneToolbar()
    }

    func reminderFields(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(spacing: 10) {
                    scheduleField
                    reminderTextField
                }
            } else {
                HStack(spacing: 10) {
                    scheduleField
                        .frame(maxWidth: 160)
                    reminderTextField
                }
            }
        }
    }

    var scheduleField: some View {
        TextField("in 10 minutes", text: $model.reminderSchedule)
            .textFieldStyle(.plain)
            .optionFieldStyle(isDirty: true)
    }

    var reminderTextField: some View {
        TextField("reminder text", text: $model.reminderText)
            .textFieldStyle(.plain)
            .optionFieldStyle(isDirty: !model.reminderText.isEmpty)
    }
}

struct PanelHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AutonomyOptionsPanel: View {
    @ObservedObject var model: AffectiveViewModel
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Button {
                model.setAutonomyMode(model.autonomyMode == "on" ? "off" : "on")
            } label: {
                Image(systemName: model.autonomyMode == "on" ? "bolt.circle.fill" : "bolt.slash.circle")
                    .font(.system(size: isCompact ? 14 : 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.autonomyMode == "on" ? AppTheme.accent : AppTheme.secondaryText)
                    .frame(width: isCompact ? 26 : 30, height: isCompact ? 26 : 30)
                    .background(AppTheme.editorBackground, in: Circle())
                    .overlay(Circle().stroke(model.autonomyMode == "on" ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(model.autonomyMode == "on" ? "Disable autonomy" : "Enable autonomy")
            .accessibilityLabel("Autonomy")
            .accessibilityValue(model.autonomyMode == "on" ? "On" : "Off")

            Text("Autonomy")
                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)

            Text(summaryText)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 8)

            if let boredomInterval = model.runtimeOptionIntValue(for: AffectiveViewModel.boredomIntervalOptionKey) {
                Label("\(boredomInterval)s", systemImage: "clock")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityLabel("Idle check every \(boredomInterval) seconds")
            }

            if model.autonomyMode == "on" {
                budgetCounter

                Button {
                    model.addAutonomyActionBudget()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: isCompact ? 17 : 18, weight: .semibold))
                        .frame(width: isCompact ? 26 : 28, height: isCompact ? 26 : 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .help("Add 1 autonomy action")
                .accessibilityLabel("Add one autonomy action")
            }
        }
        .padding(.horizontal, isCompact ? 11 : 15)
        .padding(.vertical, isCompact ? 9 : 11)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(model.autonomyMode == "on" ? AppTheme.accent.opacity(0.45) : .white.opacity(0.08))
        )
    }

    var summaryText: String {
        if model.autonomyMode == "on" {
            return "\(model.autonomyActionBudget) actions left"
        }
        return "Off"
    }

    var budgetCounter: some View {
        Text("\(model.autonomyActionBudget) actions")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Autonomy budget \(model.autonomyActionBudget) actions")
    }
}

struct ChatControlsStrip: View {
    @ObservedObject var model: AffectiveViewModel
    var isCompact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlLayout(showStatus: true)
            controlLayout(showStatus: false)
        }
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 6 : 8)
        .background(AppTheme.panelBackground.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
    }

    func controlLayout(showStatus: Bool) -> some View {
        HStack(spacing: 8) {
            BrainVoiceToggleButton(model: model)

            AutonomyToggleButton(model: model)

            if showStatus, model.autonomyMode == "on" {
                CompactStatusPill(text: "\(model.autonomyActionBudget)")
                    .accessibilityLabel("Autonomy budget \(model.autonomyActionBudget) actions")
            }

            Button {
                model.addAutonomyActionBudget()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .accessibilityLabel("Add one autonomy action")
            .opacity(model.autonomyMode == "on" ? 1 : 0)
            .disabled(model.autonomyMode != "on")
            .frame(width: model.autonomyMode == "on" ? 30 : 0)
            .clipped()
            .accessibilityHidden(model.autonomyMode != "on")
        }
    }
}

struct AutonomyToggleButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.setAutonomyMode(model.autonomyMode == "on" ? "off" : "on")
        } label: {
            Image(systemName: model.autonomyMode == "on" ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.autonomyMode == "on" ? AppTheme.accent : AppTheme.secondaryText)
        .background(AppTheme.editorBackground, in: Circle())
        .overlay(Circle().stroke(model.autonomyMode == "on" ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
        .help(model.autonomyMode == "on" ? "Disable autonomy" : "Enable autonomy")
        .accessibilityLabel("Autonomy")
        .accessibilityValue(model.autonomyMode == "on" ? "On" : "Off")
    }
}

struct BrainVoiceToggleButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.setBrainVoiceEnabled(!model.brainVoiceEnabled)
        } label: {
            Image(systemName: model.brainVoiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.brainVoiceEnabled ? AppTheme.accent : AppTheme.secondaryText)
        .background(AppTheme.editorBackground, in: Circle())
        .overlay(Circle().stroke(model.brainVoiceEnabled ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
        .help(model.brainVoiceEnabled ? "Disable brain voice" : "Enable brain voice")
        .accessibilityLabel("Brain voice")
        .accessibilityValue(model.brainVoiceEnabled ? "On" : "Off")
    }
}

struct HeaderStrip: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(connectionDetail)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            Button {
                model.refreshBrainState()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.accent)
            .controlSize(.small)
            .disabled(model.isToolRunning)
            .help("Refresh state")
            .accessibilityLabel("Refresh state")
        }
    }

    var connectionDetail: String {
        "macOS host - \(model.coreStatusText)"
    }

    var statusSymbolName: String {
        if !model.canSend { return "paperplane.fill" }
        if model.coreStatusText == "connected" { return "checkmark.circle.fill" }
        return model.coreStatusSymbolName
    }

    var statusTint: Color {
        if !model.canSend { return .blue }
        if model.coreStatusText == "connected" { return AppTheme.accent }
        return .orange
    }
}

struct PrimaryHoldButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 5) {
                Text("Tap to Wake")
                    .font(.title2.weight(.bold))
                Text("Use the message field with system dictation for voice input")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            Image(systemName: "space")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            model.shortTapWake()
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 14)
        .opacity(!model.canSend ? 0.62 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Tap to wake Affective")
        .accessibilityAction {
            model.shortTapWake()
        }
    }
}
