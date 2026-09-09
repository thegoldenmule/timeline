import AppKit
import Foundation
import SwiftUI

/// Entry point. `--skeleton-check` runs the end-to-end check headlessly on the main actor against a
/// temporary library root and exits with its verdict; `--connect-google` runs the Google connect flow
/// without the window (the browser opens, the token lands in the file store); anything else launches
/// the SwiftUI window over `TIMELINE_ROOT` (default `~/Movies/Timeline`).
@main
enum TimelineAppMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--skeleton-check") {
            Task { @MainActor in
                let ok = await SkeletonCheck.run()
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--connect-google") {
            Task { @MainActor in
                let ok = await ConnectGoogleCommand.run()
                exit(ok ? 0 : 1)
            }
            dispatchMain()
        }
        TimelineWindowApp.main()
    }
}

struct TimelineWindowApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Timeline") {
            ContentView(model: model)
        }
        .defaultSize(width: 1400, height: 860)
        Settings {
            SettingsView(model: model)
        }
    }
}

/// An SPM executable has no bundle, so the activation policy is set by hand or no window appears.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
