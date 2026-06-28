#if os(macOS)
import AppKit
import Combine
import SwiftUI
import os
import UniformTypeIdentifiers

private let avatarLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "avatar-editor")

struct AvatarEditorWindow: View {
    let brainID: String?
    @StateObject private var library = BrainLibrary()

    var body: some View {
        Group {
            if let brain {
                AvatarEditorView(brain: brain, library: library)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.square.badge.exclamationmark")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text("Open a brain before editing its avatar.")
                        .font(.headline)
                    Text("The avatar editor saves assets into the selected brain folder.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(minWidth: 520, minHeight: 320)
                .background(AppTheme.background)
                .foregroundStyle(AppTheme.primaryText)
            }
        }
    }

    private var brain: BrainDescriptor? {
        if let brainID {
            return library.brains.first { $0.id == brainID }
        }
        if let lastID = UserDefaults.standard.string(forKey: AffectiveViewModel.lastOpenedBrainIDKey) {
            return library.brains.first { $0.id == lastID }
        }
        return library.recencySortedBrains.first
    }
}

struct AvatarEditorView: View {
    let brain: BrainDescriptor
    @ObservedObject var library: BrainLibrary
    @StateObject private var model: AvatarEditorModel
    @State private var dragOrigin: CGPoint?
    @State private var viewportZoom: Double = 1
    @State private var viewportPan: CGSize = .zero
    @State private var showOverwriteConfirmation = false
    @State private var generationStartedAt: Date?
    @State private var expandedPreviewKind: AvatarKitAssetKind?

    init(brain: BrainDescriptor, library: BrainLibrary) {
        self.brain = brain
        self.library = library
        AppTheme.applyTheme(for: brain)
        _model = StateObject(wrappedValue: AvatarEditorModel(brain: brain))
    }

    var body: some View {
        HStack(spacing: 0) {
            editorSidebar
                .frame(width: model.editorSection.sidebarWidth)

            Divider()
                .overlay(AppTheme.softSeparator)

            canvasPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .frame(minWidth: model.editorSection.sidebarWidth + 680, minHeight: 760)
        .onAppear {
            model.refreshCredentialStatus()
        }
        .onChange(of: model.editorSection) { _, section in
            viewportZoom = 1
            viewportPan = .zero
            if section == .generate {
                model.refreshCredentialStatus()
            }
        }
        .onChange(of: model.isGenerating) { _, isGenerating in
            if !isGenerating {
                generationStartedAt = nil
            }
        }
        .sheet(item: $expandedPreviewKind) { kind in
            avatarKitAssetPreviewSheet(for: kind)
        }
    }

    var editorSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Avatar Editor")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(brain.displayName)
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            SegmentedControl(
                selection: $model.editorSection,
                options: AvatarEditorSection.allCases.map {
                    .init(value: $0, title: $0.title, systemImage: $0.systemImage)
                }
            )

            Divider()
                .overlay(AppTheme.softSeparator)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.editorSection {
                    case .generate:
                        generateControls
                    case .layout:
                        layoutControls
                    case .atlases:
                        atlasMappingControls
                    case .expressions:
                        expressionControls
                    case .clip:
                        clipControls
                    }

                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(role: .destructive) {
                    model.resetSelectedLayerToDefaults()
                } label: {
                    Label("Reset layer to defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.danger)
                .disabled(!model.canResetSelectedLayer)

                Spacer()

                Button {
                    save()
                } label: {
                    Label(model.highlightsSave ? "Save Avatar Now" : "Save Avatar", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(model.highlightsSave ? .orange : nil)
                .disabled(!model.hasRenderableLayer)
            }
        }
        .padding(22)
        .background(AppTheme.sidebarBackground)
    }

    func layoutConfidenceBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.layoutConfidenceWarning = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.orange.opacity(0.35))
        )
    }

    var canvasPane: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.controlBackground

