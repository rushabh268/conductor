import SwiftUI

@main
struct ConductorApp: App {
    @State private var db: AppDatabase
    @State private var coordinator: IngestionCoordinator
    @State private var settings: SettingsStore
    private let isTestHost: Bool

    init() {
        let testing = ProcessInfo.processInfo.environment["CONDUCTOR_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        isTestHost = testing
        let database = try! AppDatabase(inMemory: testing)
        let defaults = testing ? UserDefaults(suiteName: "conductor-test-host-\(UUID().uuidString)")! : .standard
        _settings = State(initialValue: SettingsStore(defaults: defaults))
        _db = State(initialValue: database)
        _coordinator = State(initialValue: IngestionCoordinator(db: database))
    }

    var body: some Scene {
        WindowGroup {
            if isTestHost { Color.clear }
            else {
                ContentView(db: db, coordinator: coordinator, settings: settings)
                    .onAppear {
                        coordinator.retentionDays = settings.retentionDays
                        coordinator.start(interval: settings.refreshInterval)
                    }
                    .onDisappear { coordinator.stop() }
            }
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Conductor Help") {
                    HelpWindowController.shared.showWindow()
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Show Onboarding") {
                    settings.hasSeenOnboarding = false
                }
            }
        }

        MenuBarExtra("Conductor", systemImage: "waveform.path.ecg", isInserted: .constant(!isTestHost)) {
            MenuBarView(db: db, settings: settings, revision: coordinator.lastIngestionAt)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Help Window Controller

/// Manages a single NSWindow instance for the help content.
@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    func showWindow() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: HelpWindowView())
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Conductor Help"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }
}
