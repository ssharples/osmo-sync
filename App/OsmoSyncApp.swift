import AppKit
import SwiftUI

@main
struct OsmoSyncApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: app.model, camera: app.model.camera)
        } label: {
            MenuBarIcon(model: app.model, camera: app.model.camera)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps one copy running, and opens a window when you open the app yourself, so you can
/// reach it even when the menu bar icon is hidden behind the notch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var window: NSWindow?

    override init() {
        let me = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me }
        if let other {
            // Already running: bring that one forward and leave quietly. A clean exit
            // also stops the login agent from relaunching this copy.
            other.activate()
            exit(0)
        }
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // The login agent passes --background; opening the app yourself shows the window.
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: MenuView(model: model, camera: model.camera).frame(width: 340)))
            w.title = "OsmoSync"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: OsmoCamera

    var body: some View {
        if camera.isRecording {
            Image(systemName: "record.circle.fill").symbolRenderingMode(.multicolor)
        } else if camera.state.isReady {
            Image(systemName: "video.fill")
        } else {
            Image(systemName: "video.slash")
        }
    }
}
