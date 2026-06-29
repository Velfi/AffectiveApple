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

struct MemoryToolsPanel: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Memory", subtitle: "Ask about or share memories through conversation.")

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
                    model.askMemoryQuestion()
                } label: {
                    Label("Ask", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(model.isToolRunning)

                Button {
                    model.shareMemoryWithBrain()
                } label: {
                    Label("Share", systemImage: "plus.circle")
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
            .optionFieldStyle(isDirty: !model.reminderSchedule.isEmpty)
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

struct InlineAutonomyControls: View {
    @ObservedObject var model: AffectiveViewModel
    var isCompact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullRow
            compactRow
            minimalRow
        }
    }

    var fullRow: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            Text("Autonomy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)

            autonomyPicker
                .frame(maxWidth: isCompact ? 190 : 220)

            Spacer(minLength: 4)

            Text(summaryText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)

            boredomIntervalLabel

            if model.autonomyIsEnabled {
                AnimatedAutonomyCapacityRing(model: model)
            }
        }
    }

    var compactRow: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            autonomyPicker
                .frame(maxWidth: isCompact ? 170 : 200)

            Spacer(minLength: 4)

            if model.autonomyIsEnabled {
                AnimatedAutonomyCapacityRing(model: model)
            }
        }
    }

    var minimalRow: some View {
        HStack(spacing: 8) {
            AutonomyToggleButton(model: model)

            if model.autonomyIsEnabled {
                AnimatedAutonomyCapacityRing(model: model)
            }

            Spacer(minLength: 0)
        }
    }

    var autonomyPicker: some View {
        Picker("Autonomy mode", selection: Binding(
            get: { model.normalizedAutonomyMode },
            set: { model.setAutonomyMode($0) }
        )) {
            Text("Off").tag("off")
            Text("Limited").tag("limited")
            Text("Full").tag("full")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Autonomy mode")
    }

    @ViewBuilder
    var boredomIntervalLabel: some View {
        if let boredomIntervalMax = model.runtimeOptionIntValue(for: AffectiveViewModel.boredomIntervalOptionKey) {
            Label("\(AffectiveViewModel.boredomIntervalMinSeconds)-\(boredomIntervalMax)s", systemImage: "clock")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .accessibilityLabel("Idle check randomly between \(AffectiveViewModel.boredomIntervalMinSeconds) and \(boredomIntervalMax) seconds")
        }
    }

    var summaryText: String {
        switch model.normalizedAutonomyMode {
        case "full":
            return "Full control"
        case "limited":
            return "Limited control"
        default:
            return "Off"
        }
    }
}

struct AutonomyToggleButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.setAutonomyMode(nextMode(from: model.normalizedAutonomyMode))
        } label: {
            Image(systemName: model.autonomyIsEnabled ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.autonomyIsEnabled ? AppTheme.accent : AppTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(AppTheme.editorBackground, in: Circle())
                .overlay(Circle().stroke(model.autonomyIsEnabled ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help("Cycle autonomy mode")
        .accessibilityLabel("Autonomy")
        .accessibilityValue(model.normalizedAutonomyMode.capitalized)
    }

    private func nextMode(from mode: String) -> String {
        switch mode {
        case "off":
            return "limited"
        case "limited":
            return "full"
        default:
            return "off"
        }
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
                .foregroundStyle(model.brainVoiceEnabled ? AppTheme.accent : AppTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(AppTheme.editorBackground, in: Circle())
                .overlay(Circle().stroke(model.brainVoiceEnabled ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
                .hitTarget()
        }
        .buttonStyle(.plain)
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
                    .frame(width: 44, height: 34)
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
        "\(Self.hostName) - \(model.coreStatusText)"
    }

    static var hostName: String {
        #if os(macOS)
        return "macOS host"
        #elseif canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad host" : "iPhone host"
        #else
        return "host"
        #endif
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

struct WakeButton: View {
    @ObservedObject var model: AffectiveViewModel
    var size: CGFloat = 36

    var body: some View {
        Button {
            model.shortTapWake()
        } label: {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: size, height: size)
                .background(AppTheme.panelBackground, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.08)))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help("Tap to wake Affective")
        .accessibilityLabel("Tap to wake Affective")
        .opacity(model.isBrainUnavailableForConversation ? 0.62 : 1)
    }
}
