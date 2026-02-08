import Foundation
import Sparkle

final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }()
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String = "Idle"
    @Published private(set) var updatePromptVisible: Bool = false
    @Published private(set) var updatePromptVersion: String?
    @Published private(set) var updatePromptBuild: String?

    private var hasStarted: Bool = false
    private var backgroundTimer: Timer?
    private var lastBackgroundCheck: Date?
    private var userInitiatedCheck: Bool = false

    private override init() {
        super.init()
    }

    func startAutomaticChecks() {
        guard !hasStarted else { return }
        hasStarted = true

        // First check shortly after launch so the UI is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkForUpdatesInBackground(reason: "launch")
        }

        // Periodic checks while the app is running.
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdatesInBackground(reason: "timer")
        }
        RunLoop.main.add(backgroundTimer!, forMode: .common)
    }

    func checkForUpdates() {
        status = "Checking…"
        lastChecked = Date()
        userInitiatedCheck = true
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackgroundIfStale(maxAgeSeconds: TimeInterval = 60 * 60) {
        let last = lastBackgroundCheck ?? lastChecked
        if let last, Date().timeIntervalSince(last) < maxAgeSeconds { return }
        checkForUpdatesInBackground(reason: "active")
    }

    func dismissUpdatePrompt() {
        updatePromptVisible = false
    }

    private func checkForUpdatesInBackground(reason: String) {
        status = "Checking…"
        lastChecked = Date()
        lastBackgroundCheck = Date()
        userInitiatedCheck = false
        controller.updater.checkForUpdatesInBackground()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            self.status = "No updates found"
            self.userInitiatedCheck = false
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            self.status = "Update available"
            self.updatePromptVersion = item.displayVersionString
            self.updatePromptBuild = item.versionString
            // If the user explicitly pressed "Check for Updates", Sparkle will present its own UI.
            // Only show our lightweight "Update Available" prompt for background checks.
            if !self.userInitiatedCheck {
                self.updatePromptVisible = true
            }
            self.userInitiatedCheck = false
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        DispatchQueue.main.async {
            self.status = "Update check failed: \(error.localizedDescription)"
            self.userInitiatedCheck = false
        }
    }
}
