#if os(macOS)
//
//  Split from AvatarEditorView.swift
//  Affective
//

import AppKit
import Combine
import SwiftUI
import os
import UniformTypeIdentifiers

private let avatarPreviewLogger = Logger(subsystem: "com.zelda-built-this.AMBI", category: "avatar-preview")

struct AtlasSheetPreview: View {
    @Binding var slot: AvatarSlot
    let imageURL: URL?
    @State private var dragState: AtlasGridDragState?

    var body: some View {
        if let imageURL,
           let image = AvatarAssetImageLoader.loadImage(from: imageURL, layerID: slot.id),
           let imageSize = image.pixelSize {
            GeometryReader { proxy in
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()

                    AtlasSheetGrid(slot: slot, imageSize: imageSize)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateGridDrag(value, imageSize: imageSize, viewSize: proxy.size)
                        }
                        .onEnded { _ in
                            dragState = nil
                        }
                )
                .clipped()
            }
        }
    }

    func updateGridDrag(_ value: DragGesture.Value, imageSize: CGSize, viewSize: CGSize) {
        guard
            imageSize.width.isFinite,
            imageSize.height.isFinite,
            viewSize.width.isFinite,
            viewSize.height.isFinite,
            imageSize.width > 0,
            imageSize.height > 0,
            viewSize.width > 0,
            viewSize.height > 0
        else {
            return
        }

        let scaleX = Double(viewSize.width / imageSize.width)
        let scaleY = Double(viewSize.height / imageSize.height)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return }
        let columns = Double(max(slot.columns, 1))
        let rows = Double(max(slot.rows, 1))
        if dragState == nil {
            dragState = AtlasGridDragState(
                operation: dragOperation(at: value.startLocation, scaleX: scaleX, scaleY: scaleY),
                frameX: slot.frameX,
                frameY: slot.frameY,
                frameWidth: slot.frameWidth,
                frameHeight: slot.frameHeight
            )
        }

        guard let dragState else { return }
        let deltaX = value.translation.width / scaleX
        let deltaY = value.translation.height / scaleY

        switch dragState.operation {
        case .origin:
            slot.frameX = clamped(
                dragState.frameX + deltaX,
                lowerBound: 0,
                upperBound: max(Double(imageSize.width) - slot.frameWidth * columns, 0)
            )
            slot.frameY = clamped(
                dragState.frameY + deltaY,
                lowerBound: 0,
                upperBound: max(Double(imageSize.height) - slot.frameHeight * rows, 0)
            )
        case .resize:
            let maximumWidth = max((Double(imageSize.width) - slot.frameX) / columns, 1)
            let maximumHeight = max((Double(imageSize.height) - slot.frameY) / rows, 1)
            slot.frameWidth = clamped(
                dragState.frameWidth + deltaX,
                lowerBound: 1,
                upperBound: maximumWidth
            )
            slot.frameHeight = clamped(
                dragState.frameHeight + deltaY,
                lowerBound: 1,
                upperBound: maximumHeight
            )
        }
    }

    func dragOperation(at location: CGPoint, scaleX: Double, scaleY: Double) -> AtlasGridDragOperation {
        let resizePoint = CGPoint(
            x: (slot.frameX + slot.frameWidth) * scaleX,
            y: (slot.frameY + slot.frameHeight) * scaleY
        )
        return location.distance(to: resizePoint) <= 34 ? .resize : .origin
    }

    func clamped(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        min(max(value, lowerBound), max(upperBound, lowerBound))
    }
}

struct LayerResizeOverlay: View {
    @Binding var slot: AvatarSlot
    let scale: Double
    let worldBounds: CGRect
    @State private var dragState: LayerResizeDragState?

