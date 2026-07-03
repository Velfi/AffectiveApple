//
//  Split from ContentView.swift
//  Affective
//

import SwiftUI
import UniformTypeIdentifiers
import StoreKit
import Combine
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

struct OptionsView: View {
    @ObservedObject var model: AffectiveViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .keyboardDoneToolbar()
    }

    var regularBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Settings")
                                    .font(.system(size: 30, weight: .semibold, design: .rounded))

                                Text("Brain settings travel with the selected brain. Host settings belong to this Mac and include provider account links.")
                                    .font(.callout)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Scope")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.secondaryText)

                                settingsScopePicker
                                    .frame(maxWidth: 460)

                                Text("Switch between brain-specific options and host credentials without losing your place.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AppTheme.separator)
                            )
                        }

                        Text("Live changes apply at the next safe point. Restart-required changes are saved now and used after the next launch.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)

                        avatarEditorButton

                        if model.selectedSettingsScope == .brain {
                            BiometricPolicyCard(model: model)
                        }

                        DonationSupportCard()

                        ForEach(model.optionGroups.indices.filter { model.optionGroups[$0].scope == model.selectedSettingsScope }, id: \.self) { index in
                            RuntimeOptionGroupView(model: model, group: $model.optionGroups[index])
                                .id(model.optionGroups[index].title)
                        }
                    }
                    .padding(horizontalSizeClass == .compact ? 18 : 32)
                    .padding(.bottom, 10)
                    .frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { scrollToFocusedSettingsGroup(using: scrollProxy) }
                .onChange(of: model.focusedSettingsGroupTitle) { _, _ in
                    scrollToFocusedSettingsGroup(using: scrollProxy)
                }
                .onChange(of: model.selectedSettingsScope) { _, _ in
                    scrollToFocusedSettingsGroup(using: scrollProxy)
                }
            }

            Divider()
                .overlay(AppTheme.softSeparator)

            ApplyOptionsBar(model: model)
                .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 24)
                .padding(.vertical, 14)
                .background(AppTheme.sidebarBackground)
        }
    }

    var compactBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HeaderStrip(model: model)
                            .panelStyle()

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Settings")
                                .font(.system(size: 23, weight: .semibold, design: .rounded))
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            CompactStatusPill(text: compactDirtyText)
                                .accessibilityLabel(model.dirtyOptionCount == 0 ? "No unsaved changes" : "\(model.dirtyOptionCount) unsaved changes")
                        }

                        settingsScopePicker

                        Text("Changes apply at the next safe point. Restart-marked settings take effect after relaunch.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        avatarEditorButton

                        if model.selectedSettingsScope == .brain {
                            BiometricPolicyCard(model: model)
                        }

                        DonationSupportCard()

                        ForEach(model.optionGroups.indices.filter { model.optionGroups[$0].scope == model.selectedSettingsScope }, id: \.self) { index in
                            RuntimeOptionGroupView(model: model, group: $model.optionGroups[index])
                                .id(model.optionGroups[index].title)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scrollToFocusedSettingsGroup(using: scrollProxy) }
                .onChange(of: model.focusedSettingsGroupTitle) { _, _ in
                    scrollToFocusedSettingsGroup(using: scrollProxy)
                }
                .onChange(of: model.selectedSettingsScope) { _, _ in
                    scrollToFocusedSettingsGroup(using: scrollProxy)
                }
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
                .overlay(AppTheme.softSeparator)

            ApplyOptionsBar(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppTheme.sidebarBackground)
        }
    }

    var settingsScopePicker: some View {
        SegmentedControl(
            selection: $model.selectedSettingsScope,
            options: SettingsScope.allCases.map {
                .init(value: $0, title: $0.rawValue, systemImage: $0.symbolName)
            }
        )
    }

    @ViewBuilder
    var avatarEditorButton: some View {
        #if os(macOS)
        if model.selectedSettingsScope == .brain {
            Button {
                openWindow(id: "avatar-editor", value: model.brain.id)
            } label: {
                Label("Open Avatar Editor", systemImage: "person.crop.square")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(horizontalSizeClass == .compact ? .regular : .large)
            .padding(.bottom, 4)
        }
        #endif
    }

    var compactDirtyText: String {
        model.dirtyOptionCount == 0 ? "Saved" : "\(model.dirtyOptionCount)"
    }

    func scrollToFocusedSettingsGroup(using scrollProxy: ScrollViewProxy) {
        guard let groupTitle = model.focusedSettingsGroupTitle else { return }
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.22)) {
                scrollProxy.scrollTo(groupTitle, anchor: .top)
            }
        }
    }
}

