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

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var horizontalAlignment: FlowLayoutHorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = normalizedWidth(proposal.width)
        let rows = layoutRows(for: subviews, width: width)
        return CGSize(width: width, height: rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = normalizedWidth(bounds.width)
        let rows = layoutRows(for: subviews, width: width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + horizontalAlignment.offset(for: row.width, in: width)

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }

            y += row.height + spacing
        }
    }

    func layoutRows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], height: CGFloat, width: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat, width: CGFloat)] = []
        var currentIndices: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if currentWidth > 0 && currentWidth + spacing + size.width > width {
                rows.append((currentIndices, currentHeight, currentWidth))
                currentIndices = [index]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentIndices.append(index)
                currentWidth += currentWidth == 0 ? size.width : size.width + spacing
                currentHeight = max(currentHeight, size.height)
            }
        }

        if currentWidth > 0 {
            rows.append((currentIndices, currentHeight, currentWidth))
        }
        return rows
    }

    private func normalizedWidth(_ proposedWidth: CGFloat?) -> CGFloat {
        guard let proposedWidth else {
            return 360
        }
        guard proposedWidth.isFinite, proposedWidth > 0 else {
            return 1
        }
        return proposedWidth
    }
}

enum FlowLayoutHorizontalAlignment {
    case leading
    case center
    case trailing

    func offset(for rowWidth: CGFloat, in availableWidth: CGFloat) -> CGFloat {
        switch self {
        case .leading:
            return 0
        case .center:
            return max((availableWidth - rowWidth) / 2, 0)
        case .trailing:
            return max(availableWidth - rowWidth, 0)
        }
    }
}

struct OptionFieldModifier: ViewModifier {
    let isDirty: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(AppTheme.editorBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isDirty ? AppTheme.accent.opacity(0.72) : .white.opacity(0.07))
            )
    }
}

struct CompactStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppTheme.panelBackground.opacity(0.82), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08)))
    }
}

struct CompactIconStatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppTheme.panelBackground.opacity(0.82), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08)))
    }
}

struct SegmentedControlOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String?

    var id: Value { value }
}

struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SegmentedControlOption<Value>]
    var equalWidth = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        if let systemImage = option.systemImage {
                            Image(systemName: systemImage)
                        }
                        Text(option.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selection == option.value ? AppTheme.primaryText : AppTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: equalWidth ? .infinity : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selection == option.value ? AppTheme.accent.opacity(0.22) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selection == option.value ? AppTheme.accent.opacity(0.35) : .clear)
                )
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(AppTheme.panelBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.07))
        )
    }
}

struct StatusNoteCard: View {
    let text: String
    var systemImage = "info.circle"
    var tint = AppTheme.secondaryText

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)

            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(AppTheme.panelBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18))
        )
    }
}

struct EmptyStateCard: View {
    let title: String
    var systemImage = "tray"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34, height: 34)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.accent.opacity(0.18))
                )

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(AppTheme.panelBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08))
        )
    }
}

extension View {
    func optionFieldStyle(isDirty: Bool) -> some View {
        modifier(OptionFieldModifier(isDirty: isDirty))
    }

    @ViewBuilder
    func chatKeyboardDismissMode() -> some View {
        #if canImport(UIKit)
        scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    @ViewBuilder
    func keyboardDoneToolbar() -> some View {
        #if canImport(UIKit)
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.dismissKeyboard()
                }
            }
        }
        #else
        self
        #endif
    }

    func panelStyle() -> some View {
        padding(15)
            .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08))
            )
    }
}

#if canImport(UIKit)
extension UIApplication {
    func dismissKeyboard() {
        sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
#endif

extension String {
    var optionDisplayName: String {
        split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

extension LogKind {
    var badgeBackground: Color {
        switch self {
        case .user, .sent: AppTheme.accent
        case .brain, .result: .blue
        case .state: AppTheme.primaryText
        case .error: .red
        }
    }

    var badgeForeground: Color {
        switch self {
        case .state: AppTheme.background
        default: .black.opacity(0.86)
        }
    }

    var entryBackground: Color {
        switch self {
        case .user, .sent: Color(red: 0.11, green: 0.22, blue: 0.17)
        case .brain, .result: Color(red: 0.11, green: 0.15, blue: 0.23)
        case .state: Color(red: 0.18, green: 0.17, blue: 0.13)
        case .error: Color(red: 0.24, green: 0.10, blue: 0.10)
        }
    }
}

enum AppTheme {
    static let background = Color(red: 0.058, green: 0.067, blue: 0.061)
    static let sidebarBackground = Color(red: 0.090, green: 0.104, blue: 0.096)
    static let controlBackground = LinearGradient(
        colors: [
            Color(red: 0.105, green: 0.126, blue: 0.115),
            Color(red: 0.058, green: 0.067, blue: 0.061),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panelBackground = Color(red: 0.145, green: 0.162, blue: 0.150)
    static let activePanelBackground = Color(red: 0.12, green: 0.27, blue: 0.19)
    static let editorBackground = Color(red: 0.078, green: 0.090, blue: 0.082)
    static let composerBackground = Color(red: 0.102, green: 0.116, blue: 0.108)
    static let messageIncoming = Color(red: 0.160, green: 0.176, blue: 0.166)
    static let messageOutgoing = Color(red: 0.10, green: 0.38, blue: 0.22)
    static let messageError = Color(red: 0.28, green: 0.12, blue: 0.12)
    static let primaryText = Color(red: 0.95, green: 0.92, blue: 0.82)
    static let secondaryText = Color(red: 0.72, green: 0.68, blue: 0.56)
    static let accent = Color(red: 0.28, green: 0.82, blue: 0.42)
    static let danger = Color(red: 0.92, green: 0.24, blue: 0.20)
}

struct BuildBadgeView: View {
    private let text = BuildBadge.text

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.secondaryText.opacity(0.7))
                .textSelection(.enabled)
                .accessibilityLabel("Build \(text)")
        }
    }
}

private enum BuildBadge {
    static var text: String? {
        guard shouldDisplay else { return nil }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = trimmed(info["CFBundleShortVersionString"])
        let build = trimmed(info["CFBundleVersion"])
        let hash = trimmed(info["AffectiveBuildHash"])
        let timestamp = trimmed(info["AffectiveBuildTimestamp"])

        var pieces = [String]()
        if let version, let build {
            pieces.append("v\(version) (\(build))")
        } else if let build {
            pieces.append("build \(build)")
        }
        if let hash {
            pieces.append(hash)
        }
        if let timestamp {
            pieces.append(timestamp)
        }

        guard !pieces.isEmpty else { return nil }
        return "\(channel): \(pieces.joined(separator: " - "))"
    }

    private static var shouldDisplay: Bool {
        #if DEBUG
        true
        #else
        isTestFlight
        #endif
    }

    private static var channel: String {
        #if DEBUG
        "Debug"
        #else
        "TestFlight"
        #endif
    }

    private static var isTestFlight: Bool {
        (Bundle.main.value(forKey: "appStoreReceiptURL") as? URL)?.lastPathComponent == "sandboxReceipt"
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

extension Array where Element == BrainSeedCard {
    var seedText: String {
        map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
