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
                    Label("Save Avatar", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasRenderableLayer)
            }
        }
        .padding(22)
        .background(AppTheme.sidebarBackground)
    }

    var canvasPane: some View {
        GeometryReader { proxy in
            let canvasSize = fittedPreviewSize(in: proxy.size)
            let canvasWidth = normalizedDimension(model.canvasWidth, fallback: 1024)
            let rawScale = canvasWidth > 0 ? canvasSize.width / canvasWidth : 1
            let scale = rawScale.isFinite && rawScale > 0 ? rawScale : 1

            ZStack {
                AppTheme.controlBackground

                ZStack(alignment: .topLeading) {
                    if model.editorSection == .atlases,
                       let selectedIndex = model.selectedAtlasSlotIndex {
                        AtlasSheetPreview(
                            slot: $model.slots[selectedIndex],
                            imageURL: model.assetURL(for: model.slots[selectedIndex])
                        )
                    } else {
                        LayeredAvatarView(
                            manifest: model.canvasPreviewManifest,
                            expressionID: model.canvasPreviewExpressionID,
                            ignoresClip: true
                        )
                    }

                    if model.editorSection == .layout,
                       let selectedIndex = model.selectedSlotIndex,
                       model.slots[selectedIndex].relativePath != nil {
                        LayerResizeOverlay(
                            slot: $model.slots[selectedIndex],
                            scale: scale,
                            canvasWidth: model.canvasWidth,
                            canvasHeight: model.canvasHeight
                        )
                    }

                    if model.editorSection == .clip {
                        let clipWidth = normalizedDimension(model.clipWidth, fallback: 1)
                        let clipHeight = normalizedDimension(model.clipHeight, fallback: 1)
                        let clipX = normalizedDimension(model.clipX, fallback: 0)
                        let clipY = normalizedDimension(model.clipY, fallback: 0)
                        Rectangle()
                            .fill(.black.opacity(0.20))
                            .overlay(
                                Rectangle()
                                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                            )
                            .frame(width: clipWidth * scale, height: clipHeight * scale)
                            .position(
                                x: (clipX + clipWidth / 2) * scale,
                                y: (clipY + clipHeight / 2) * scale
                            )

                        Text("\(Int(clipWidth)) x \(Int(clipHeight))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(AppTheme.accent.opacity(0.92), in: Capsule())
                            .foregroundStyle(AppTheme.textOnAccent)
                            .position(
                                x: clipX * scale + 52,
                                y: clipY * scale + 22
                            )
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.separator)
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if model.editorSection == .clip {
                                if dragOrigin == nil {
                                    dragOrigin = CGPoint(x: model.clipX, y: model.clipY)
                                }
                                guard let dragOrigin else { return }
                                model.moveClipFrame(
                                    x: dragOrigin.x + value.translation.width / scale,
                                    y: dragOrigin.y + value.translation.height / scale
                                )
                                return
                            }

                            guard model.editorSection == .layout,
                                  let index = model.selectedSlotIndex
                            else { return }
                            if dragOrigin == nil {
                                dragOrigin = CGPoint(x: model.slots[index].x, y: model.slots[index].y)
                            }
                            guard let dragOrigin else { return }
                            model.slots[index].x = max(0, dragOrigin.x + value.translation.width / scale)
                            model.slots[index].y = max(0, dragOrigin.y + value.translation.height / scale)
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
            }
        }
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
            HStack {
                Picker("Default", selection: $model.defaultExpressionID) {
                    ForEach(model.expressions) { expression in
                        Text(expression.name).tag(expression.id)
                    }
                }
                .frame(maxWidth: 190)

                Spacer()

                Button {
                    model.seedNeutralExpression()
                } label: {
                    Label("Seed Neutral", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }

            expressionPreviewStrip

            VStack(alignment: .leading, spacing: 10) {
                Text("Expression Frames")
                    .font(.headline)

                if let selectedIndex = model.selectedExpressionIndex {
                    expressionRow(for: $model.expressions[selectedIndex])
                } else {
                    Text("Select an expression to edit its frames.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    var expressionPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.expressions) { expression in
                    Button {
                        model.previewExpressionID = expression.id
                    } label: {
                        Text(expression.name)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.previewExpressionID == expression.id ? AppTheme.accent : .secondary)
                }
            }
        }
    }

    func expressionRow(for expression: Binding<AvatarExpressionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(expression.wrappedValue.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.defaultExpressionID == expression.wrappedValue.id {
                    Text("Default")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    frameCell("Eyes", frame: expression.eyesFrame)
                    frameCell("Mouth", frame: expression.mouthFrame)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blink Frames")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        TextField("0,1,2,1", text: expression.blinkFramesText)
                            .textFieldStyle(.plain)
                            .optionFieldStyle(isDirty: false)
                            .frame(minWidth: 120, maxWidth: 160)
                    }
                    numberField("Blink FPS", value: expression.blinkFPS)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                expressionAtlasPicker(title: "Eyes Atlas", kind: .eyes, selection: expression.eyesFrame)
                expressionAtlasPicker(title: "Mouth Atlas", kind: .mouth, selection: expression.mouthFrame)
            }
        }
        .padding(12)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.separator)
        )
    }

    func frameCell(_ title: String, frame: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            TextField(title, value: frame, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .optionFieldStyle(isDirty: false)
                .frame(minWidth: 120, maxWidth: 160)
        }
    }

    @ViewBuilder
    func expressionAtlasPicker(title: String, kind: AvatarSlot.Kind, selection: Binding<Int>) -> some View {
        if let slot = model.slot(kind: kind), slot.usesAtlas {
            AtlasFramePicker(
                title: title,
                slot: slot,
                imageURL: model.assetURL(for: slot),
                selectedFrame: selection,
                compact: true
            )
        }
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

    func numericGrid(for slot: Binding<AvatarSlot>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                numberField("X", value: slot.x)
                numberField("Y", value: slot.y)
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
                numberField("Frame H", value: slot.frameHeight)
            }
            GridRow {
                intField("Columns", value: slot.columns)
                intField("Rows", value: slot.rows)
            }
            GridRow {
                intField("Frames", value: slot.frames)
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
                Text("This is the saved avatar boundary. Drag the frame on the preview or enter exact values.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
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
            .onChange(of: model.clipWidth) { _, _ in model.scheduleClipFrameConstraint() }
            .onChange(of: model.clipHeight) { _, _ in model.scheduleClipFrameConstraint() }

            HStack(spacing: 8) {
                Button {
                    model.resetClipToCanvas()
                } label: {
                    Label("Full Canvas", systemImage: "rectangle.expand.vertical")
                }
                .buttonStyle(.bordered)

                Button {
                    model.centerSquareClip()
                } label: {
                    Label("Center Square", systemImage: "square")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
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

    func intField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .optionFieldStyle(isDirty: false)
                .frame(minWidth: 120, maxWidth: 160)
        }
    }

    func fittedCanvasSize(in size: CGSize) -> CGSize {
        let canvasWidth = normalizedDimension(model.canvasWidth, fallback: 1024)
        let canvasHeight = normalizedDimension(model.canvasHeight, fallback: 1024)
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

    func fittedPreviewSize(in size: CGSize) -> CGSize {
        guard
            model.editorSection == .atlases,
            let slot = model.selectedAtlasSlot,
            let imageURL = model.assetURL(for: slot),
            let image = NSImage(contentsOf: imageURL),
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

    func normalizedDimension(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else {
            avatarLogger.error("Invalid avatar dimension value=\(value, privacy: .public)")
            return fallback
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
        model.setAsset(url, for: slotID)
    }

    func save() {
        do {
            try model.copyPendingAssets()
            let updated = try library.saveAvatarManifest(model.savedManifest, for: brain)
            model.statusText = "Saved avatar for \(updated.displayName)."
        } catch {
            model.statusText = "Save failed: \(error.localizedDescription)"
        }
    }
}

#endif