    var body: some View {
        let safeScale = normalizedDimension(scale, defaultValue: 1)
        let topLeft = slot.topLeftOrigin()
        let rect = CGRect(
            x: (topLeft.x - worldBounds.minX) * safeScale,
            y: (topLeft.y - worldBounds.minY) * safeScale,
            width: normalizedDimension(slot.width, defaultValue: 1) * safeScale,
            height: normalizedDimension(slot.height, defaultValue: 1) * safeScale
        )

        ZStack(alignment: .topLeading) {
            if rect.isValidAvatarEditorFrame {
                Rectangle()
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                ForEach(LayerResizeHandle.allCases) { handle in
                    ResizeHandleView()
                        .position(handle.position(in: rect))
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    resize(handle: handle, value: value)
                                }
                                .onEnded { _ in
                                    dragState = nil
                                }
                        )
                }
            }
        }
        .frame(width: worldBounds.width * safeScale, height: worldBounds.height * safeScale, alignment: .topLeading)
    }

    func resize(handle: LayerResizeHandle, value: DragGesture.Value) {
        if dragState == nil {
            dragState = LayerResizeDragState(
                width: slot.width,
                height: slot.height
            )
        }
        guard let dragState else { return }

        let safeScale = normalizedDimension(scale, defaultValue: 1)
        let dx = value.translation.width / safeScale
        let dy = value.translation.height / safeScale
        let minimumSize = 16.0

        switch handle {
        case .topLeading:
            slot.width = max(dragState.width - dx, minimumSize)
            slot.height = max(dragState.height - dy, minimumSize)
        case .topTrailing:
            slot.width = max(dragState.width + dx, minimumSize)
            slot.height = max(dragState.height - dy, minimumSize)
        case .bottomLeading:
            slot.width = max(dragState.width - dx, minimumSize)
            slot.height = max(dragState.height + dy, minimumSize)
        case .bottomTrailing:
            slot.width = max(dragState.width + dx, minimumSize)
            slot.height = max(dragState.height + dy, minimumSize)
        }
    }

    func normalizedDimension(_ value: Double, defaultValue: Double) -> Double {
        guard value.isFinite, value > 0 else {
            avatarPreviewLogger.error("Invalid resize canvas dimension value=\(value, privacy: .public)")
            return defaultValue
        }
        return value
    }
}

struct ResizeHandleView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(AppTheme.accent)
            .frame(width: 14, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.black.opacity(0.55), lineWidth: 2)
            )
            .contentShape(Rectangle())
    }
}

enum LayerResizeHandle: CaseIterable, Hashable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: Self { self }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing:
            CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

struct LayerResizeDragState {
    let width: Double
    let height: Double
}

struct AtlasSheetGrid: View {
    let slot: AvatarSlot
    let imageSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let scaleX = size.width / imageSize.width
            let scaleY = size.height / imageSize.height
            let frameX = CGFloat(slot.frameX)
            let frameY = CGFloat(slot.frameY)
            let frameWidth = CGFloat(max(slot.frameWidth, 1))
            let frameHeight = CGFloat(max(slot.frameHeight, 1))
            let columns = max(slot.columns, 1)
            let rows = max(slot.rows, 1)
            let frames = slot.effectiveFrameCount
            let crossLength = max(min(frameWidth * scaleX, frameHeight * scaleY) * 0.06, 4)

