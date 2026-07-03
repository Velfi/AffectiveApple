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
                    .stroke(isDirty ? AppTheme.accent.opacity(0.72) : AppTheme.separator)
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
            .overlay(Capsule().stroke(AppTheme.separator))
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
            .overlay(Capsule().stroke(AppTheme.separator))
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
                .stroke(AppTheme.separator)
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

struct CoreConnectingScreen: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        ZStack {
            AppTheme.background
                .ignoresSafeArea()

            VStack(spacing: 28) {
                BrainAvatar(brain: model.brain, sizing: .fixedHeight(128))
                    .frame(maxWidth: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.separator)
                    )

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)

                    Text(model.coreLoadProgressLabel.isEmpty ? model.statusText : model.coreLoadProgressLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .multilineTextAlignment(.center)

                    if !model.coreLoadProgressDetail.isEmpty {
                        Text(model.coreLoadProgressDetail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }

                    Text(
                        model.isDreamTimeInFlight
                            ? "\(HeaderStrip.hostName) - dreaming"
                            : "\(HeaderStrip.hostName) - connecting"
                    )
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(32)
            .frame(maxWidth: 420)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(coreConnectingAccessibilityLabel)
    }

    private var coreConnectingAccessibilityLabel: String {
        var parts = ["Connecting to Zig core"]
        let label = model.coreLoadProgressLabel.isEmpty ? model.statusText : model.coreLoadProgressLabel
        if !label.isEmpty {
            parts.append(label)
        }
        if !model.coreLoadProgressDetail.isEmpty {
            parts.append(model.coreLoadProgressDetail)
        }
        return parts.joined(separator: ", ")
    }
}

struct HostPipelineDeadlockOverlay: View {
    let deadlock: HostPipelineDeadlock
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                DeadlockMark()
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Host Pipeline Deadlock")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text(deadlock.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)

                    Text(deadlock.detail)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }

                if !deadlock.sortedDiagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Diagnostics")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .textCase(.uppercase)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(deadlock.sortedDiagnostics, id: \.key) { item in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(item.key)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.white.opacity(0.62))
                                            .frame(width: 180, alignment: .leading)
                                        Text(item.value)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.white.opacity(0.92))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                    .padding(14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.12))
                    )
                }

                Text(deadlock.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.red.opacity(0.9))

                Button("Dismiss Overlay", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 520)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Host pipeline deadlock. \(deadlock.title). \(deadlock.detail)")
    }
}

private struct DeadlockMark: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(0.28), lineWidth: 8)

            Path { path in
                let inset: CGFloat = 28
                path.move(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: 120 - inset, y: 120 - inset))
                path.move(to: CGPoint(x: 120 - inset, y: inset))
                path.addLine(to: CGPoint(x: inset, y: 120 - inset))
            }
            .stroke(Color.red, style: StrokeStyle(lineWidth: 14, lineCap: .round))
        }
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
                .stroke(AppTheme.separator)
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
                    .stroke(AppTheme.separator)
            )
    }

    /// Expands the tappable area to at least `size`pt (Apple HIG recommends ≥44) without
    /// enlarging the visible content. Apply as the outermost modifier of a Button's label so the
    /// hit region — not just the icon — meets the minimum.
    func hitTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
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
        case .process: .purple
        case .emote: AppTheme.secondaryText.opacity(0.55)
        case .state: AppTheme.primaryText
        case .error: .red
        }
    }

    var badgeForeground: Color {
        switch self {
        case .state: AppTheme.inverseText
        case .emote: AppTheme.primaryText
        default: AppTheme.textOnAccent
        }
    }

    var entryBackground: Color {
        switch self {
        case .user, .sent: AppTheme.logUserBackground
        case .brain, .result: AppTheme.logBrainBackground
        case .process: AppTheme.logBrainBackground.opacity(0.82)
        case .emote: AppTheme.logStateBackground.opacity(0.72)
        case .state: AppTheme.logStateBackground
        case .error: AppTheme.logErrorBackground
        }
    }
}

enum AppTheme {
    private static let accentRedKey = "Affective.activeThemeColor.red"
    private static let accentGreenKey = "Affective.activeThemeColor.green"
    private static let accentBlueKey = "Affective.activeThemeColor.blue"
    private static let defaultAccent = AdaptiveColorComponents(red: 0.070, green: 0.560, blue: 0.250)

