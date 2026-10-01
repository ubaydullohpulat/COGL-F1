import AppKit
import SwiftUI

@main
struct COGLF1App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var state = AppState()

  var body: some Scene {
    Window("Forecast Studio", id: "main") {
      RootView()
        .environment(state)
        .frame(minWidth: 960, minHeight: 640)
        .task {
          delegate.state = state
          await state.boot()
        }
        .task { await state.updater.checkAtLaunch() }
    }
    .defaultSize(width: 1440, height: 900)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { Task { await state.updater.checkAndTell() } }
          .disabled(state.updater.isWorking)
      }
      CommandGroup(replacing: .newItem) {
        Button("Open Data File…") { state.chooseFile() }
          .keyboardShortcut("o")
      }
      CommandMenu("Forecast") {
        Button("Run Forecast") { Task { await state.runForecast() } }
          .keyboardShortcut("r")
          .disabled(state.isForecasting)
        Button("Load Selected Model") { Task { await state.loadSelectedModel() } }
          .keyboardShortcut("l")
        Button("Unload Model") { Task { await state.unloadModel() } }
          .keyboardShortcut("e", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
        .environment(state)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var state: AppState?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Needed when run as a bare executable (swift run) rather than from the .app bundle.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { state?.engine.stop() }
  }
}
