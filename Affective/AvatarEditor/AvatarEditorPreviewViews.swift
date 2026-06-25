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
           let image = NSImage(contentsOf: imageURL),
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
    let canvasWidth: Double
    let canvasHeight: Double
    @State private var dragState: LayerResizeDragState?

    var body: some View {
        let safeCanvasWidth = normalizedDimension(canvasWidth, fallback: 1024)
        let safeCanvasHeight = normalizedDimension(canvasHeight, fallback: 1024)
        let safeScale = normalizedDimension(scale, fallback: 1)
        let rect = CGRect(
            x: slot.x * safeScale,
            y: slot.y * safeScale,
            width: normalizedDimension(slot.width, fallback: 1) * safeScale,
            height: normalizedDimension(slot.height, fallback: 1) * safeScale
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
        .frame(width: safeCanvasWidth * safeScale, height: safeCanvasHeight * safeScale, alignment: .topLeading)
    }

    func resize(handle: LayerResizeHandle, value: DragGesture.Value) {
        if dragState == nil {
            dragState = LayerResizeDragState(
                x: slot.x,
                y: slot.y,
                width: slot.width,
                height: slot.height
            )
        }
        guard let dragState else { return }

        let safeScale = normalizedDimension(scale, fallback: 1)
        let dx = value.translation.width / safeScale
        let dy = value.translation.height / safeScale
        let minimumSize = 16.0
        let right = dragState.x + dragState.width
        let bottom = dragState.y + dragState.height

        switch handle {
        case .topLeading:
            let newX = clamped(dragState.x + dx, lowerBound: 0, upperBound: right - minimumSize)
            let newY = clamped(dragState.y + dy, lowerBound: 0, upperBound: bottom - minimumSize)
            slot.x = newX
            slot.y = newY
            slot.width = right - newX
            slot.height = bottom - newY
        case .topTrailing:
            let newRight = clamped(right + dx, lowerBound: dragState.x + minimumSize, upperBound: canvasWidth)
            let newY = clamped(dragState.y + dy, lowerBound: 0, upperBound: bottom - minimumSize)
            slot.y = newY
            slot.width = newRight - dragState.x
            slot.height = bottom - newY
        case .bottomLeading:
            let newX = clamped(dragState.x + dx, lowerBound: 0, upperBound: right - minimumSize)
            let newBottom = clamped(bottom + dy, lowerBound: dragState.y + minimumSize, upperBound: canvasHeight)
            slot.x = newX
            slot.width = right - newX
            slot.height = newBottom - dragState.y
        case .bottomTrailing:
            let newRight = clamped(right + dx, lowerBound: dragState.x + minimumSize, upperBound: canvasWidth)
            let newBottom = clamped(bottom + dy, lowerBound: dragState.y + minimumSize, upperBound: canvasHeight)
            slot.width = newRight - dragState.x
            slot.height = newBottom - dragState.y
        }
    }

    func clamped(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        min(max(value, lowerBound), max(upperBound, lowerBound))
    }

    func normalizedDimension(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else {
            avatarPreviewLogger.error("Invalid resize canvas dimension value=\(value, privacy: .public)")
            return fallback
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
    let x: Double
    let y: Double
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
            let frames = max(slot.frames, 1)
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
                Text("\(max(slot.frames, 1)) frames")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(0..<max(slot.frames, 1), id: \.self) { frame in
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

#endif