struct DonationSupportCard: View {
    @StateObject private var store = DonationSupportStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Support Development")
                        .font(.headline.weight(.semibold))

                    Text("If Affective is useful to you, you can send an optional one-time tip to help fund continued development.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let statusText = store.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.products.isEmpty && store.isLoading {
                ProgressView("Loading tip options")
                    .controlSize(.small)
                    .tint(AppTheme.accent)
            } else if store.products.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(DonationSupportProduct.allCases) { product in
                        Button {
                            store.statusText = "Tip products are not available yet. Check App Store Connect setup."
                        } label: {
                            Label(product.defaultButtonTitle, systemImage: "heart.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(true)
                        .help(product.productID)
                    }
                }

                Text("Configure these consumable in-app purchases in App Store Connect before submitting for review.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(store.products) { product in
                        Button {
                            Task {
                                await store.purchase(product)
                            }
                        } label: {
                            Label(productButtonTitle(product), systemImage: "heart.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(store.isPurchasing)
                        .help("Purchase \(product.displayName)")
                    }
                }
            }
        }
        .padding(14)
        .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 2)
        .task {
            await store.loadProducts()
        }
    }

    private func productButtonTitle(_ product: Product) -> String {
        "\(product.displayName) \(product.displayPrice)"
    }
}

struct BiometricPolicyCard: View {
    @ObservedObject var model: AffectiveViewModel
    @State private var confirmDeleteAll = false
    @State private var confirmDisableAndDelete = false

    var summaries: [BiometricTemplateSummary] {
        model.biometricTemplateSummaries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Biometric Data Policy")
                        .font(.headline.weight(.semibold))
                    Text("People memory stays separate from biometric records. Face templates stay on this device unless you choose to export them. Affective does not collect them on a server, sell them, or send them to model providers. Enrollment is owner-managed: record consent before adding another person's biometric records.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                policyLine("Collected", "biometric records, face templates, and optional labels")
                policyLine("Purpose", "local recognition and comparison for this brain")
                policyLine("Stored", "memory/face_embeddings/ and local biometric records")
                policyLine("Retention", retentionText)
                policyLine("Export", exportText)
            }
            .font(.caption)

            Divider()
                .overlay(AppTheme.softSeparator)

            VStack(alignment: .leading, spacing: 8) {
                Text("Biometric Records")
                    .font(.subheadline.weight(.semibold))

                if summaries.isEmpty {
                    Text("No local biometric templates were found for this brain.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(summaries) { summary in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(summary.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(summary.templateCount) records")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                            Text(summary.consentStatus)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .help(summaryHelp(summary))
                    }
                }
            }

            FlowLayout(spacing: 8) {
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete Biometric Data", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    confirmDisableAndDelete = true
                } label: {
                    Label("Disable and Delete", systemImage: "person.crop.circle.badge.xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 2)
        .confirmationDialog("Delete all biometric data for this brain?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete Biometric Data", role: .destructive) {
                model.deleteAllBiometricData()
            }
        } message: {
            Text("This removes face templates and local biometric records, but keeps the rest of the brain.")
        }
        .confirmationDialog("Disable recognition and delete biometric data?", isPresented: $confirmDisableAndDelete, titleVisibility: .visible) {
            Button("Disable and Delete", role: .destructive) {
                model.disableRecognitionAndDeleteBiometricData()
            }
        } message: {
            Text("This turns recognition and enrollment off, excludes biometrics from future exports and iCloud uploads, and removes stored templates.")
        }
    }

    var retentionText: String {
        switch model.biometricPolicy.retentionPeriod {
        case "30_days": "30 days"
        case "1_year": "1 year"
        case "3_years": "3 years"
        case "delete_when_not_seen": "delete when a person has not been seen"
        default: "until deleted"
        }
    }

    var exportText: String {
        model.biometricPolicy.exportIncluded
            ? "included in exports and iCloud uploads after confirmation"
            : "excluded from exports and iCloud uploads"
    }

