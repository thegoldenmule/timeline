import AppKit
import Foundation
import SwiftUI

/// Entry point. `--skeleton-check` runs the walking-skeleton flow headlessly on the main actor and
/// exits with its verdict; anything else launches the SwiftUI window.
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
        .defaultSize(width: 1200, height: 760)
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
