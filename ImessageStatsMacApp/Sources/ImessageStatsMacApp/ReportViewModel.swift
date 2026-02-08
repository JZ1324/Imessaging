import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var dbURL: URL?
    @Published var outputFolderURL: URL?
    @Published var report: Report?
    @Published var statusMessage: String = ""
    @Published var statusIsError: Bool = false
    @Published var isWorking: Bool = false

    @Published var sinceEnabled: Bool = false
    @Published var untilEnabled: Bool = false
    @Published var sinceDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var untilDate: Date = Date()
    @Published var thresholdHours: Double = 168
    @Published var topCount: Int = 100
    @Published var autoRefreshEnabled: Bool = true {
        didSet { configureAutoRefresh() }
    }

    @Published var latestHTMLURL: URL?
    @Published var showAccessPrompt: Bool = false
    @Published var accessPromptMessage: String = ""

    private let generator = ReportGenerator()
    private var refreshTimer: Timer?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?

    private let defaults = UserDefaults.standard
    private let dbURLKey = "ImessageStats.lastDBURL"
    private let outputURLKey = "ImessageStats.lastOutputURL"
    private let lastDBSignatureKey = "ImessageStats.lastDBSignature"
    private let lastSettingsSignatureKey = "ImessageStats.lastSettingsSignature"

    func onAppear(allowAutoWork: Bool) {
        if let savedDB = defaults.string(forKey: dbURLKey) {
            dbURL = URL(fileURLWithPath: savedDB)
        } else {
            let fallback = URL(fileURLWithPath: ("~/Library/Messages/chat.db" as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: fallback.path) {
                dbURL = fallback
            }
        }

        if let savedOutput = defaults.string(forKey: outputURLKey) {
            outputFolderURL = URL(fileURLWithPath: savedOutput)
        } else {
            outputFolderURL = defaultOutputFolder()
        }

        if allowAutoWork {
            if dbURL != nil {
                generateReport()
            } else {
                setStatus("Could not locate chat.db. Grant Full Disk Access or pick a DB later.", isError: true)
            }
            configureAutoRefresh()
        }
    }

    func chooseDatabase() {
        let panel = NSOpenPanel()
        let contentTypes = ["db", "sqlite", "sqlite3"].compactMap { UTType(filenameExtension: $0) }
        if !contentTypes.isEmpty {
            panel.allowedContentTypes = contentTypes
        }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            dbURL = url
            defaults.set(url.path, forKey: dbURLKey)
            statusMessage = "Selected database: \(url.lastPathComponent)"
            statusIsError = false
            if autoRefreshEnabled {
                generateReport()
            }
            configureAutoRefresh()
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            outputFolderURL = url
            defaults.set(url.path, forKey: outputURLKey)
            statusMessage = "Selected output folder: \(url.path)"
            statusIsError = false
        }
    }

    func generateReport() {
        guard let dbURL else {
            setStatus("Please choose a chat.db file.", isError: true)
            return
        }

        let outputFolder = outputFolderURL ?? defaultOutputFolder()
        let settings = makeSettings()

        // Skip expensive regeneration if neither the DB file nor the filters changed.
        if let dbSignature = fileSignature(for: dbURL),
           dbSignature == lastGeneratedDBSignature,
           settingsSignature(settings) == lastGeneratedSettingsSignature,
           let cached = loadCachedReport(outputFolder: outputFolder) {
            report = cached.report
            latestHTMLURL = cached.htmlURL
            outputFolderURL = outputFolder
            setStatus("Up to date.", isError: false)
            isWorking = false
            return
        }

        isWorking = true
        statusMessage = "Generating report…"
        statusIsError = false

        let dbSignatureAtStart = fileSignature(for: dbURL)
        let settingsSignatureAtStart = settingsSignature(settings)

        Task.detached { [settings, generator = self.generator] in
            do {
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: nil)
                let output = try generator.generate(dbURL: dbURL, outputFolder: outputFolder, settings: settings)
                await MainActor.run {
                    self.report = output.report
                    self.latestHTMLURL = output.htmlURL
                    self.outputFolderURL = outputFolder
                    if let dbSignatureAtStart {
                        self.lastGeneratedDBSignature = dbSignatureAtStart
                    }
                    self.lastGeneratedSettingsSignature = settingsSignatureAtStart
                    self.setStatus("Report generated.", isError: false)
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    let message = "Failed: \(error)"
                    self.setStatus(message, isError: true)
                    self.isWorking = false

                    if self.isLikelyDiskAccessError(error) {
                        let translocated = Bundle.main.bundlePath.contains("AppTranslocation")
                        if translocated {
                            self.accessPromptMessage = "This app is running from a translocated path (usually launching directly from a DMG). Drag the app to Applications, run it from there, then grant Full Disk Access."
                        } else {
                            self.accessPromptMessage = "This app needs Full Disk Access to read iMessage data (chat.db). Click Open Settings and enable Full Disk Access for iMessages Stats."
                        }
                        self.showAccessPrompt = true
                    }
                }
            }
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openContactsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func defaultOutputFolder() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return (documents ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("iMessageStats", isDirectory: true)
    }

    private func makeSettings() -> ReportGenerator.Settings {
        let since = sinceEnabled ? sinceDate : nil
        let until = untilEnabled ? untilDate : nil
        return ReportGenerator.Settings(since: since, until: until, thresholdHours: thresholdHours, top: topCount)
    }

    private func settingsSignature(_ settings: ReportGenerator.Settings) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let since = settings.since.map { formatter.string(from: $0) } ?? "-"
        let until = settings.until.map { formatter.string(from: $0) } ?? "-"
        let threshold = String(format: "%.2f", settings.thresholdHours)
        return "since=\(since)|until=\(until)|threshold=\(threshold)|top=\(settings.top)"
    }

    private func fileSignature(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        let stamp = Int(modified.timeIntervalSince1970)
        return "\(stamp)|\(size.int64Value)"
    }

    private func loadCachedReport(outputFolder: URL) -> ReportOutput? {
        let jsonURL = outputFolder.appendingPathComponent("report.json")
        let htmlURL = outputFolder.appendingPathComponent("report.html")
        // If the user deletes/moves the HTML output (common when cleaning up "reports"),
        // don't treat the JSON as a valid cache hit because the UI relies on report.html.
        guard FileManager.default.fileExists(atPath: htmlURL.path) else { return nil }
        guard let data = try? Data(contentsOf: jsonURL) else { return nil }
        let decoder = JSONDecoder()
        guard let report = try? decoder.decode(Report.self, from: data) else { return nil }
        return ReportOutput(report: report, htmlURL: htmlURL, jsonURL: jsonURL)
    }

    private var lastGeneratedDBSignature: String? {
        get { defaults.string(forKey: lastDBSignatureKey) }
        set { defaults.setValue(newValue, forKey: lastDBSignatureKey) }
    }

    private var lastGeneratedSettingsSignature: String? {
        get { defaults.string(forKey: lastSettingsSignatureKey) }
        set { defaults.setValue(newValue, forKey: lastSettingsSignatureKey) }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func isLikelyDiskAccessError(_ error: Error) -> Bool {
        let msg = String(describing: error).lowercased()
        return msg.contains("authorization denied")
            || msg.contains("operation not permitted")
            || msg.contains("not permitted")
            || msg.contains("not authorized")
            || msg.contains("full disk access")
    }

    private func configureAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopWatching()

        guard autoRefreshEnabled, let dbURL else { return }

        // File watcher for near-real-time updates.
        startWatching(dbURL: dbURL)

        // Fallback timer in case file events are missed.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.dbURL != nil && !self.isWorking {
                    self.generateReport()
                }
            }
        }
    }

    func startAutoRefresh() {
        configureAutoRefresh()
    }

    private func startWatching(dbURL: URL) {
        stopWatching()

        fileDescriptor = open(dbURL.path, O_EVTONLY)
        if fileDescriptor < 0 {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedRefresh()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        fileWatcher = source
        source.resume()
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.dbURL != nil && !self.isWorking {
                self.generateReport()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
}
