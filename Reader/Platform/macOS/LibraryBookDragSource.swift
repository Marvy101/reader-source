#if os(macOS)
import AppKit
import SwiftUI

/// Owns the native drag lifecycle so the shelf and drag image never show two books.
/// The SwiftUI view supplies its artwork; this adapter only handles pointer input.
struct LibraryBookDragSource: NSViewRepresentable {
    let bookID: UUID
    let image: (CGSize) -> NSImage?
    let open: () -> Void
    let began: () -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.bookID = bookID
        view.makeImage = image
        view.open = open
        view.began = began
        view.ended = ended
    }

    final class SourceView: NSView, NSDraggingSource {
        var bookID = UUID()
        var makeImage: ((CGSize) -> NSImage?)?
        var open: (() -> Void)?
        var began: (() -> Void)?
        var ended: (() -> Void)?
        private var mouseDownEvent: NSEvent?
        private var preparedImage: NSImage?
        private var isDragging = false
        private var finishDrag: (() -> Void)?
        private var artworkWindow: NSPanel?
        private var grabOffset = NSPoint.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Let SwiftUI continue handling hover, context menus and accessibility.
            guard let type = NSApp.currentEvent?.type,
                  [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(type)
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            // Prepare on press, before movement, so the first drag event only
            // positions an existing image instead of rendering SwiftUI artwork.
            preparedImage = makeImage?(bounds.size)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let start = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - start.locationInWindow.x
            let dy = event.locationInWindow.y - start.locationInWindow.y
            guard dx * dx + dy * dy >= 16,
                  let image = preparedImage else { return }

            guard let window else { return }
            let screenFrame = window.convertToScreen(convert(bounds, to: nil))
            let pointer = NSEvent.mouseLocation
            grabOffset = NSPoint(x: pointer.x - screenFrame.minX, y: pointer.y - screenFrame.minY)
            let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            let artwork = NSImageView(frame: NSRect(origin: .zero, size: screenFrame.size))
            artwork.image = image
            artwork.imageScaling = .scaleAxesIndependently
            panel.contentView = artwork
            artworkWindow = panel

            let item = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: bookID))
            // AppKit and SwiftUI destinations can resize native drag previews.
            // Keep their payload/lifecycle, but draw the book in a fixed-size,
            // noninteractive window so destination animations cannot shrink it.
            let transparent = NSImage(size: bounds.size)
            item.setDraggingFrame(bounds, contents: transparent)
            finishDrag = ended
            isDragging = true
            let session = beginDraggingSession(with: [item], event: start, source: self)
            session.draggingFormation = .none
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil; preparedImage = nil }
            if !isDragging, mouseDownEvent != nil,
               bounds.contains(convert(event.locationInWindow, from: nil)) {
                open?()
            }
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            began?()
            artworkWindow?.orderFrontRegardless()
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            let pointer = NSEvent.mouseLocation
            artworkWindow?.setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y))
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            // Called for accepted drops, Escape and drops outside any destination.
            // No native thumbnail morph or return-size animation.
            artworkWindow?.orderOut(nil)
            artworkWindow = nil
            isDragging = false
            preparedImage = nil
            mouseDownEvent = nil
            finishDrag?()
            finishDrag = nil
        }

        static func pasteboardItem(for id: UUID) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: .string)
            item.setData(Data(id.uuidString.utf8), forType: NSPasteboard.PasteboardType(QuietLibraryDrag.type.identifier))
            return item
        }
    }
}
#endif