    static func applyThemeColor(_ themeColor: String?) {
        guard let themeColor, let color = BrainThemeColor.color(fromString: themeColor) else {
            clearBrainThemeColor()
            return
        }
        UserDefaults.standard.set(color.red, forKey: accentRedKey)
        UserDefaults.standard.set(color.green, forKey: accentGreenKey)
        UserDefaults.standard.set(color.blue, forKey: accentBlueKey)
    }

    static func applyTheme(for brain: BrainDescriptor) {
        applyThemeColor(brain.favoriteThemeColor.map { themeColorString(for: $0) })
    }

    static func applyMiseEnScene(name: String, themeColor: String?) {
        applyThemeColor(themeColor)
    }

    private static func themeColorString(for color: BrainThemeColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((color.red * 255).rounded()),
            Int((color.green * 255).rounded()),
            Int((color.blue * 255).rounded())
        )
    }

    static func clearBrainThemeColor() {
        UserDefaults.standard.removeObject(forKey: accentRedKey)
        UserDefaults.standard.removeObject(forKey: accentGreenKey)
        UserDefaults.standard.removeObject(forKey: accentBlueKey)
    }

    static let background = Color(
        light: .init(red: 0.965, green: 0.965, blue: 0.950),
        dark: .init(red: 0.058, green: 0.067, blue: 0.061)
    )
    static let sidebarBackground = Color(
        light: .init(red: 0.925, green: 0.935, blue: 0.910),
        dark: .init(red: 0.090, green: 0.104, blue: 0.096)
    )
    static let controlBackground = LinearGradient(
        colors: [
            Color(
                light: .init(red: 0.990, green: 0.990, blue: 0.975),
                dark: .init(red: 0.105, green: 0.126, blue: 0.115)
            ),
            background,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panelBackground = Color(
        light: .init(red: 1.000, green: 1.000, blue: 0.985),
        dark: .init(red: 0.145, green: 0.162, blue: 0.150)
    )
    static var activePanelBackground: Color {
        accentWash(lightOpacity: 0.18, darkOpacity: 0.30)
    }
    static let editorBackground = Color(
        light: .init(red: 0.900, green: 0.915, blue: 0.885),
        dark: .init(red: 0.078, green: 0.090, blue: 0.082)
    )
    static let composerBackground = Color(
        light: .init(red: 0.985, green: 0.985, blue: 0.970),
        dark: .init(red: 0.102, green: 0.116, blue: 0.108)
    )
    static let messageIncoming = Color(
        light: .init(red: 0.920, green: 0.930, blue: 0.905),
        dark: .init(red: 0.160, green: 0.176, blue: 0.166)
    )
    static var messageOutgoing: Color { accent }
    static let messageError = Color(
        light: .init(red: 1.000, green: 0.870, blue: 0.850),
        dark: .init(red: 0.280, green: 0.120, blue: 0.120)
    )
    static var logUserBackground: Color {
        accentWash(lightOpacity: 0.16, darkOpacity: 0.25)
    }
    static let logBrainBackground = Color(
        light: .init(red: 0.890, green: 0.925, blue: 0.990),
        dark: .init(red: 0.110, green: 0.150, blue: 0.230)
    )
    static let logStateBackground = Color(
        light: .init(red: 0.955, green: 0.935, blue: 0.860),
        dark: .init(red: 0.180, green: 0.170, blue: 0.130)
    )
    static let logErrorBackground = Color(
        light: .init(red: 1.000, green: 0.885, blue: 0.875),
        dark: .init(red: 0.240, green: 0.100, blue: 0.100)
    )
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let inverseText = Color(
        light: .init(red: 1.000, green: 1.000, blue: 1.000),
        dark: .init(red: 0.058, green: 0.067, blue: 0.061)
    )
    static var textOnAccent: Color {
        activeAccentComponents.perceivedLuminance > 0.58 ? .black.opacity(0.86) : .white
    }
    static var accent: Color {
        Color(light: activeAccentComponents, dark: activeAccentComponents.darkAppearanceAccent)
    }
    static let danger = Color(
        light: .init(red: 0.820, green: 0.145, blue: 0.120),
        dark: .init(red: 0.920, green: 0.240, blue: 0.200)
    )
    static let separator = Color(
        light: .init(red: 0.000, green: 0.000, blue: 0.000, opacity: 0.120),
        dark: .init(red: 1.000, green: 1.000, blue: 1.000, opacity: 0.095)
    )
    static let softSeparator = Color(
        light: .init(red: 0.000, green: 0.000, blue: 0.000, opacity: 0.070),
        dark: .init(red: 1.000, green: 1.000, blue: 1.000, opacity: 0.060)
    )
    static let ambientShadow = Color(
        light: .init(red: 0.000, green: 0.000, blue: 0.000, opacity: 0.100),
        dark: .init(red: 0.000, green: 0.000, blue: 0.000, opacity: 0.260)
    )

    private static var activeAccentComponents: AdaptiveColorComponents {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: accentRedKey) != nil,
            defaults.object(forKey: accentGreenKey) != nil,
            defaults.object(forKey: accentBlueKey) != nil
        else {
            return defaultAccent
        }
        return AdaptiveColorComponents(
            red: CGFloat(defaults.double(forKey: accentRedKey)),
            green: CGFloat(defaults.double(forKey: accentGreenKey)),
            blue: CGFloat(defaults.double(forKey: accentBlueKey))
        ).clamped
    }

    private static func accentWash(lightOpacity: CGFloat, darkOpacity: CGFloat) -> Color {
        let accent = activeAccentComponents
        return Color(
            light: accent.mixed(with: .white, amount: 1 - lightOpacity),
            dark: accent.darkAppearanceAccent.mixed(with: .black, amount: 1 - darkOpacity)
        )
    }
}

