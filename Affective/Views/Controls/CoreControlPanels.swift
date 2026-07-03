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
            Text("Attention")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)

            attentionStatePill

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.autonomyStatusLine(at: context.date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
            }
            .layoutPriority(1)

            boredomIntervalLabel
        }
    }

    var compactRow: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            attentionStatePill

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.autonomyStatusLine(at: context.date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
        }
    }

    var minimalRow: some View {
        HStack(spacing: 8) {
            AttentionStateButton(model: model)

            Spacer(minLength: 0)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.autonomyStatusLine(at: context.date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    var attentionStatePill: some View {
        Button {
            model.showAttentionSettings()
        } label: {
            Label(model.attentionStatusTitle, systemImage: attentionStateSymbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(AppTheme.editorBackground, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open attention settings")
        .accessibilityLabel("Open attention settings")
        .accessibilityValue(model.attentionStatusTitle)
    }

    var attentionStateSymbolName: String {
        model.attentionIsInSleepHours ? "moon.zzz.fill" : "scope"
    }

    @ViewBuilder
    var boredomIntervalLabel: some View {
        if let boredomIntervalMax = model.runtimeOptionIntValue(for: AffectiveViewModel.boredomIntervalOptionKey) {
            Label("\(AffectiveViewModel.boredomIntervalMinSeconds)-\(boredomIntervalMax)s", systemImage: "clock")
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Idle check randomly between \(AffectiveViewModel.boredomIntervalMinSeconds) and \(boredomIntervalMax) seconds")
        }
    }
}

struct ChatConversationControlStrip: View {
    @ObservedObject var model: AffectiveViewModel
    var isCompact = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullRow
            compactRow
        }
    }

    var fullRow: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            AttentionPlaybackButton(model: model)
            CameraSenseToggleButton(model: model)
            BrainVoiceToggleButton(model: model)

            Divider()
                .frame(height: 22)
                .overlay(AppTheme.softSeparator)

            InlineAutonomyControls(model: model, isCompact: true)
                .layoutPriority(1)
        }
        .controlGroupFrame(isCompact: isCompact)
    }

    var compactRow: some View {
        HStack(spacing: 8) {
            AttentionPlaybackButton(model: model)
            CameraSenseToggleButton(model: model)
            BrainVoiceToggleButton(model: model)

            Spacer(minLength: 4)

            AttentionStateButton(model: model)
        }
        .controlGroupFrame(isCompact: true)
    }
}

private extension View {
    func controlGroupFrame(isCompact: Bool) -> some View {
        self
            .padding(.horizontal, isCompact ? 7 : 9)
            .padding(.vertical, isCompact ? 6 : 7)
            .background(AppTheme.composerBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.separator)
            )
    }
}

struct AttentionPlaybackButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.setAttentionPaused(!model.attentionIsPaused)
        } label: {
            Image(systemName: model.attentionIsPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.attentionIsPaused ? AppTheme.secondaryText : AppTheme.accent)
                .frame(width: 30, height: 30)
                .background(AppTheme.editorBackground, in: Circle())
                .overlay(Circle().stroke(model.attentionIsPaused ? .white.opacity(0.08) : AppTheme.accent.opacity(0.36)))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help(model.attentionIsPaused ? "Resume attention" : "Pause attention")
        .accessibilityLabel(model.attentionIsPaused ? "Resume attention" : "Pause attention")
    }
}

struct CameraSenseToggleButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.setCameraCaptureEnabled(!model.cameraCaptureIsEnabled)
        } label: {
            Image(systemName: model.cameraCaptureIsEnabled ? "camera.fill" : "video.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.cameraCaptureIsEnabled ? AppTheme.accent : AppTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(AppTheme.editorBackground, in: Circle())
                .overlay(Circle().stroke(model.cameraCaptureIsEnabled ? AppTheme.accent.opacity(0.36) : .white.opacity(0.08)))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help(model.cameraCaptureIsEnabled ? "Disable camera sense" : "Enable camera sense")
        .accessibilityLabel("Camera sense")
        .accessibilityValue(model.cameraCaptureIsEnabled ? "On" : "Off")
    }
}

struct AttentionStateButton: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        Button {
            model.showAttentionSettings()
        } label: {
            Image(systemName: model.attentionIsInSleepHours ? "moon.zzz.fill" : "scope")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 30, height: 30)
                .background(AppTheme.editorBackground, in: Circle())
                .overlay(Circle().stroke(AppTheme.accent.opacity(0.36)))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .help("Open attention settings")
        .accessibilityLabel("Open attention settings")
        .accessibilityValue(model.autonomyStatusLine())
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
        ViewThatFits(in: .horizontal) {
            inlineRow
            stackedRow
        }
    }

    var inlineRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
                .frame(width: 18, height: 18)

            Text(model.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text(connectionDetail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            refreshButton
        }
    }

    var stackedRow: some View {
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
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer()

            refreshButton
        }
    }

    var refreshButton: some View {
        Button {
            model.refreshBrainState()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 30)
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.accent)
        .controlSize(.small)
        .disabled(model.isToolRunning)
        .help("Refresh state")
        .accessibilityLabel("Refresh state")
        .fixedSize(horizontal: true, vertical: false)
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
