import AppKit
import SwiftUI

@MainActor
final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    static let mainWindowID = "ifilespan-main"
    var openMainWindow: (@MainActor () -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard openMainWindow != nil else { return true }
        restoreMainWindow()
        return false
    }

    func restoreMainWindow() {
        // SwiftUI's single Window scene restores a closed window without making duplicates.
        for window in NSApp.windows where window.canBecomeMain && window.isMiniaturized {
            window.deminiaturize(nil)
        }
        openMainWindow?()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
struct MainWindowReopenRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let lifecycle: ApplicationLifecycle

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            lifecycle.openMainWindow = { action(id: ApplicationLifecycle.mainWindowID) }
        }
    }
}