    func policyLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .fontWeight(.semibold)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func summaryHelp(_ summary: BiometricTemplateSummary) -> String {
        let created = summary.createdAt.map { Self.dateFormatter.string(from: $0) } ?? "unknown"
        let lastMatched = summary.lastMatchedAt.map { Self.dateFormatter.string(from: $0) } ?? "unknown"
        return "Created: \(created)\nLast matched: \(lastMatched)"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

@MainActor
final class DonationSupportStore: ObservableObject {
    @Published var products: [Product] = []
    @Published var statusText: String?
    @Published var isLoading = false
    @Published var isPurchasing = false

    private var hasLoadedProducts = false

    func loadProducts(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        if hasLoadedProducts && !forceRefresh { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let loadedProducts = try await Product.products(for: DonationSupportProduct.productIDs)
            products = loadedProducts.sortedByDonationProductOrder()
            hasLoadedProducts = true
            statusText = products.isEmpty
                ? "Tip products are not available yet. Confirm the consumable in-app purchases are configured in App Store Connect."
                : nil
        } catch {
            statusText = "Unable to load tip options: \(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        statusText = "Starting purchase..."
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                statusText = "Thank you for supporting Affective."
            case .pending:
                statusText = "Purchase is pending approval."
            case .userCancelled:
                statusText = "Purchase cancelled."
            @unknown default:
                statusText = "Purchase did not complete."
            }
        } catch {
            statusText = "Purchase failed: \(error.localizedDescription)"
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw DonationSupportError.failedVerification
        }
    }
}

enum DonationSupportProduct: String, CaseIterable, Identifiable {
    case smallTip = "2026_small_tip.1"
    case mediumTip = "2026_medium_tip.1"
    case largeTip = "2026_big_tip.1"

    var id: String { rawValue }
    var productID: String { rawValue }

    var defaultButtonTitle: String {
        switch self {
        case .smallTip: "Small Tip"
        case .mediumTip: "Medium Tip"
        case .largeTip: "Large Tip"
        }
    }

    static var productIDs: [String] {
        allCases.map(\.productID)
    }
}

enum DonationSupportError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            "StoreKit could not verify this purchase."
        }
    }
}

extension Array where Element == Product {
    func sortedByDonationProductOrder() -> [Product] {
        sorted { lhs, rhs in
            let lhsIndex = DonationSupportProduct.productIDs.firstIndex(of: lhs.id) ?? Int.max
            let rhsIndex = DonationSupportProduct.productIDs.firstIndex(of: rhs.id) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }
}

struct RuntimeOptionGroupView: View {
    @ObservedObject var model: AffectiveViewModel
    @Binding var group: RuntimeOptionGroup
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        DisclosureGroup(isExpanded: $group.isExpanded) {
            VStack(spacing: 0) {
                ForEach($group.options) { $option in
                    RuntimeOptionRow(model: model, option: $option)
                    if option.id != group.options.last?.id {
                        Divider()
                            .overlay(AppTheme.softSeparator)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.headline.weight(.semibold))
                    if horizontalSizeClass != .compact {
                        Text(group.note)
                            .font(.callout)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if isCredentialGroup {
                        Button {
                            model.testCredentialOptions(group.options)
                        } label: {
                            Label("Test All", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(group.options.compactMap { ProviderCredentialKey(rawValue: $0.key) }.contains { model.credentialTestResults[$0]?.isTesting == true })
                        .help("Test every configured API key in this group")
                    }

                    if horizontalSizeClass == .compact {
                        Text("\(group.options.count)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.13), in: Capsule())
                    } else {
                        Text("\(group.options.count) options")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) {
                    group.isExpanded.toggle()
                }
            }
            .accessibilityAddTraits(.isButton)
        }
        .padding(horizontalSizeClass == .compact ? 13 : 15)
        .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 2)
    }

    var isCredentialGroup: Bool {
        group.options.contains { ProviderCredentialKey(rawValue: $0.key) != nil }
    }
}

struct RuntimeOptionRow: View {
    @ObservedObject var model: AffectiveViewModel
    @Binding var option: RuntimeOption
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        rowLayout(isCompact: horizontalSizeClass == .compact)
        .padding(.vertical, horizontalSizeClass == .compact ? 10 : 14)
        .opacity(option.isReadOnly ? 0.68 : 1)
    }

    @ViewBuilder
    func rowLayout(isCompact: Bool) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 9) {
                optionLabel
                optionField(isCompact: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                optionAccessories(horizontalAlignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    optionLabel
                        .frame(minWidth: 156, maxWidth: 240, alignment: .leading)

                    Spacer(minLength: 12)

                    optionField(isCompact: false)
                        .frame(maxWidth: 320, alignment: .trailing)
                }

                if hasAccessories {
                    optionAccessories(horizontalAlignment: .trailing)
                }
            }
        }
    }