            for index in 0..<min(frames, columns * rows) {
                let column = index % columns
                let row = index / columns
                let rect = CGRect(
                    x: (frameX + CGFloat(column) * frameWidth) * scaleX,
                    y: (frameY + CGFloat(row) * frameHeight) * scaleY,
                    width: frameWidth * scaleX,
                    height: frameHeight * scaleY
                )

                context.stroke(
                    Path(rect),
                    with: .color(.black.opacity(0.45)),
                    lineWidth: 2
                )
                context.stroke(
                    Path(rect),
                    with: .color(.white.opacity(0.70)),
                    lineWidth: 0.75
                )

                let center = CGPoint(x: rect.midX, y: rect.midY)
                var shadowCross = Path()
                shadowCross.move(to: CGPoint(x: center.x - crossLength, y: center.y))
                shadowCross.addLine(to: CGPoint(x: center.x + crossLength, y: center.y))
                shadowCross.move(to: CGPoint(x: center.x, y: center.y - crossLength))
                shadowCross.addLine(to: CGPoint(x: center.x, y: center.y + crossLength))
                context.stroke(
                    shadowCross,
                    with: .color(.black.opacity(0.45)),
                    lineWidth: 2
                )

                var cross = Path()
                cross.move(to: CGPoint(x: center.x - crossLength, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + crossLength, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - crossLength))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + crossLength))
                context.stroke(
                    cross,
                    with: .color(.white.opacity(0.78)),
                    lineWidth: 0.75
                )
            }

            let origin = CGPoint(x: frameX * scaleX, y: frameY * scaleY)
            let resize = CGPoint(
                x: (frameX + frameWidth) * scaleX,
                y: (frameY + frameHeight) * scaleY
            )
            context.fill(Path(ellipseIn: CGRect(x: origin.x - 5, y: origin.y - 5, width: 10, height: 10)), with: .color(AppTheme.accent))
            context.stroke(Path(ellipseIn: CGRect(x: origin.x - 6, y: origin.y - 6, width: 12, height: 12)), with: .color(.black.opacity(0.55)), lineWidth: 2)
            context.fill(Path(CGRect(x: resize.x - 5, y: resize.y - 5, width: 10, height: 10)), with: .color(AppTheme.accent))
            context.stroke(Path(CGRect(x: resize.x - 6, y: resize.y - 6, width: 12, height: 12)), with: .color(.black.opacity(0.55)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

enum AtlasGridDragOperation {
    case origin
    case resize
}

struct AtlasGridDragState {
    let operation: AtlasGridDragOperation
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
}

extension CGPoint {
    func distance(to point: CGPoint) -> Double {
        hypot(x - point.x, y - point.y)
    }
}

extension CGRect {
    var isValidAvatarEditorFrame: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}

struct AtlasFramePicker: View {
    var title = "Atlas Frames"
    let slot: AvatarSlot
    let imageURL: URL?
    @Binding var selectedFrame: Int
    var compact = false

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(compact ? 54 : 68), spacing: 8),
            count: compact ? 3 : 4
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(slot.effectiveFrameCount) frames")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let imageURL, let image = AvatarAssetImageLoader.loadImage(from: imageURL, layerID: slot.id) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(0..<slot.effectiveFrameCount, id: \.self) { frame in
                        Button {
                            selectedFrame = frame
                        } label: {
                            VStack(spacing: 5) {
                                if let frameImage = image.croppedEditorAvatarFrame(
                                    index: frame,
                                    frameX: Int(slot.frameX),
                                    frameY: Int(slot.frameY),
                                    frameWidth: Int(slot.frameWidth),
                                    frameHeight: Int(slot.frameHeight)
                                ) {
                                    Image(nsImage: frameImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: compact ? 48 : 62, height: compact ? 36 : 46)
                                        .clipped()
                                } else {
                                    Rectangle()
                                        .fill(.white.opacity(0.08))
                                        .frame(width: compact ? 48 : 62, height: compact ? 36 : 46)
                                }

                                Text("\(frame)")
                                    .font(.caption2.monospacedDigit())
                            }
                            .padding(5)
                            .frame(width: compact ? 54 : 68)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(frame == selectedFrame ? AppTheme.accent.opacity(0.25) : .white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(frame == selectedFrame ? AppTheme.accent : .white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Choose an atlas image first.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(AppTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08))
        )
    }
}

struct AvatarEditorCanvasViewport<Content: View>: View {
    @Binding var zoom: Double
    @Binding var pan: CGSize
    let worldBounds: CGRect
    @ViewBuilder let content: (_ scale: Double) -> Content

    @State private var panDragOrigin: CGSize?
    @State private var magnificationBaseZoom: Double?

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            let fitScale = fittedScale(viewSize: viewSize, worldBounds: worldBounds)
            let effectiveScale = fitScale * zoom
            let contentWidth = worldBounds.width * effectiveScale
            let contentHeight = worldBounds.height * effectiveScale

            ZStack {
                content(effectiveScale)
                    .frame(width: contentWidth, height: contentHeight)
                    .offset(x: pan.width, y: pan.height)
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .modifiers(.option)
                    .onChanged { value in
                        if panDragOrigin == nil {
                            panDragOrigin = pan
                        }
                        guard let panDragOrigin else { return }
                        pan = CGSize(
                            width: panDragOrigin.width + value.translation.width,
                            height: panDragOrigin.height + value.translation.height
                        )
                    }
                    .onEnded { _ in panDragOrigin = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if magnificationBaseZoom == nil {
                            magnificationBaseZoom = zoom
                        }
                        guard let magnificationBaseZoom else { return }
                        zoom = clampedZoom(magnificationBaseZoom * value)
                    }
                    .onEnded { _ in magnificationBaseZoom = nil }
            )
            .background(ScrollWheelZoomCapture(onZoom: { delta in
                zoom = clampedZoom(zoom * (1 + delta))
            }))
        }
    }

    func fittedScale(viewSize: CGSize, worldBounds: CGRect) -> Double {
        guard viewSize.width > 0, viewSize.height > 0,
              worldBounds.width > 0, worldBounds.height > 0 else {
            return 1
        }
        let horizontal = (viewSize.width * 0.9) / worldBounds.width
        let vertical = (viewSize.height * 0.9) / worldBounds.height
        return min(horizontal, vertical)
    }

    func clampedZoom(_ value: Double) -> Double {
        min(max(value, 0.25), 4)
    }
}