                if model.isGenerating {
                    generatingCanvasPane(size: proxy.size)
                } else if model.editorSection == .atlases,
                   let selectedIndex = model.selectedAtlasSlotIndex {
                    atlasCanvasPane(size: proxy.size, selectedIndex: selectedIndex)
                } else {
                    layoutOrClipCanvasPane(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    func generatingCanvasPane(size: CGSize) -> some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text(model.generationStep?.title ?? "Generating avatar kit")
                    .font(.title3.weight(.semibold))
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let startedAt = generationStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { _ in
                    Text("Elapsed \(elapsedGenerationText(since: startedAt))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            Button(role: .destructive) {
                model.cancelGeneration()
            } label: {
                Label("Cancel Generation", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    func elapsedGenerationText(since start: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(start)), 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remainder)s"
        }
        return "\(remainder)s"
    }

    @ViewBuilder
    func atlasCanvasPane(size: CGSize, selectedIndex: Int) -> some View {
        ZStack(alignment: .top) {
            let canvasSize = fittedPreviewSize(in: size)
            ZStack(alignment: .topLeading) {
                AtlasSheetPreview(
                    slot: $model.slots[selectedIndex],
                    imageURL: model.assetURL(for: model.slots[selectedIndex])
                )
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.separator)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let warning = model.layoutConfidenceWarning {
                layoutConfidenceBanner(warning)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    func layoutOrClipCanvasPane(size: CGSize) -> some View {
        ZStack {
            layoutOrClipCanvasContent

            if let warning = model.layoutConfidenceWarning,
               model.editorSection == .layout || model.editorSection == .atlases {
                VStack {
                    layoutConfidenceBanner(warning)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    Spacer()
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    var layoutOrClipCanvasContent: some View {
        let worldBounds = model.worldContentBounds(editorSection: model.editorSection)
        AvatarEditorCanvasViewport(
            zoom: $viewportZoom,
            pan: $viewportPan,
            worldBounds: worldBounds
        ) { scale in
            ZStack(alignment: .topLeading) {
                LayeredAvatarView(
                    manifest: model.canvasPreviewManifest,
                    expressionID: model.editorSection == .atlases ? nil : "neutral",
                    eyeSprite: model.editorSection == .atlases ? nil : model.previewEyeName,
                    mouthSprite: model.editorSection == .atlases ? nil : model.previewMouthName,
                    ignoresClip: true,
                    contentAlignment: .center,
                    assetURLForPath: model.assetURL(forRelativePath:)
                )
                .frame(
                    width: normalizedDimension(model.canvasWidth, defaultValue: 1024) * scale,
                    height: normalizedDimension(model.canvasHeight, defaultValue: 1024) * scale
                )

                if model.editorSection == .clip {
                    ClipDimmingOverlay(
                        clipX: model.clipX,
                        clipY: model.clipY,
                        clipWidth: model.clipWidth,
                        clipHeight: model.clipHeight,
                        worldBounds: worldBounds,
                        scale: scale
                    )
                    ClipFrameOverlay(
                        clipX: $model.clipX,
                        clipY: $model.clipY,
                        clipWidth: $model.clipWidth,
                        clipHeight: $model.clipHeight,
                        aspectMode: model.clipAspectMode,
                        worldBounds: worldBounds,
                        scale: scale
                    )
                    .onChange(of: model.clipX) { _, _ in model.scheduleClipFrameConstraint() }
                    .onChange(of: model.clipY) { _, _ in model.scheduleClipFrameConstraint() }
                    .onChange(of: model.clipWidth) { _, _ in model.scheduleClipFrameConstraint(driving: .width) }
                    .onChange(of: model.clipHeight) { _, _ in model.scheduleClipFrameConstraint(driving: .height) }
                }

                if model.editorSection == .layout,
                   let selectedIndex = model.selectedSlotIndex,
                   model.slots[selectedIndex].hasRenderableContent {
                    LayerResizeOverlay(
                        slot: $model.slots[selectedIndex],
                        scale: scale,
                        worldBounds: worldBounds
                    )
                }
            }
            .frame(width: worldBounds.width * scale, height: worldBounds.height * scale, alignment: .topLeading)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.separator)
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard model.editorSection == .layout,
                              let index = model.selectedSlotIndex
                        else { return }
                        if dragOrigin == nil {
                            dragOrigin = CGPoint(x: model.slots[index].x, y: model.slots[index].y)
                        }
                        guard let dragOrigin else { return }
                        model.slots[index].x = dragOrigin.x + value.translation.width / scale
                        model.slots[index].y = dragOrigin.y + value.translation.height / scale
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var generateControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            credentialReadinessPanel

            VStack(alignment: .leading, spacing: 6) {
                Text("Character Brief")
                    .font(.headline)
                Text("Describe the character. Generation creates a base head plus 4×4 eye and mouth atlases. Assets stay staged until you save.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .topLeading) {
                if model.characterBrief.isEmpty {
                    Text("Example: A teal fox with round glasses, soft fur, and a friendly curious expression.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.characterBrief)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .disabled(model.isGenerating || model.regeneratingAssetKind != nil)
            }

            HStack(spacing: 10) {
                Button {
                    if model.hasExistingAvatarAssets, model.generationError == nil {
                        showOverwriteConfirmation = true
                    } else {
                        generationStartedAt = Date()
                        model.requestGenerateAvatarKit(resume: false)
                    }
                } label: {
                    if model.isGenerating {
                        Label("Generating…", systemImage: "hourglass")
                    } else if model.generationError != nil {
                        Label("Start Over", systemImage: "arrow.clockwise")
                    } else {
                        Label("Generate Avatar Kit", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canGenerateAvatarKit)

                if model.canResumeGeneration {
                    Button {
                        generationStartedAt = Date()
                        model.requestGenerateAvatarKit(resume: true)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if model.isGenerating {
                    Button(role: .destructive) {
                        model.cancelGeneration()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .confirmationDialog(
                "Replace existing avatar?",
                isPresented: $showOverwriteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Replace Existing Avatar", role: .destructive) {
                    generationStartedAt = Date()
                    model.requestGenerateAvatarKit(resume: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Generated images replace the current editor preview. Your saved avatar files are not changed until you click Save Avatar.")
            }

            if let error = model.generationError {
                generationErrorBanner(error)
            }

            if model.isGenerating || !model.completedGenerationSteps.isEmpty || model.generationError != nil {
                generationProgressList
            }

            if model.hasAnyGeneratedPreview {
                generatedPreviewGrid
            }

            if model.highlightsSave {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.orange)
                    Text("Save Avatar to write staged images and avatar.json.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .padding(10)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    var credentialReadinessPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requirements")
                .font(.subheadline.weight(.semibold))

            credentialRow(
                title: "Google API key",
                detail: "Image generation",
                isReady: model.credentialStatus.hasGoogleCredential
            )
            credentialRow(
                title: "Vision provider key",
                detail: "OpenAI, Anthropic, Google, or DeepSeek",
                isReady: model.credentialStatus.hasVisionCredential
            )

            if !model.credentialStatus.isReady {
                Text("Configure missing keys in Affective Settings before generating.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(10)
        .background(AppTheme.controlBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func credentialRow(title: String, detail: String, isReady: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
        }
    }

    func generationErrorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Generation failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            Text(error)
                .font(.caption)
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if model.canResumeGeneration {
                Text("Resume continues from the last completed step without regenerating finished images.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.red.opacity(0.25))
        )
    }

    var generationProgressList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress")
                .font(.subheadline.weight(.semibold))

            ForEach(AvatarKitGenerationStep.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    if model.generationStep == step {
                        ProgressView()
                            .controlSize(.small)
                    } else if model.failedGenerationStep == step {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if model.completedGenerationSteps.contains(step)
                        || isGenerationStepComplete(step) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(model.generationStep == step ? AppTheme.primaryText : AppTheme.secondaryText)
                }
            }
        }
    }

    var generatedPreviewGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated Assets")
                .font(.subheadline.weight(.semibold))
            Text("Click a thumbnail to expand. Retry replaces one layer without regenerating the full kit.")
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)

            HStack(alignment: .top, spacing: 10) {
                ForEach(AvatarKitAssetKind.allCases) { kind in
                    generatedPreviewCard(for: kind)
                }
            }
        }
    }

    @ViewBuilder
    func generatedPreviewCard(for kind: AvatarKitAssetKind) -> some View {
        VStack(spacing: 6) {
            if let url = model.previewURL(for: kind),
               let image = generatedPreviewImage(at: url) {
                Button {
                    expandedPreviewKind = kind
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .background(transparencyCheckerboard(cellSize: 8))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(AppTheme.separator)
                        )
                }
                .buttonStyle(.plain)
                .help("Expand \(kind.layerTitle)")
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.controlBackground)
                    .frame(width: 88, height: 88)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
            }

            Text(kind.assetFileName)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.secondaryText)

            Button {
                model.requestRegenerateAsset(kind)
            } label: {
                if model.regeneratingAssetKind == kind {
                    Label("Retrying…", systemImage: "hourglass")
                } else {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canRegenerateAsset(kind))
        }
    }

    func avatarKitAssetPreviewSheet(for kind: AvatarKitAssetKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.layerTitle)
                        .font(.title2.weight(.semibold))
                    Text(kind.assetFileName)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button("Close") {
                    expandedPreviewKind = nil
                }
            }

            if let url = model.previewURL(for: kind),
               let image = generatedPreviewImage(at: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: 1200,
                            maxHeight: 900
                        )
                        .frame(minWidth: 320, minHeight: 320)
                        .background(transparencyCheckerboard(cellSize: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
            }

            HStack {
                Button {
                    expandedPreviewKind = nil
                    model.requestRegenerateAsset(kind)
                } label: {
                    if model.regeneratingAssetKind == kind {
                        Label("Retrying \(kind.layerTitle)…", systemImage: "hourglass")
                    } else {
                        Label("Retry \(kind.layerTitle)", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRegenerateAsset(kind))

                Spacer()

                Button("Close") {
                    expandedPreviewKind = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 520)
    }

    func transparencyCheckerboard(cellSize: CGFloat) -> some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for column in 0..<columns {
                    let isDark = (row + column).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(column) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isDark ? Color.black.opacity(0.08) : Color.white.opacity(0.9))
                    )
                }
            }
        }
    }

    func isGenerationStepComplete(_ step: AvatarKitGenerationStep) -> Bool {
        guard let current = model.generationStep else {
            return !model.isGenerating && !model.generatedPreviewURLs.isEmpty
        }
        guard let currentIndex = AvatarKitGenerationStep.allCases.firstIndex(of: current),
              let stepIndex = AvatarKitGenerationStep.allCases.firstIndex(of: step)
        else {
            return false
        }
        return stepIndex < currentIndex
    }

    var layoutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Layer", selection: $model.selectedSlotID) {
                ForEach($model.slots) { $slot in
                    Label(slot.title, systemImage: slot.systemImage)
                        .tag(slot.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .frame(maxHeight: 190)

            if let selectedIndex = model.selectedSlotIndex {
                selectedLayerControls(for: $model.slots[selectedIndex])
            }

            canvasControls
        }
    }

    var atlasMappingControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedControl(
                selection: $model.selectedAtlasSlotID,
                options: model.atlasSlots.map {
                    .init(value: $0.id, title: $0.title, systemImage: $0.systemImage)
                }
            )

            if let selectedIndex = model.selectedAtlasSlotIndex {
                selectedLayerControls(for: $model.slots[selectedIndex])
                AtlasFramePicker(
                    slot: model.slots[selectedIndex],
                    imageURL: model.assetURL(for: model.slots[selectedIndex]),
                    selectedFrame: $model.slots[selectedIndex].selectedFrame
                )
            }
        }
    }

    var expressionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            neutralPairControls

            Text("Name each atlas cell so the expression capability can surface eyes and mouth sprites for this avatar.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    model.copyLLMTemplateToClipboard()
                } label: {
                    Label("Copy LLM Template", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(model.eyeSprites.isEmpty || model.mouthSprites.isEmpty)

                Button {
                    model.pasteLLMTemplateFromClipboard()
                } label: {
                    Label("Paste LLM Template", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(model.eyeSprites.isEmpty || model.mouthSprites.isEmpty)
            }

            spriteTable(
                title: "Eyes",
                sprites: $model.eyeSprites,
                selectedName: model.previewEyeName,
                onSelect: model.previewEyeSprite(frame:)
            )

            spriteTable(
                title: "Mouth",
                sprites: $model.mouthSprites,
                selectedName: model.previewMouthName,
                onSelect: model.previewMouthSprite(frame:)
            )
        }
    }

    var neutralPairControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neutral Pair")
                .font(.headline)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Eyes")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Picker("Eyes", selection: $model.neutralEyeName) {
                        ForEach(model.eyeSprites) { sprite in
                            Text(sprite.name).tag(sprite.name)
                        }
                    }
                    .labelsHidden()
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mouth")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Picker("Mouth", selection: $model.neutralMouthName) {
                        ForEach(model.mouthSprites) { sprite in
                            Text(sprite.name).tag(sprite.name)
                        }
                    }
                    .labelsHidden()
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Blink Frames")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    TextField("0,14,15,14,0", text: $model.neutralBlinkFramesText)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .optionFieldStyle(isDirty: false)
                }
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Blink FPS")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    TextField("FPS", value: $model.neutralBlinkFPS, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .optionFieldStyle(isDirty: false)
                        .frame(width: 52)
                }
            }
        }
        .padding(12)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    func spriteTable(
        title: String,
        sprites: Binding<[AvatarAtlasSprite]>,
        selectedName: String,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Frame")
                        .frame(width: 44, alignment: .trailing)
                    Text("Row")
                        .frame(width: 36, alignment: .trailing)
                    Text("Col")
                        .frame(width: 36, alignment: .trailing)
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
                    .overlay(AppTheme.separator)

                if sprites.wrappedValue.isEmpty {
                    Text("Configure the \(title.lowercased()) atlas first.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(Array(sprites.wrappedValue.indices), id: \.self) { index in
                        spriteTableRow(
                            for: sprites[index],
                            isSelected: sprites.wrappedValue[index].name == selectedName
                        ) {
                            onSelect(sprites.wrappedValue[index].frame)
                        }
                        if index != sprites.wrappedValue.indices.last {
                            Divider()
                                .overlay(AppTheme.separator)
                        }
                    }
                }
            }
            .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.separator)
            )
        }
    }

    func spriteTableRow(
        for sprite: Binding<AvatarAtlasSprite>,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(sprite.wrappedValue.frame)")
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Text("\(sprite.wrappedValue.row)")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text("\(sprite.wrappedValue.column)")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            TextField("name", text: sprite.name)
                .textFieldStyle(.plain)
                .font(.callout)
                .optionFieldStyle(isDirty: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? AppTheme.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    func selectedLayerControls(for slot: Binding<AvatarSlot>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(slot.wrappedValue.title, systemImage: slot.wrappedValue.systemImage)
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: slot.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            HStack(spacing: 10) {
                Button {
                    chooseImage(for: slot.wrappedValue.id)
                } label: {
                    Label(slot.wrappedValue.usesAtlas ? "Choose Atlas" : "Choose Image", systemImage: "photo")
                }
                .buttonStyle(.bordered)

                Button {
                    model.clear(slotID: slot.wrappedValue.id)
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(slot.wrappedValue.relativePath == nil)
            }

            if let path = slot.wrappedValue.relativePath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }

            if slot.wrappedValue.kind == .background, slot.wrappedValue.relativePath == nil {
                backgroundColorControls(for: slot)
            }

            numericGrid(for: slot)

            if slot.wrappedValue.supportsAtlas {
                atlasModeControls(for: slot)
            }

            if slot.wrappedValue.usesAtlas {
                atlasControls(for: slot)
            }

            if slot.wrappedValue.supportsAtlas, slot.wrappedValue.relativePath != nil {
                Button {
                    model.autodetectAtlas(slotID: slot.wrappedValue.id)
                } label: {
                    Label("Autodetect Sprite Atlas", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    func syncBackgroundSlotGeometry(_ slot: Binding<AvatarSlot>) {
        guard slot.wrappedValue.kind == .background else { return }
        slot.wrappedValue.x = model.canvasWidth / 2
        slot.wrappedValue.y = model.canvasHeight / 2
        slot.wrappedValue.width = model.canvasWidth
        slot.wrappedValue.height = model.canvasHeight
    }

    func backgroundColorControls(for slot: Binding<AvatarSlot>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Transparent", isOn: slot.isBackgroundTransparent)
                .toggleStyle(.switch)
                .onChange(of: slot.wrappedValue.isBackgroundTransparent) { _, isTransparent in
                    if isTransparent {
                        slot.wrappedValue.backgroundColor = nil
                    }
                    syncBackgroundSlotGeometry(slot)
                }

            if !slot.wrappedValue.isBackgroundTransparent {
                ColorPicker("Background Color", selection: Binding(
                    get: { slot.wrappedValue.backgroundColor ?? .white },
                    set: { newColor in
                        slot.wrappedValue.backgroundColor = newColor
                        slot.wrappedValue.isBackgroundTransparent = false
                        syncBackgroundSlotGeometry(slot)
                    }
                ))
            }

            Text("Solid color or transparency applies when no background image is uploaded.")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func numericGrid(for slot: Binding<AvatarSlot>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                numberField("Center X", value: slot.x)
                numberField("Center Y", value: slot.y)
            }
            GridRow {
                numberField("W", value: slot.width)
                numberField("H", value: slot.height)
            }
        }
    }

    func atlasControls(for slot: Binding<AvatarSlot>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                numberField("Offset X", value: slot.frameX)
                numberField("Offset Y", value: slot.frameY)
            }
            GridRow {
                numberField("Frame W", value: slot.frameWidth)
                    .onChange(of: slot.wrappedValue.frameWidth) { _, _ in
                        model.syncAtlasGrid(for: slot.wrappedValue.id)
                    }
                numberField("Frame H", value: slot.frameHeight)
                    .onChange(of: slot.wrappedValue.frameHeight) { _, _ in
                        model.syncAtlasGrid(for: slot.wrappedValue.id)
                    }
            }
            GridRow {
                intField("Columns", value: slot.columns, slotID: slot.wrappedValue.id)
                intField("Rows", value: slot.rows, slotID: slot.wrappedValue.id)
            }
            GridRow {
                Text("Frames: \(slot.wrappedValue.effectiveFrameCount)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                if slot.wrappedValue.isAnimatedAtlas {
                    numberField("FPS", value: slot.fps)
                } else {
                    intField("Frame", value: slot.selectedFrame)
                }
            }
        }
    }

    func atlasModeControls(for slot: Binding<AvatarSlot>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use sprite atlas", isOn: slot.usesAtlas)
                .toggleStyle(.switch)

            if slot.wrappedValue.usesAtlas && slot.wrappedValue.supportsAnimationToggle {
                Toggle("Animate atlas", isOn: slot.isAnimatedAtlas)
                    .toggleStyle(.switch)
            }
        }
    }

    var canvasControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    numberField("Width", value: $model.canvasWidth)
                    numberField("Height", value: $model.canvasHeight)
                }
            }
            .onChange(of: model.canvasWidth) { _, _ in model.scheduleClipFrameConstraint() }
            .onChange(of: model.canvasHeight) { _, _ in model.scheduleClipFrameConstraint() }
        }
        .padding(14)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    var clipControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clip Frame")
                    .font(.headline)
                Text("Choose an aspect ratio, then drag and scale the crop frame on the canvas. Option-drag to pan; pinch or ⌘+scroll to zoom.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Aspect Ratio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)

                HStack(spacing: 8) {
                    Button {
                        model.setClipAspectFree()
                    } label: {
                        Text("Free")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.centerSquareClip()
                    } label: {
                        Text("1:1")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.setClipAspect(width: 4, height: 5)
                    } label: {
                        Text("4:5")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.setClipAspect(width: 16, height: 9)
                    } label: {
                        Text("16:9")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.setClipAspect(width: 9, height: 16)
                    } label: {
                        Text("9:16")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    numberField("W", value: $model.customClipAspectWidth)
                    numberField("H", value: $model.customClipAspectHeight)
                    Button {
                        model.setClipAspect(width: model.customClipAspectWidth, height: model.customClipAspectHeight)
                    } label: {
                        Text("Apply")
                    }
                    .buttonStyle(.bordered)
                }

                Text("Current: \(model.clipAspectMode.label)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    numberField("X", value: $model.clipX)
                    numberField("Y", value: $model.clipY)
                }
                GridRow {
                    numberField("Width", value: $model.clipWidth)
                    numberField("Height", value: $model.clipHeight)
                }
            }
            .onChange(of: model.clipX) { _, _ in model.scheduleClipFrameConstraint() }
            .onChange(of: model.clipY) { _, _ in model.scheduleClipFrameConstraint() }
            .onChange(of: model.clipWidth) { _, _ in model.scheduleClipFrameConstraint(driving: .width) }
            .onChange(of: model.clipHeight) { _, _ in model.scheduleClipFrameConstraint(driving: .height) }

            Button {
                model.resetClipToCanvas()
            } label: {
                Label("Full Canvas", systemImage: "rectangle.expand.vertical")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    func numberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .optionFieldStyle(isDirty: false)
                .frame(minWidth: 120, maxWidth: 160)
        }
    }

    func intField(_ title: String, value: Binding<Int>, slotID: AvatarSlot.ID? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .optionFieldStyle(isDirty: false)
                .frame(minWidth: 120, maxWidth: 160)
                .onChange(of: value.wrappedValue) { _, _ in
                    if let slotID {
                        model.syncAtlasGrid(for: slotID)
                    }
                }
        }
    }

