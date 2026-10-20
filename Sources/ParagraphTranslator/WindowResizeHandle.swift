import AppKit
import SwiftUI

struct WindowResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeHandleView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeHandleView: NSView {
    private struct DragStart {
        let frame: NSRect
        let mouse: NSPoint
    }

    private var dragStart: DragStart?

    private static let resizeCursor: NSCursor = {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        let symbol = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        let image = symbol?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) ?? symbol
        guard let image else { return .resizeLeftRight }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "拖动调整窗口大小"
        setAccessibilityElement(true)
        setAccessibilityRole(.growArea)
        setAccessibilityLabel("调整窗口大小")
        setAccessibilityHelp("拖动右下角调整窗口大小")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.resizeCursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let grip = NSBezierPath()
        grip.lineWidth = 1.25
        grip.lineCapStyle = .round
        let lengths: [CGFloat] = [4, 8, 12]
        for length in lengths {
            grip.move(to: NSPoint(x: bounds.maxX - 5 - length, y: bounds.minY + 5))
            grip.line(to: NSPoint(x: bounds.maxX - 5, y: bounds.minY + 5 + length))
        }
        grip.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = DragStart(frame: window.frame, mouse: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        resizeWindow()
    }

    override func mouseUp(with event: NSEvent) {
        resizeWindow()
        dragStart = nil
    }

    private func resizeWindow() {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: dragStart.frame.minX, y: dragStart.frame.maxY - 1)) }
            ?? window.screen
        let visible = screen?.visibleFrame
        let maxWidth = max(window.minSize.width, min(window.maxSize.width,
            visible.map { $0.maxX - dragStart.frame.minX - 12 } ?? window.maxSize.width))
        let maxHeight = max(window.minSize.height, min(window.maxSize.height,
            visible.map { dragStart.frame.maxY - $0.minY - 12 } ?? window.maxSize.height))
        let width = min(max(dragStart.frame.width + mouse.x - dragStart.mouse.x,
                            window.minSize.width), maxWidth)
        let height = min(max(dragStart.frame.height - mouse.y + dragStart.mouse.y,
                             window.minSize.height), maxHeight)
        // Keep the opposite corner fixed while the bottom-right corner follows the mouse.
        let frame = NSRect(x: dragStart.frame.minX, y: dragStart.frame.maxY - height,
                           width: width, height: height)
        window.setFrame(frame, display: true)
    }
}