private struct AdaptiveColorComponents {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let opacity: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    static let white = AdaptiveColorComponents(red: 1, green: 1, blue: 1)
    static let black = AdaptiveColorComponents(red: 0, green: 0, blue: 0)

    var clamped: AdaptiveColorComponents {
        AdaptiveColorComponents(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            opacity: min(max(opacity, 0), 1)
        )
    }

    var perceivedLuminance: CGFloat {
        0.299 * red + 0.587 * green + 0.114 * blue
    }

    var darkAppearanceAccent: AdaptiveColorComponents {
        perceivedLuminance < 0.42 ? mixed(with: .white, amount: 0.28) : self
    }

    func mixed(with other: AdaptiveColorComponents, amount: CGFloat) -> AdaptiveColorComponents {
        let amount = min(max(amount, 0), 1)
        let retainedAmount = 1 - amount
        return AdaptiveColorComponents(
            red: red * retainedAmount + other.red * amount,
            green: green * retainedAmount + other.green * amount,
            blue: blue * retainedAmount + other.blue * amount,
            opacity: opacity
        )
    }
}

private extension Color {
    init(light: AdaptiveColorComponents, dark: AdaptiveColorComponents) {
        #if os(macOS)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return NSColor(themeComponents: match == .darkAqua ? dark : light)
        })
        #elseif canImport(UIKit)
        self = Color(uiColor: UIColor { traits in
            UIColor(themeComponents: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self = Color(
            red: Double(light.red),
            green: Double(light.green),
            blue: Double(light.blue),
            opacity: Double(light.opacity)
        )
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(themeComponents components: AdaptiveColorComponents) {
        self.init(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.opacity
        )
    }
}
#elseif canImport(UIKit)
private extension UIColor {
    convenience init(themeComponents components: AdaptiveColorComponents) {
        self.init(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: components.opacity
        )
    }
}
#endif

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

@MainActor
enum LocalFileImageCache {
    #if canImport(UIKit)
    typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    typealias PlatformImage = NSImage
    #endif

    private static var cache: [URL: PlatformImage] = [:]

    static func image(at url: URL) -> PlatformImage? {
        if let cached = cache[url] {
            return cached
        }
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else { return nil }
        #else
        return nil
        #endif
        cache[url] = image
        return image
    }
}

struct LocalCachedFileImageView: View {
    let url: URL
    var missingContent: AnyView?

    @State private var loadedImage: LocalFileImageCache.PlatformImage?

    var body: some View {
        Group {
            if let loadedImage {
                #if canImport(UIKit)
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                #elseif canImport(AppKit)
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                #endif
            } else if let missingContent {
                missingContent
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            loadedImage = LocalFileImageCache.image(at: url)
        }
    }
}
