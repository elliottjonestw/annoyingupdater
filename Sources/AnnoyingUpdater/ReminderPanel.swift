import AppKit

/// Take keyboard focus for the reminder without activating the app's other windows.
@MainActor
final class ReminderPanel: NSPanel {
    init(contentViewController controller: NSViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: controller.view.fittingSize),
                   styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        contentViewController = controller
        title = "Software Updates"; titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
