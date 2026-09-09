import SwiftUI
import AppKit

struct KeyDownHandler: ViewModifier {
    let handler: (NSEvent) -> Bool

    func body(content: Content) -> some View {
        content
            .background(KeyEventCatcher(handler: handler))
    }
}

extension View {
    func onKeyDown(performing handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyDownHandler(handler: handler))
    }
}

private struct KeyEventCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyEventView {
        let view = KeyEventView()
        view.handler = handler
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyEventView, context: Context) {
        nsView.handler = handler
    }
}

private class KeyEventView: NSView {
    var handler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}