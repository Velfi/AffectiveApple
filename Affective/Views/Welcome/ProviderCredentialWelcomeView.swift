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

struct APIKeyWelcomeView: View {
    let continueToApp: () -> Void
    let bypass: () -> Void
    @State private var credentials = Dictionary(uniqueKeysWithValues: ProviderCredentialKey.allCases.map { ($0, "") })
    @State private var errorText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var hasEnteredCredential: Bool {
        credentials.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact && verticalSizeClass == .compact {
                HStack(spacing: 0) {
                    ScrollView {
                        introduction
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 310)
                    .background(AppTheme.sidebarBackground)

                    Divider()
                        .overlay(.white.opacity(0.06))

                    credentialForm
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    desktopWelcomeLayout
                    compactWelcomeLayout
                }
            }
        }
        .background(AppTheme.controlBackground)
        .keyboardDoneToolbar()
    }

    var desktopWelcomeLayout: some View {
        HStack(spacing: 0) {
            introduction
                .frame(width: 430, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.sidebarBackground)

            Divider()
                .overlay(.white.opacity(0.06))

            credentialForm
        }
    }

    var compactWelcomeLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                introduction
                credentialFormContent
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var introduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Affective")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Add at least one model provider key before waking a brain.")
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomePlainLanguageRow(
                    symbolName: "lock.shield",
                    title: "Your keys stay on this device.",
                    message: "Affective stores API keys in Keychain, the system password store."
                )

                WelcomePlainLanguageRow(
                    symbolName: "arrow.left.arrow.right",
                    title: "Affective uses them only for model calls.",
                    message: "When a brain asks OpenAI, Anthropic, or Google for a response, Affective attaches the matching key so that provider can bill your account."
                )

                WelcomePlainLanguageRow(
                    symbolName: "slider.horizontal.3",
                    title: "You stay in control.",
                    message: "You can add, replace, or remove keys later from Host settings."
                )
            }

            Spacer(minLength: 12)

            BuildBadgeView()
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 8 : 44)
        .padding(.vertical, horizontalSizeClass == .compact ? 4 : 44)
    }

    var credentialForm: some View {
        ScrollView {
            credentialFormContent
            .padding(36)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var credentialFormContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Provider Keys")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
                Text("Paste whichever account key you want Affective to use. One is enough to continue.")
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            VStack(spacing: 12) {
                ForEach(ProviderCredentialKey.allCases, id: \.self) { key in
                    ProviderCredentialEntryRow(
                        provider: key,
                        credential: credentialBinding(for: key)
                    )
                }
            }

            if !errorText.isEmpty {
                StatusNoteCard(
                    text: errorText,
                    systemImage: "exclamationmark.triangle",
                    tint: .orange
                )
                .frame(maxWidth: 720, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                credentialActions(isStacked: false)
                credentialActions(isStacked: true)
            }
            .padding(.top, 4)

            StatusNoteCard(
                text: "The skip button is here for local development and advanced setups. Affective also picks up keys from standard provider environment variables, so click \"Nevermind\" if that is how you configure them. If no key is configured, model requests may fail until one is added in Host settings.",
                systemImage: "wrench.and.screwdriver"
            )
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    func credentialActions(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 10) {
                    saveCredentialButton
                    bypassButton
                }
            } else {
                HStack(spacing: 12) {
                    saveCredentialButton
                    bypassButton
                    Spacer()
                }
            }
        }
    }

    var saveCredentialButton: some View {
        Button {
            saveAndContinue()
        } label: {
            Label("Save Key(s) and Continue", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!hasEnteredCredential)
    }

    var bypassButton: some View {
        Button {
            bypass()
        } label: {
            Label("Nevermind, I know what I'm doing", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    func credentialBinding(for key: ProviderCredentialKey) -> Binding<String> {
        Binding(
            get: { credentials[key, default: ""] },
            set: { credentials[key] = $0 }
        )
    }

    func saveAndContinue() {
        #if canImport(UIKit)
        UIApplication.shared.dismissKeyboard()
        #endif
        do {
            try AffectiveViewModel.saveProviderCredentials(credentials)
            continueToApp()
        } catch {
            errorText = "Could not save API key(s): \(error.localizedDescription)"
        }
    }
}

struct WelcomePlainLanguageRow: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderCredentialEntryRow: View {
    let provider: ProviderCredentialKey
    @Binding var credential: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                header(isStacked: false)
                header(isStacked: true)
            }

            SecureField(provider.fieldLabel, text: $credential)
                .textFieldStyle(.plain)
                .optionFieldStyle(isDirty: !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(15)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08))
        )
    }

    func header(isStacked: Bool) -> some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 8) {
                    providerText
                    keyLink
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    providerText
                    Spacer(minLength: 12)
                    keyLink
                }
            }
        }
    }

    var providerText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.fieldLabel)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(provider.creationURL.host ?? provider.creationURL.absoluteString)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    var keyLink: some View {
        Link(destination: provider.creationURL) {
            Label("Create/manage key", systemImage: "key")
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AppTheme.accent)
        .help("Open \(provider.displayName) key page")
    }
}