    var optionLabel: some View {
        Text(option.label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(option.key)
    }

    @ViewBuilder
    func optionAccessories(horizontalAlignment: FlowLayoutHorizontalAlignment) -> some View {
        FlowLayout(spacing: 8, horizontalAlignment: horizontalAlignment) {
            if let keyCreationURL {
                Link(destination: keyCreationURL) {
                    Label("Create key", systemImage: "key")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .help("Open \(option.label.replacingOccurrences(of: " API key", with: "")) key creation page")
            }

            if let credentialKey {
                Button {
                    model.testCredential(for: option)
                } label: {
                    Label(credentialTestLabel, systemImage: credentialTestSymbolName)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.caption.weight(.semibold))
                .tint(credentialTestTint)
                .disabled(model.credentialTestResults[credentialKey]?.isTesting == true || option.shouldDeleteSecret)
                .help(credentialTestHelp)
            }

            if let speechVoiceDownloadURL {
                Link(destination: speechVoiceDownloadURL) {
                    Label("Download more voices", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .help("Open Apple speech voice downloads in System Settings")
            }

            if option.isSecret, option.hasStoredSecret {
                Button {
                    option.shouldDeleteSecret.toggle()
                    if option.shouldDeleteSecret {
                        option.value = ""
                    }
                } label: {
                    Image(systemName: option.shouldDeleteSecret ? "arrow.uturn.backward" : "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.semibold))
                .foregroundStyle(option.shouldDeleteSecret ? AppTheme.accent : Color.red.opacity(0.82))
                .help(option.shouldDeleteSecret ? "Keep stored key" : "Remove stored key")
            }

            if option.isReadOnly {
                OptionBadge(text: "read only")
            } else if option.requiresRestart {
                OptionBadge(text: "restart")
            }
        }
        .frame(maxWidth: .infinity, alignment: horizontalAlignment.frameAlignment)
    }

    var hasAccessories: Bool {
        keyCreationURL != nil
            || credentialKey != nil
            || speechVoiceDownloadURL != nil
            || (option.isSecret && option.hasStoredSecret)
            || option.isReadOnly
            || option.requiresRestart
    }

    var keyCreationURL: URL? {
        ProviderCredentialKey(rawValue: option.key)?.creationURL
    }

    var credentialKey: ProviderCredentialKey? {
        ProviderCredentialKey(rawValue: option.key)
    }

    var speechVoiceDownloadURL: URL? {
        guard option.key == "speech_voice" else { return nil }
        #if os(macOS)
        return URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
        #else
        return URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    var credentialTestStatus: CredentialTestStatus? {
        credentialKey.flatMap { model.credentialTestResults[$0] }
    }

    var credentialTestLabel: String {
        switch credentialTestStatus {
        case .testing: "Testing"
        case .valid: "Works"
        case .invalid: "Failed"
        case nil: "Test"
        }
    }

    var credentialTestSymbolName: String {
        switch credentialTestStatus {
        case .testing: "arrow.triangle.2.circlepath"
        case .valid: "checkmark.circle.fill"
        case .invalid: "xmark.octagon.fill"
        case nil: "checkmark.shield"
        }
    }

    var credentialTestTint: Color {
        switch credentialTestStatus {
        case .valid: AppTheme.accent
        case .invalid: AppTheme.danger
        default: AppTheme.secondaryText
        }
    }

    var credentialTestHelp: String {
        switch credentialTestStatus {
        case .invalid(let message): message
        case .valid: "The provider accepted this key."
        case .testing: "Testing this key with the provider."
        case nil: "Test the typed key, or the stored key if the field is blank."
        }
    }

    var secretStatusText: String {
        if option.shouldDeleteSecret {
            return "Will remove"
        }
        return option.hasStoredSecret ? "Configured" : "Not configured"
    }

    var secretPlaceholder: String {
        option.hasStoredSecret ? "Enter replacement key" : "Enter key"
    }

    func optionField(isCompact: Bool) -> some View {
        Group {
            switch option.kind {
            case .select(let choices):
                Picker(option.label, selection: $option.value) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(option.isReadOnly)
                .tint(AppTheme.accent)
                .controlSize(.regular)
                .frame(maxWidth: isCompact ? .infinity : 220, alignment: isCompact ? .leading : .trailing)
            case .text:
                if option.isSecret {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: option.hasStoredSecret && !option.shouldDeleteSecret ? "checkmark.seal.fill" : "key.slash")
                                .foregroundStyle(option.hasStoredSecret && !option.shouldDeleteSecret ? AppTheme.accent : AppTheme.secondaryText)
                            Text(secretStatusText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        SecureField(secretPlaceholder, text: $option.value)
                            .textFieldStyle(.plain)
                            .optionFieldStyle(isDirty: option.isDirty)
                            .disabled(option.isReadOnly || option.shouldDeleteSecret)
                            .frame(maxWidth: isCompact ? .infinity : 320, alignment: .leading)
                            .onChange(of: option.value) { _, newValue in
                                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    DispatchQueue.main.async {
                                        option.shouldDeleteSecret = false
                                    }
                                }
                            }
                    }
                    .frame(maxWidth: isCompact ? .infinity : 320, alignment: .leading)
                } else {
                    TextField(option.label, text: $option.value)
                        .textFieldStyle(.plain)
                        .optionFieldStyle(isDirty: option.isDirty)
                        .disabled(option.isReadOnly)
                        .frame(maxWidth: isCompact ? .infinity : 320, alignment: .leading)
                }
            case .number:
                HStack(spacing: 8) {
                    TextField(option.label, text: $option.value)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .optionFieldStyle(isDirty: option.isDirty)
                        .disabled(option.isReadOnly)
                        .frame(width: isCompact ? 100 : 92)

                    if let unit = option.unit {
                        Text(unit)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: isCompact ? 64 : 58, alignment: .leading)
                    }
                }
                .frame(maxWidth: isCompact ? .infinity : 158, alignment: .leading)
            case .timeRange:
                HStack(spacing: 8) {
                    timePicker("Start", selection: timeBinding(for: .start))

                    Text("to")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)

                    timePicker("End", selection: timeBinding(for: .end))
                }
                .disabled(option.isReadOnly)
                .frame(maxWidth: isCompact ? .infinity : 230, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    func timePicker(_ title: String, selection: Binding<Date>) -> some View {
        #if os(macOS)
        DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
        #else
        DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
        #endif
    }

    func timeBinding(for edge: TimeRangeEdge) -> Binding<Date> {
        Binding(
            get: {
                let range = TimeRangeValue(option.value)
                return edge == .start ? range.startDate : range.endDate
            },
            set: { newValue in
                var range = TimeRangeValue(option.value)
                switch edge {
                case .start:
                    range.startDate = newValue
                case .end:
                    range.endDate = newValue
                }
                option.value = range.storageValue
            }
        )
    }
}

private extension FlowLayoutHorizontalAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}

enum TimeRangeEdge {
    case start
    case end
}

struct TimeRangeValue {
    static let defaultStart = "22:00"
    static let defaultEnd = "08:00"

    var start: String
    var end: String

    init(_ storageValue: String) {
        let parts = storageValue.split(separator: "-", maxSplits: 1).map(String.init)
        start = parts.first ?? Self.defaultStart
        end = parts.dropFirst().first ?? Self.defaultEnd
    }

    var startDate: Date {
        get { Self.date(from: start) }
        set { start = Self.string(from: newValue) }
    }

    var endDate: Date {
        get { Self.date(from: end) }
        set { end = Self.string(from: newValue) }
    }

    var storageValue: String {
        "\(start)-\(end)"
    }

    static func date(from value: String) -> Date {
        let parts = value.split(separator: ":", maxSplits: 1).compactMap { Int($0) }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = parts.indices.contains(0) ? parts[0] : 0
        components.minute = parts.indices.contains(1) ? parts[1] : 0
        return components.date ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func string(from date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

struct OptionBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(AppTheme.separator))
    }
}

struct ApplyOptionsBar: View {
    @ObservedObject var model: AffectiveViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            applyLayout(isStacked: false)
            applyLayout(isStacked: true)
        }
    }

    func applyLayout(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    dirtyLabel
                    applyButton
                }
            } else {
                HStack(spacing: 12) {
                    dirtyLabel
                    Spacer()
                    applyButton
                }
            }
        }
    }

    var dirtyLabel: some View {
        Text(dirtyText)
            .font(.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.panelBackground.opacity(0.7), in: Capsule())
            .overlay(Capsule().stroke(AppTheme.separator))
    }

    var applyButton: some View {
        Button {
            model.applyOptions()
        } label: {
            Label("Apply Changes", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.dirtyOptionCount == 0)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    var dirtyText: String {
        if model.dirtyOptionCount == 0 {
            return "No unsaved changes"
        }
        let base = "\(model.dirtyOptionCount) unsaved \(model.dirtyOptionCount == 1 ? "change" : "changes")"
        if model.restartDirtyCount > 0 {
            return "\(base), \(model.restartDirtyCount) after restart"
        }
        return base
    }
}