struct ScrollWheelZoomCapture: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ScrollWheelZoomNSView {
        let view = ScrollWheelZoomNSView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ScrollWheelZoomNSView, context: Context) {
        nsView.onZoom = onZoom
    }
}

final class ScrollWheelZoomNSView: NSView {
    var onZoom: ((Double) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.deltaY * 0.02
            onZoom?(delta)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

struct ClipDimmingOverlay: View {
    let clipX: Double
    let clipY: Double
    let clipWidth: Double
    let clipHeight: Double
    let worldBounds: CGRect
    let scale: Double

    var body: some View {
        let clipRect = CGRect(
            x: (clipX - worldBounds.minX) * scale,
            y: (clipY - worldBounds.minY) * scale,
            width: clipWidth * scale,
            height: clipHeight * scale
        )
        let fullRect = CGRect(
            x: 0,
            y: 0,
            width: worldBounds.width * scale,
            height: worldBounds.height * scale
        )

        Canvas { context, _ in
            var dimPath = Path()
            dimPath.addRect(fullRect)
            dimPath.addRect(clipRect)
            context.fill(dimPath, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}

struct ClipFrameOverlay: View {
    @Binding var clipX: Double
    @Binding var clipY: Double
    @Binding var clipWidth: Double
    @Binding var clipHeight: Double
    let aspectMode: ClipAspectMode
    let worldBounds: CGRect
    let scale: Double
  @State private var dragState: ClipFrameDragState?

    var body: some View {
        let safeScale = normalizedDimension(scale, defaultValue: 1)
        let rect = CGRect(
            x: (clipX - worldBounds.minX) * safeScale,
            y: (clipY - worldBounds.minY) * safeScale,
            width: normalizedDimension(clipWidth, defaultValue: 1) * safeScale,
            height: normalizedDimension(clipHeight, defaultValue: 1) * safeScale
        )

        ZStack(alignment: .topLeading) {
            if rect.isValidAvatarEditorFrame {
                Rectangle()
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragState == nil {
                                    dragState = .move(x: clipX, y: clipY)
                                }
                                guard case .move(let startX, let startY) = dragState else { return }
                                clipX = startX + value.translation.width / safeScale
                                clipY = startY + value.translation.height / safeScale
                            }
                            .onEnded { _ in dragState = nil }
                    )

                Text("\(Int(clipWidth)) x \(Int(clipHeight))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AppTheme.accent.opacity(0.92), in: Capsule())
                    .foregroundStyle(AppTheme.textOnAccent)
                    .position(x: rect.minX + 52, y: rect.minY + 22)

                ForEach(ClipResizeHandle.allCases) { handle in
                    ResizeHandleView()
                        .position(handle.position(in: rect))
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    resize(handle: handle, value: value, rect: rect, safeScale: safeScale)
                                }
                                .onEnded { _ in dragState = nil }
                        )
                }
            }
        }
        .frame(width: worldBounds.width * safeScale, height: worldBounds.height * safeScale, alignment: .topLeading)
    }

    func resize(handle: ClipResizeHandle, value: DragGesture.Value, rect: CGRect, safeScale: Double) {
        if dragState == nil {
            dragState = .resize(x: clipX, y: clipY, width: clipWidth, height: clipHeight)
        }
        guard case .resize(let startX, let startY, let startWidth, let startHeight) = dragState else { return }

        let dx = value.translation.width / safeScale
        let dy = value.translation.height / safeScale
        let minimumSize = 16.0
        let right = startX + startWidth
        let bottom = startY + startHeight

        if let ratio = aspectMode.ratio {
            switch handle {
            case .bottomTrailing:
                let delta = max(dx, dy * ratio)
                let newWidth = max(startWidth + delta, minimumSize)
                clipX = startX
                clipY = startY
                clipWidth = newWidth
                clipHeight = newWidth / ratio
            case .topLeading:
                let newWidth = max(startWidth - dx, minimumSize)
                let newHeight = max(newWidth / ratio, minimumSize)
                clipWidth = newWidth
                clipHeight = newHeight
                clipX = right - newWidth
                clipY = bottom - newHeight
            case .topTrailing:
                let newWidth = max(startWidth + dx, minimumSize)
                let newHeight = max(newWidth / ratio, minimumSize)
                clipX = startX
                clipY = bottom - newHeight
                clipWidth = newWidth
                clipHeight = newHeight
            case .bottomLeading:
                let newWidth = max(startWidth - dx, minimumSize)
                let newHeight = max(newWidth / ratio, minimumSize)
                clipX = right - newWidth
                clipY = startY
                clipWidth = newWidth
                clipHeight = newHeight
            }
        } else {
            switch handle {
            case .topLeading:
                let newX = startX + dx
                let newY = startY + dy
                clipX = newX
                clipY = newY
                clipWidth = max(right - newX, minimumSize)
                clipHeight = max(bottom - newY, minimumSize)
            case .topTrailing:
                let newY = startY + dy
                let newRight = right + dx
                clipX = startX
                clipY = newY
                clipWidth = max(newRight - startX, minimumSize)
                clipHeight = max(bottom - newY, minimumSize)
            case .bottomLeading:
                let newX = startX + dx
                let newBottom = bottom + dy
                clipX = newX
                clipY = startY
                clipWidth = max(right - newX, minimumSize)
                clipHeight = max(newBottom - startY, minimumSize)
            case .bottomTrailing:
                let newRight = right + dx
                let newBottom = bottom + dy
                clipX = startX
                clipY = startY
                clipWidth = max(newRight - startX, minimumSize)
                clipHeight = max(newBottom - startY, minimumSize)
            }
        }
    }

    func normalizedDimension(_ value: Double, defaultValue: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultValue }
        return value
    }
}

enum ClipResizeHandle: CaseIterable, Hashable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: Self { self }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeading:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing:
            CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

enum ClipFrameDragState {
    case move(x: Double, y: Double)
    case resize(x: Double, y: Double, width: Double, height: Double)
}

#endif