    func fittedCanvasSize(in size: CGSize) -> CGSize {
        let canvasWidth = normalizedDimension(model.canvasWidth, defaultValue: 1024)
        let canvasHeight = normalizedDimension(model.canvasHeight, defaultValue: 1024)
        let available = CGSize(width: max(size.width - 80, 120), height: max(size.height - 80, 120))
        guard canvasWidth.isFinite, canvasHeight.isFinite, canvasWidth > 0, canvasHeight > 0 else {
            avatarLogger.error("Invalid canvas dimensions width=\(self.model.canvasWidth, privacy: .public) height=\(self.model.canvasHeight, privacy: .public)")
            return CGSize(width: 1024, height: 1024)
        }
        let scale = min(available.width / canvasWidth, available.height / canvasHeight)
        guard scale.isFinite, scale > 0 else {
            avatarLogger.error("Invalid canvas scale availableWidth=\(available.width, privacy: .public) availableHeight=\(available.height, privacy: .public) canvasWidth=\(canvasWidth, privacy: .public) canvasHeight=\(canvasHeight, privacy: .public)")
            return CGSize(width: canvasWidth, height: canvasHeight)
        }
        return CGSize(width: canvasWidth * scale, height: canvasHeight * scale)
    }

    func generatedPreviewImage(at url: URL) -> NSImage? {
        guard let cgImage = try? AvatarKitChromaKey.keyedImageIfNeeded(from: url) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    func fittedPreviewSize(in size: CGSize) -> CGSize {
        guard
            model.editorSection == .atlases,
            let slot = model.selectedAtlasSlot,
            let imageURL = model.assetURL(for: slot),
            let image = AvatarAssetImageLoader.loadImage(from: imageURL, layerID: slot.id),
            let imageSize = image.pixelSize
        else {
            return fittedCanvasSize(in: size)
        }

        let available = CGSize(width: max(size.width - 80, 120), height: max(size.height - 80, 120))
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else {
            avatarLogger.error("Invalid atlas image size width=\(imageSize.width, privacy: .public) height=\(imageSize.height, privacy: .public)")
            return fittedCanvasSize(in: size)
        }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        guard scale.isFinite, scale > 0 else {
            avatarLogger.error("Invalid atlas scale availableWidth=\(available.width, privacy: .public) availableHeight=\(available.height, privacy: .public) imageWidth=\(imageSize.width, privacy: .public) imageHeight=\(imageSize.height, privacy: .public)")
            return CGSize(width: imageSize.width, height: imageSize.height)
        }
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    func normalizedDimension(_ value: Double, defaultValue: Double) -> Double {
        guard value.isFinite, value > 0 else {
            avatarLogger.error("Invalid avatar dimension value=\(value, privacy: .public)")
            return defaultValue
        }
        return value
    }

    func chooseImage(for slotID: AvatarSlot.ID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Avatar Asset"
        panel.prompt = "Use Asset"
        panel.message = "Choose a PNG or JPEG image."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.setAsset(url, for: slotID)
        } catch {
            model.statusText = "Could not use asset: \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            try model.copyPendingAssets()
            let updated = try library.saveAvatarManifest(model.savedManifest, for: brain)
            model.noteAvatarSaved()
            model.statusText = "Saved avatar for \(updated.displayName)."
        } catch {
            model.statusText = "Save failed: \(error.localizedDescription)"
        }
    }
}

#endif
