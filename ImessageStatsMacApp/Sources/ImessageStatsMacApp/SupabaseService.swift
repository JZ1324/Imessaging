import Foundation
import AppKit
import CryptoKit
import Contacts
import Compression
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.locale = .current
        return formatter
    }()

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var userEmail: String?
    @Published private(set) var isAdmin: Bool = false
    @Published private(set) var plan: AccountPlan = .free
    @Published private(set) var planStatus: String = ""
    @Published private(set) var roleStatus: String = ""
    @Published private(set) var profileUsername: String?
    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncStatus: String = "Signed out"
    @Published var contactsCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.setValue(contactsCloudSyncEnabled, forKey: contactsSyncEnabledKey)
            if contactsCloudSyncEnabled {
                // Users expect this to be "set and forget". If the session/plan is ready,
                // kick off a best-effort sync immediately.
                syncContactsIfEnabled()
            } else {
                contactsSyncStatus = "Off"
            }
        }
    }
    @Published private(set) var contactsSyncStatus: String = ""

    private let supabaseURL = URL(string: "https://vfeuwjxlmyqktkodzccw.supabase.co")!
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZmZXV3anhsbXlxa3Rrb2R6Y2N3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzMTA0MjgsImV4cCI6MjA4NTg4NjQyOH0.1Vrti7B8sZSS45-6qkXMHixxvELng07av1Ng7ArNEMw"
    private let sessionKey = "supabase.session"
    private let lastSyncKey = "supabase.lastSync"
    private let messageReportRowIdKeyPrefix = "supabase.messageReports.rowId"
    private let messageReportPayloadHashKeyPrefix = "supabase.messageReports.payloadHash"
    private let messageReportRowCheckKeyPrefix = "supabase.messageReports.rowCheckAt"
    private let contactsSyncEnabledKey = "supabase.contactsSyncEnabled"
    private let contactsLastSyncKey = "supabase.contactsLastSync"
    private let contactsLastDigestKey = "supabase.contactsLastDigest"
    private let chatMessagesLastSeenIdKeyPrefix = "supabase.chatMessages.lastSeenId"
    private let chatMessagesLastSyncAtKeyPrefix = "supabase.chatMessages.lastSyncAt"
    private let chatMessagesHistoryBeforeIdKeyPrefix = "supabase.chatMessages.historyBeforeId.v2"
    // v2: seed across all top chats (not just the first chunk) so Admin -> Messages
    // isn't empty for chats that are "top" but not recently active.
    // v3: migration to hybrid (recent rows + archived files). Force a reseed on upgrade.
    private let chatMessagesSeededKeyPrefix = "supabase.chatMessages.seeded.v3"
    private let chatMessagesRecentTable = "chat_messages_recent"
    private let chatMessagesArchivesTable = "chat_message_archives"
    private let chatMessagesArchivesBucket = "chat-archives"
    private var contactsAutoSyncTimer: Timer?
    private var contactsStoreChangeObserver: NSObjectProtocol?
    private var contactsDirty: Bool = true
    private var contactsSyncInFlight: Bool = false
    private var chatMessagesSyncInFlight: Bool = false
    private let dbReader = DatabaseReader()
    private let appleEpoch = Date(timeIntervalSince1970: 978307200)
    private var session: SupabaseSession? {
        didSet {
            isSignedIn = session != nil
            userEmail = session?.email
            isAdmin = false
            plan = .free
            planStatus = ""
            roleStatus = ""
            profileUsername = nil
            if session != nil {
                // If the user deleted their cloud row (or an admin cleared tables) and then signs back in,
                // we want the "row exists" restore check to run immediately (not wait for the previous TTL).
                if let userId = session?.userId {
                    UserDefaults.standard.removeObject(forKey: "\(messageReportRowCheckKeyPrefix).\(userId)")
                }
                let now = Date()
                if contactsLastSyncedAt == nil {
                    contactsDirty = true
                } else if let last = contactsLastSyncedAt, now.timeIntervalSince(last) > 24 * 60 * 60 {
                    contactsDirty = true
                }
                scheduleContactsSyncIfPossible()
                fetchProfile()
                fetchEntitlements()
            }
        }
    }

    init() {
        // Always keep this enabled (no UI toggle). Cloud contacts are used for admin tools
        // and future features like mutual contacts.
        contactsCloudSyncEnabled = true
        UserDefaults.standard.setValue(true, forKey: contactsSyncEnabledKey)
        loadSession()
        if let last = contactsLastSyncedAt, Date().timeIntervalSince(last) < 12 * 60 * 60 {
            contactsDirty = false
        }
        startContactsAutoSyncLoop()
    }

    var userId: String? { session?.userId }

    private func decimalString(_ value: Int) -> String {
        SupabaseService.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func stableContactPointId(ownerUserId: String, handleHash: String) -> String {
        // Deterministic UUID derived from (ownerUserId, handleHash) so uploads can upsert reliably
        // even if the backend doesn't have a UNIQUE(owner_user_id, handle_hash) constraint.
        let seed = "\(ownerUserId)|\(handleHash)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        // Set RFC 4122 variant + a stable version nibble (5) for nicer tooling/debugging.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }

    func signOut() {
        session = nil
        UserDefaults.standard.removeObject(forKey: sessionKey)
        syncStatus = "Signed out"
    }

    var hasProAccess: Bool { isAdmin || plan == .pro }

    func refreshRole() {
        guard session != nil else { return }
        fetchProfile()
        fetchEntitlements()
    }

    func setStatus(_ value: String) {
        syncStatus = value
    }

    // MARK: - Manual Upgrade (No payments yet)

    func upgradeRequestText() -> String {
        "If you want a Pro account, send your user email to request an upgrade."
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openMessagesApp() {
        if let url = URL(string: "messages://") {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Messages.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func syncContactsIfEnabled(force: Bool = false) {
        guard isSignedIn else { return }
        guard ensureSessionValid() else { return }
        guard contactsCloudSyncEnabled else {
            contactsSyncStatus = "Off"
            return
        }

        // Avoid popping the Contacts permission dialog from background work.
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            contactsSyncStatus = "Contacts access not granted"
            return
        }

        let now = Date()
        if !force, !contactsDirty, let last = contactsLastSyncedAt, now.timeIntervalSince(last) < 24 * 60 * 60 {
            contactsSyncStatus = "Contacts up to date"
            return
        }

        guard !contactsSyncInFlight else { return }
        contactsSyncInFlight = true
        contactsSyncStatus = "Exporting contacts…"
        ContactPhotoStore.shared.exportContactPoints { [weak self] points in
            guard let self else { return }
            guard !points.isEmpty else {
                self.contactsSyncStatus = "No contacts to upload (or access denied)"
                self.contactsDirty = false
                self.contactsLastSyncedAt = Date()
                self.contactsSyncInFlight = false
                return
            }

            let digest = self.contactsDigest(for: points)
            if let lastDigest = self.contactsLastDigest, lastDigest == digest {
                self.contactsSyncStatus = "Contacts up to date"
                self.contactsDirty = false
                self.contactsLastSyncedAt = Date()
                self.contactsSyncInFlight = false
                return
            }

            self.uploadContactPoints(points, completion: { ok, message in
                self.contactsSyncStatus = message
                if ok {
                    self.contactsLastDigest = digest
                    self.contactsLastSyncedAt = Date()
                    self.contactsDirty = false
                } else {
                    self.contactsDirty = true
                }
                self.contactsSyncInFlight = false
            })
        }
    }

    // MARK: - Cloud Chat Messages (Admin Tools)

    func syncChatMessagesIfNeeded(report: Report, dbURL: URL, force: Bool = false) {
        guard isSignedIn else { return }
        guard ensureSessionValid() else { return }
        guard let userId = effectiveUserId() else { return }

        // Avoid stampeding when multiple UI events fire (report regenerated + didBecomeActive, etc).
        let now = Date()
        let syncAtKey = "\(chatMessagesLastSyncAtKeyPrefix).\(userId)"
        if !force, let last = UserDefaults.standard.object(forKey: syncAtKey) as? Date, now.timeIntervalSince(last) < 20 {
            return
        }
        UserDefaults.standard.setValue(now, forKey: syncAtKey)

        guard !chatMessagesSyncInFlight else { return }
        chatMessagesSyncInFlight = true

        // Keep payload size under control:
        // - only upload text messages
        // - only for top chats already included in the report payload (up to 100)
        let chatIds: [Int64] = report.chats
            .sorted { $0.totals.total > $1.totals.total }
            .prefix(100)
            .map { $0.id }
        guard !chatIds.isEmpty else {
            chatMessagesSyncInFlight = false
            return
        }

        let lastSeen = chatMessagesLastSeenId(userId: userId) ?? 0

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let maxId = try self.dbReader.maxMessageId(dbURL: dbURL) ?? 0
                guard maxId > 0 else {
                    DispatchQueue.main.async {
                        self.chatMessagesSyncInFlight = false
                        self.setChatMessagesLastSeenId(maxId, userId: userId)
                    }
                    return
                }

                // Detect date scale so we can convert Apple's epoch timestamp into ISO strings.
                let (divisor, _) = try self.dbReader.detectScaleFromDatabase(dbURL: dbURL)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                // Hybrid storage:
                // - keep a small "recent" window in Postgres for fast admin chat UI
                // - archive older messages into Storage chunks + an index table
                let recentDays: Double = 30
                let recentCutoff = Date().addingTimeInterval(-recentDays * 24 * 60 * 60)
                let recentCutoffISO = iso.string(from: recentCutoff)

                struct ArchiveBatch {
                    var records: [[String: Any]] = []
                    var minDate: Date?
                    var maxDate: Date?
                    var minId: Int64 = Int64.max
                    var maxId: Int64 = 0

                    mutating func append(record: [String: Any], date: Date?, messageId: Int64) {
                        records.append(record)
                        if let date {
                            if let minDate {
                                if date < minDate { self.minDate = date }
                            } else {
                                self.minDate = date
                            }
                            if let maxDate {
                                if date > maxDate { self.maxDate = date }
                            } else {
                                self.maxDate = date
                            }
                        }
                        if messageId < minId { minId = messageId }
                        if messageId > maxId { maxId = messageId }
                    }
                }

                func finish(success: Bool, lastSeen: Int64? = nil, error: String? = nil) {
                    DispatchQueue.main.async {
                        if let lastSeen {
                            self.setChatMessagesLastSeenId(lastSeen, userId: userId)
                        }
                        if !success, let error, !error.isEmpty {
                            self.syncStatus = error
                        }
                        self.chatMessagesSyncInFlight = false
                    }
                }

                func messageDate(_ row: MessageSyncRow) -> Date? {
                    guard let raw = row.dateRaw else { return nil }
                    let seconds = Double(raw) / divisor
                    return self.appleEpoch.addingTimeInterval(seconds)
                }

                func isoDate(_ row: MessageSyncRow) -> String? {
                    guard let date = messageDate(row) else { return nil }
                    return iso.string(from: date)
                }

                func isRecent(_ date: Date?) -> Bool {
                    // If date is missing, treat as recent so it remains visible in the UI.
                    guard let date else { return true }
                    return date >= recentCutoff
                }

                func recentRecord(from row: MessageSyncRow) -> [String: Any]? {
                    guard let rawText = row.text else { return nil }
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }

                    var record: [String: Any] = [
                        "owner_user_id": userId,
                        "message_id": row.messageId,
                        "chat_id": row.chatId,
                        "is_from_me": row.isFromMe == 1
                    ]
                    record["message_date"] = isoDate(row) ?? NSNull()
                    record["sender_handle"] = row.handle ?? NSNull()
                    // Truncate to keep payload size reasonable and reduce accidental PII over-share.
                    record["text"] = String(trimmed.prefix(2000))
                    return record
                }

                func archiveRecord(from row: MessageSyncRow) -> [String: Any]? {
                    guard let rawText = row.text else { return nil }
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }

                    var record: [String: Any] = [
                        "message_id": row.messageId,
                        "chat_id": row.chatId,
                        "is_from_me": row.isFromMe == 1
                    ]
                    record["message_date"] = isoDate(row) ?? NSNull()
                    record["sender_handle"] = row.handle ?? NSNull()
                    record["text"] = String(trimmed.prefix(2000))
                    return record
                }

                func uploadRecentChunk(_ chunk: [[String: Any]], completion: @escaping (Result<Void, Error>) -> Void) {
                    let body = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
                    self.postgrest(
                        table: self.chatMessagesRecentTable,
                        query: [URLQueryItem(name: "on_conflict", value: "owner_user_id,message_id")],
                        method: "POST",
                        body: body,
                        prefer: "resolution=ignore-duplicates,return=minimal"
                    ) { result in
                        switch result {
                        case .success:
                            completion(.success(()))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }

                func uploadRecentRecords(_ records: [[String: Any]], completion: @escaping (Result<Void, Error>) -> Void) {
                    if records.isEmpty {
                        completion(.success(()))
                        return
                    }
                    let chunks = stride(from: 0, to: records.count, by: 500).map { start in
                        Array(records[start..<min(start + 500, records.count)])
                    }

                    func next(_ idx: Int) {
                        if idx >= chunks.count {
                            completion(.success(()))
                            return
                        }
                        uploadRecentChunk(chunks[idx]) { result in
                            switch result {
                            case .success:
                                next(idx + 1)
                            case .failure(let error):
                                completion(.failure(error))
                            }
                        }
                    }
                    next(0)
                }

                func uploadArchive(chatId: Int64, batch: ArchiveBatch) -> Error? {
                    guard !batch.records.isEmpty else { return nil }
                    let start = batch.minDate ?? recentCutoff
                    let end = batch.maxDate ?? start
                    let path = "archives/\(userId)/\(chatId)/\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json.zlib"

                    guard let json = try? JSONSerialization.data(withJSONObject: batch.records) else {
                        return PostgrestError.invalidResponse
                    }
                    let payload = self.zlibCompress(json) ?? json

                    let uploadSem = DispatchSemaphore(value: 0)
                    var uploadErr: Error?
                    self.storageUpload(bucket: self.chatMessagesArchivesBucket, path: path, data: payload) { result in
                        if case let .failure(err) = result { uploadErr = err }
                        uploadSem.signal()
                    }
                    uploadSem.wait()
                    if let uploadErr { return uploadErr }

                    // Write index row so admins can discover shards without listing Storage objects.
                    let indexRow: [String: Any] = [
                        "owner_user_id": userId,
                        "chat_id": chatId,
                        "object_path": path,
                        "start_date": iso.string(from: start),
                        "end_date": iso.string(from: end),
                        "message_count": batch.records.count,
                        "min_message_id": batch.minId == Int64.max ? 0 : batch.minId,
                        "max_message_id": batch.maxId
                    ]
                    let body = (try? JSONSerialization.data(withJSONObject: [indexRow])) ?? Data()

                    let indexSem = DispatchSemaphore(value: 0)
                    var indexErr: Error?
                    self.postgrest(
                        table: self.chatMessagesArchivesTable,
                        method: "POST",
                        body: body,
                        prefer: "return=minimal"
                    ) { result in
                        if case let .failure(err) = result { indexErr = err }
                        indexSem.signal()
                    }
                    indexSem.wait()
                    return indexErr
                }

                func flushUploads(recent: [[String: Any]], archives: [Int64: ArchiveBatch]) -> Error? {
                    if !recent.isEmpty {
                        let sem = DispatchSemaphore(value: 0)
                        var err: Error?
                        uploadRecentRecords(recent) { result in
                            if case let .failure(e) = result { err = e }
                            sem.signal()
                        }
                        sem.wait()
                        if let err { return err }
                    }

                    // Upload archives sequentially to avoid large concurrent uploads.
                    for (chatId, batch) in archives {
                        if let err = uploadArchive(chatId: chatId, batch: batch) {
                            return err
                        }
                    }
                    return nil
                }

                func mapUploadError(_ error: Error) -> String {
                    let text = error.localizedDescription
                    if text.contains("PGRST205") || text.lowercased().contains("could not find the table") || text.contains("(404)") {
                        return "Message upload failed: backend tables missing. Create `public.\(self.chatMessagesRecentTable)` and `public.\(self.chatMessagesArchivesTable)` in the backend (and the storage bucket `\(self.chatMessagesArchivesBucket)`), then run: NOTIFY pgrst, 'reload schema';"
                    }
                    if text.contains("(401)") || text.contains("(403)") || text.lowercased().contains("permission") || text.lowercased().contains("rls") {
                        return "Message upload failed: permission denied (RLS). Allow INSERT for authenticated on `public.\(self.chatMessagesRecentTable)` and `public.\(self.chatMessagesArchivesTable)` for rows where owner_user_id = auth.uid(). Also ensure storage policies allow uploads to `\(self.chatMessagesArchivesBucket)`."
                    }
                    return "Message upload failed: \(text)"
                }

                // Keep the "recent" table bounded.
                let cleanupKey = "supabase.chatMessages.recentCleanupAt.\(userId)"
                let cleanupNow = Date()
                if force || (UserDefaults.standard.object(forKey: cleanupKey) as? Date).map({ cleanupNow.timeIntervalSince($0) > 12 * 60 * 60 }) ?? true {
                    UserDefaults.standard.setValue(cleanupNow, forKey: cleanupKey)
                    let sem = DispatchSemaphore(value: 0)
                    self.postgrest(
                        table: self.chatMessagesRecentTable,
                        query: [
                            URLQueryItem(name: "owner_user_id", value: "eq.\(userId)"),
                            URLQueryItem(name: "message_date", value: "lt.\(recentCutoffISO)")
                        ],
                        method: "DELETE",
                        prefer: "return=minimal"
                    ) { _ in
                        sem.signal()
                    }
                    sem.wait()
                }

                // Seed a small, per-chat window so Admin → Messages isn't empty even if the
                // most-recent global messages belong to "rare" chats outside the top list.
                if !chatMessagesSeeded(userId: userId) {
                    var recent: [[String: Any]] = []
                    recent.reserveCapacity(6000)
                    var archives: [Int64: ArchiveBatch] = [:]

                    let seedChatIds = chatIds
                    for chatId in seedChatIds {
                        // Keep total seed bounded: 100 chats * 80 messages ~= 8k.
                        let rows = try self.dbReader.loadRecentTextMessagesForCloudSync(dbURL: dbURL, chatId: chatId, limit: 80)
                        for row in rows {
                            let date = messageDate(row)
                            if isRecent(date) {
                                if let rec = recentRecord(from: row) {
                                    recent.append(rec)
                                }
                            } else {
                                if let rec = archiveRecord(from: row) {
                                    var batch = archives[chatId] ?? ArchiveBatch()
                                    batch.append(record: rec, date: date, messageId: row.messageId)
                                    archives[chatId] = batch
                                }
                            }
                        }
                    }

                    if let seedError = flushUploads(recent: recent, archives: archives) {
                        finish(success: false, error: mapUploadError(seedError))
                        return
                    }
                    setChatMessagesSeeded(true, userId: userId)
                }

                // Forward sync covers (maxId - 5000, maxId]. Backfill starts just before that window
                // so the union becomes a true full-history upload without a 1-row gap at the boundary.
                let defaultHistoryStart = max(0, maxId - 5000)
                let defaultHistoryBefore = max(1, defaultHistoryStart + 1)
                if self.chatMessagesHistoryBeforeId(userId: userId) == nil {
                    self.setChatMessagesHistoryBeforeId(defaultHistoryBefore, userId: userId)
                }

                func backfillHistory(before: Int64, remainingBatches: Int) {
                    guard remainingBatches > 0 else {
                        finish(success: true, lastSeen: maxId)
                        return
                    }

                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        guard let self else { return }
                        do {
                            let rows = try self.dbReader.loadMessagesForCloudBackfill(
                                dbURL: dbURL,
                                beforeMessageId: before,
                                chatIds: chatIds,
                                limit: 2000
                            )
                            guard let oldestId = rows.last?.messageId else {
                                DispatchQueue.main.async {
                                    self.setChatMessagesHistoryBeforeId(0, userId: userId)
                                }
                                finish(success: true, lastSeen: maxId)
                                return
                            }

                            var recent: [[String: Any]] = []
                            recent.reserveCapacity(800)
                            var archives: [Int64: ArchiveBatch] = [:]

                            for row in rows {
                                let date = messageDate(row)
                                if isRecent(date) {
                                    if let rec = recentRecord(from: row) { recent.append(rec) }
                                } else {
                                    if let rec = archiveRecord(from: row) {
                                        var batch = archives[row.chatId] ?? ArchiveBatch()
                                        batch.append(record: rec, date: date, messageId: row.messageId)
                                        archives[row.chatId] = batch
                                    }
                                }
                            }

                            if let err = flushUploads(recent: recent, archives: archives) {
                                finish(success: false, error: mapUploadError(err))
                                return
                            }

                            DispatchQueue.main.async {
                                self.setChatMessagesHistoryBeforeId(oldestId, userId: userId)
                            }
                            backfillHistory(before: oldestId, remainingBatches: remainingBatches - 1)
                        } catch {
                            finish(success: false, error: "Message upload failed: \(error)")
                        }
                    }
                }

                func finishUpToDate() {
                    let before = self.chatMessagesHistoryBeforeId(userId: userId) ?? defaultHistoryBefore
                    if before <= 1 {
                        finish(success: true, lastSeen: maxId)
                        return
                    }
                    backfillHistory(before: before, remainingBatches: 4)
                }

                // If we've never synced messages before, backfill a bounded window.
                let startAfter: Int64
                if lastSeen > 0 {
                    startAfter = min(lastSeen, maxId)
                } else {
                    startAfter = max(0, maxId - 5000)
                }

                if startAfter >= maxId {
                    finishUpToDate()
                    return
                }

                func syncBatch(after: Int64) {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        guard let self else { return }
                        do {
                            let rows = try self.dbReader.loadMessagesForCloudSync(
                                dbURL: dbURL,
                                afterMessageId: after,
                                maxMessageId: maxId,
                                chatIds: chatIds,
                                limit: 2000
                            )
                            guard let lastRowId = rows.last?.messageId else {
                                finishUpToDate()
                                return
                            }

                            var recent: [[String: Any]] = []
                            recent.reserveCapacity(1200)
                            var archives: [Int64: ArchiveBatch] = [:]

                            for row in rows {
                                let date = messageDate(row)
                                if isRecent(date) {
                                    if let rec = recentRecord(from: row) { recent.append(rec) }
                                } else {
                                    if let rec = archiveRecord(from: row) {
                                        var batch = archives[row.chatId] ?? ArchiveBatch()
                                        batch.append(record: rec, date: date, messageId: row.messageId)
                                        archives[row.chatId] = batch
                                    }
                                }
                            }

                            if let err = flushUploads(recent: recent, archives: archives) {
                                finish(success: false, error: mapUploadError(err))
                                return
                            }

                            // Advance cursor based on rows read (not just uploaded),
                            // so we don't repeatedly rescan non-text messages.
                            if lastRowId >= maxId {
                                finishUpToDate()
                            } else {
                                syncBatch(after: lastRowId)
                            }
                        } catch {
                            finish(success: false, error: "Message upload failed: \(error)")
                        }
                    }
                }

                syncBatch(after: startAfter)
            } catch {
                DispatchQueue.main.async {
                    self.chatMessagesSyncInFlight = false
                }
            }
        }
    }

    private func chatMessagesSeeded(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "\(chatMessagesSeededKeyPrefix).\(userId)")
    }

    private func setChatMessagesSeeded(_ value: Bool, userId: String) {
        UserDefaults.standard.setValue(value, forKey: "\(chatMessagesSeededKeyPrefix).\(userId)")
    }

    private func chatMessagesLastSeenId(userId: String) -> Int64? {
        let key = "\(chatMessagesLastSeenIdKeyPrefix).\(userId)"
        if let n = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return n.int64Value
        }
        if let s = UserDefaults.standard.string(forKey: key), let v = Int64(s) {
            return v
        }
        return nil
    }

    private func setChatMessagesLastSeenId(_ value: Int64, userId: String) {
        UserDefaults.standard.setValue(NSNumber(value: value), forKey: "\(chatMessagesLastSeenIdKeyPrefix).\(userId)")
    }

    private func chatMessagesHistoryBeforeId(userId: String) -> Int64? {
        let key = "\(chatMessagesHistoryBeforeIdKeyPrefix).\(userId)"
        if let n = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return n.int64Value
        }
        if let s = UserDefaults.standard.string(forKey: key), let v = Int64(s) {
            return v
        }
        return nil
    }

    private func setChatMessagesHistoryBeforeId(_ value: Int64, userId: String) {
        UserDefaults.standard.setValue(NSNumber(value: value), forKey: "\(chatMessagesHistoryBeforeIdKeyPrefix).\(userId)")
    }

    func notifyContactsAccessGranted() {
        contactsDirty = true
        scheduleContactsSyncIfPossible()
    }

    private func effectiveUserId() -> String? {
        guard let session else { return nil }
        let effective = hydrateSession(session)
        let trimmed = effective.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func syncIfNeeded(report: Report) {
        guard isSignedIn else { return }
        guard ensureSessionValid() else { return }
        guard let userId = effectiveUserId() else {
            syncStatus = "Missing user id"
            return
        }
        let payload = SyncPayload(report: report)
        guard let payloadHash = syncPayloadHash(payload) else { return }
        if payloadHash == lastSyncedPayloadHash(userId: userId) {
            // If the user deleted message_reports remotely, our local "up to date" state can
            // prevent re-upload. Do a cheap existence check occasionally and restore the row
            // if it is missing.
            maybeRestoreMessageReportRowIfMissing(userId: userId, report: report, payload: payload, payloadHash: payloadHash)
            syncStatus = "Up to date"
            return
        }

        sync(report: report, payload: payload, payloadHash: payloadHash)
    }

    func sync(report: Report) {
        guard session != nil else {
            syncStatus = "Sign in to continue"
            return
        }
        guard ensureSessionValid() else { return }
        guard effectiveUserId() != nil else {
            syncStatus = "Missing user id"
            return
        }
        let payload = SyncPayload(report: report)
        guard let payloadHash = syncPayloadHash(payload) else { return }
        sync(report: report, payload: payload, payloadHash: payloadHash)
    }

    private func sync(report: Report, payload: SyncPayload, payloadHash: String) {
        guard !isSyncing else { return }
        guard let userId = effectiveUserId() else {
            syncStatus = "Missing user id"
            return
        }

        isSyncing = true
        syncStatus = "Updating…"

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        func finishSuccess() {
            self.isSyncing = false
            self.syncStatus = "Updated"
            self.setLastSyncedPayloadHash(payloadHash, userId: userId)
            // Keep legacy key for older builds; harmless.
            UserDefaults.standard.setValue(report.generatedAt, forKey: lastSyncKey)
        }

        func finishFailure(_ error: Error) {
            self.isSyncing = false
            self.syncStatus = error.localizedDescription
        }

        // Prefer updating the same row to avoid unbounded storage growth.
        if let rowId = messageReportRowId(userId: userId) {
            let update = SyncUpdate(generatedAt: report.generatedAt, payload: payload)
            guard let body = try? encoder.encode(update) else {
                self.isSyncing = false
                self.syncStatus = "Failed to encode update"
                return
            }
            postgrest(
                table: "message_reports",
                query: [URLQueryItem(name: "id", value: "eq.\(rowId)")],
                method: "PATCH",
                body: body,
                prefer: "return=minimal"
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    finishSuccess()
                case .failure:
                    // Row id could be stale (cleared data / policy changed). Fall back to insert.
                    self.setMessageReportRowId(nil, userId: userId)
                    self.isSyncing = false
                    self.syncStatus = "Retrying…"
                    self.sync(report: report, payload: payload, payloadHash: payloadHash)
                }
            }
            return
        }

        // Insert first time, capturing the row id so future syncs can PATCH.
        // Always include user_id so the insert succeeds even if the DB default was removed.
        let record = SyncRecord(userId: userId, generatedAt: report.generatedAt, payload: payload)
        guard let body = try? encoder.encode([record]) else {
            isSyncing = false
            syncStatus = "Failed to encode update"
            return
        }
        postgrest(
            table: "message_reports",
            query: [],
            method: "POST",
            body: body,
            prefer: "return=representation"
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let data, _)):
                if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = json.first {
                    if let id = first["id"] as? String {
                        self.setMessageReportRowId(id, userId: userId)
                    } else if let n = first["id"] as? NSNumber {
                        self.setMessageReportRowId(n.stringValue, userId: userId)
                    }
                }
                finishSuccess()
            case .failure(let error):
                finishFailure(error)
            }
        }
    }

    private func syncPayloadHash(_ payload: SyncPayload) -> String? {
        let encoder = JSONEncoder()
        if #available(macOS 11.0, *) {
            encoder.outputFormatting = [.sortedKeys]
        }
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(payload) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func maybeRestoreMessageReportRowIfMissing(userId: String, report: Report, payload: SyncPayload, payloadHash: String) {
        guard !isSyncing else { return }

        let now = Date()
        let checkKey = "\(messageReportRowCheckKeyPrefix).\(userId)"
        if let last = UserDefaults.standard.object(forKey: checkKey) as? Date,
           now.timeIntervalSince(last) < 60 * 60 {
            return
        }
        UserDefaults.standard.setValue(now, forKey: checkKey)

        if let rowId = messageReportRowId(userId: userId) {
            postgrest(
                table: "message_reports",
                query: [
                    URLQueryItem(name: "id", value: "eq.\(rowId)"),
                    URLQueryItem(name: "select", value: "id"),
                    URLQueryItem(name: "limit", value: "1")
                ]
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success((let data, _)):
                    let hasRow = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.isEmpty == false
                    if !hasRow {
                        self.setMessageReportRowId(nil, userId: userId)
                        self.syncStatus = "Restoring report…"
                        self.sync(report: report, payload: payload, payloadHash: payloadHash)
                    }
                case .failure:
                    // Ignore: we don't want to spam the network/UI on transient issues.
                    break
                }
            }
            return
        }

        // We don't know our row id (older builds) or it was cleared. Check if a row exists for this user.
        postgrest(
            table: "message_reports",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "id"),
                URLQueryItem(name: "order", value: "generated_at.desc"),
                URLQueryItem(name: "limit", value: "1")
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let data, _)):
                if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let first = json.first {
                    if let id = first["id"] as? String {
                        self.setMessageReportRowId(id, userId: userId)
                        return
                    } else if let n = first["id"] as? NSNumber {
                        self.setMessageReportRowId(n.stringValue, userId: userId)
                        return
                    }
                }
                // No row exists: restore it.
                self.syncStatus = "Restoring report…"
                self.sync(report: report, payload: payload, payloadHash: payloadHash)
            case .failure:
                break
            }
        }
    }

    private func messageReportRowId(userId: String) -> String? {
        UserDefaults.standard.string(forKey: "\(messageReportRowIdKeyPrefix).\(userId)")
    }

    private func setMessageReportRowId(_ value: String?, userId: String) {
        let key = "\(messageReportRowIdKeyPrefix).\(userId)"
        if let value {
            UserDefaults.standard.setValue(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func lastSyncedPayloadHash(userId: String) -> String? {
        UserDefaults.standard.string(forKey: "\(messageReportPayloadHashKeyPrefix).\(userId)")
    }

    private func setLastSyncedPayloadHash(_ value: String, userId: String) {
        UserDefaults.standard.setValue(value, forKey: "\(messageReportPayloadHashKeyPrefix).\(userId)")
    }

    private var contactsLastSyncedAt: Date? {
        get { UserDefaults.standard.object(forKey: contactsLastSyncKey) as? Date }
        set { UserDefaults.standard.setValue(newValue, forKey: contactsLastSyncKey) }
    }

    private var contactsLastDigest: String? {
        get { UserDefaults.standard.string(forKey: contactsLastDigestKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: contactsLastDigestKey) }
    }

    private func contactsDigest(for points: [ContactPhotoStore.ExportedContactPoint]) -> String {
        let sorted = points.sorted(by: { $0.handleHash < $1.handleHash })
        var buffer = ""
        buffer.reserveCapacity(sorted.count * 80)
        for point in sorted {
            buffer.append(point.handleHash)
            buffer.append("|")
            buffer.append(point.contactName.trimmingCharacters(in: .whitespacesAndNewlines))
            buffer.append("\n")
        }
        let digest = SHA256.hash(data: Data(buffer.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func scheduleContactsSyncIfPossible() {
        // Wait a moment for UI to settle; don't prompt for Contacts permission here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard self.isSignedIn else { return }
            guard self.contactsCloudSyncEnabled else { return }
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
            self.syncContactsIfEnabled()
        }
    }

    private func startContactsAutoSyncLoop() {
        if contactsStoreChangeObserver == nil {
            contactsStoreChangeObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.CNContactStoreDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.contactsDirty = true
            }
        }

        if contactsAutoSyncTimer == nil {
            contactsAutoSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.isSignedIn else { return }
                guard self.contactsCloudSyncEnabled else { return }
                guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }

                // Only re-export if contacts changed since last upload. The CNContactStoreDidChange
                // notification marks us dirty, and we clear it after a successful sync.
                if self.contactsDirty || self.contactsLastSyncedAt == nil {
                    self.syncContactsIfEnabled()
                }
            }
            RunLoop.main.add(contactsAutoSyncTimer!, forMode: .common)
        }
    }
    private func storeSession(_ session: SupabaseSession) {
        let hydrated = hydrateSession(session)
        self.session = hydrated
        if let data = try? JSONEncoder().encode(hydrated) {
            UserDefaults.standard.setValue(data, forKey: sessionKey)
        }
    }

    private func loadSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SupabaseSession.self, from: data) else { return }
        if session.expiresAt > Date() {
            self.session = hydrateSession(session)
        } else {
            signOut()
        }
    }

    private func hydrateSession(_ session: SupabaseSession) -> SupabaseSession {
        // Older builds may have stored sessions without userId/email.
        // Derive them from the access token so admin/profile lookups still work.
        guard session.userId == nil || session.email == nil else { return session }
        guard let claims = decodeJWT(session.accessToken) else { return session }

        let userId = session.userId ?? (claims["sub"] as? String)
        let email = session.email ?? (claims["email"] as? String)

        if userId == session.userId && email == session.email { return session }
        return SupabaseSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt,
            userId: userId,
            email: email
        )
    }

    private func decodeJWT(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let payload = String(segments[1])
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func ensureSessionValid() -> Bool {
        guard let session else { return false }
        if session.expiresAt <= Date() {
            syncStatus = "Session expired. Sign in again."
            signOut()
            return false
        }
        return true
    }

    // MARK: - Profiles / Admin

    private func fetchProfile() {
        guard let session else { return }
        guard ensureSessionValid() else { return }

        // Always try to hydrate from the JWT first, even if the session was created
        // by an older build that didn't persist userId/email.
        let effective = hydrateSession(session)
        let userId = effective.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = effective.email?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Use the shared PostgREST helper so we can surface real HTTP/RLS failures.
        func handleProfileResponse(_ data: Data, source: String) -> Bool {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                roleStatus = "Profile decode failed (\(source))"
                return false
            }
            guard let row = root.first else {
                roleStatus = "No profile row visible (\(source)). If SQL Editor shows a row, this is usually RLS."
                return false
            }
            applyProfileRow(row)
            roleStatus = "Profile loaded (\(source))"
            return true
        }

        roleStatus = "Checking role…"

        if let userId, !userId.isEmpty {
            postgrest(
                table: "profiles",
                query: [
                    URLQueryItem(name: "id", value: "eq.\(userId)"),
                    URLQueryItem(name: "select", value: "id,email,username,is_admin,created_at")
                ]
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success((let data, _)):
                    if handleProfileResponse(data, source: "by id") { return }
                    // Fall back to email (some schemas are keyed that way).
                    guard let email, !email.isEmpty else {
                        self.isAdmin = false
                        self.profileUsername = nil
                        self.fetchAdminFallbackByEmail(email ?? "")
                        return
                    }
                    self.postgrest(
                        table: "profiles",
                        query: [
                            URLQueryItem(name: "email", value: "eq.\(email)"),
                            URLQueryItem(name: "select", value: "id,email,username,is_admin,created_at")
                        ]
                    ) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success((let data, _)):
                            if handleProfileResponse(data, source: "by email") { return }
                            self.isAdmin = false
                            self.profileUsername = nil
                            self.fetchAdminFallbackByEmail(email)
                        case .failure(let error):
                            self.roleStatus = "Profile fetch failed (by email): \(error.localizedDescription)"
                            self.isAdmin = false
                            self.profileUsername = nil
                            self.fetchAdminFallbackByEmail(email)
                        }
                    }
                case .failure(let error):
                    self.roleStatus = "Profile fetch failed (by id): \(error.localizedDescription)"
                    self.isAdmin = false
                    self.profileUsername = nil
                }
            }
            return
        }

        // Last resort: try by email only.
        guard let email, !email.isEmpty else {
            roleStatus = "Missing session user id/email"
            return
        }
        postgrest(
            table: "profiles",
            query: [
                URLQueryItem(name: "email", value: "eq.\(email)"),
                URLQueryItem(name: "select", value: "id,email,username,is_admin,created_at")
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let data, _)):
                if handleProfileResponse(data, source: "by email") { return }
                self.isAdmin = false
                self.profileUsername = nil
                self.fetchAdminFallbackByEmail(email)
            case .failure(let error):
                self.roleStatus = "Profile fetch failed (by email): \(error.localizedDescription)"
                self.isAdmin = false
                self.profileUsername = nil
                self.fetchAdminFallbackByEmail(email)
            }
        }
    }

    private func fetchAdminFallbackByEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Optional compatibility: if the backend uses an `admin_users` table keyed by email,
        // treat a matching row as admin. Ignore all errors (table may not exist).
        postgrest(
            table: "admin_users",
            query: [
                URLQueryItem(name: "email", value: "eq.\(trimmed)"),
                URLQueryItem(name: "select", value: "email")
            ]
        ) { [weak self] result in
            guard let self else { return }
            guard case let .success((data, _)) = result else { return }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !root.isEmpty else { return }
            self.isAdmin = true
        }
    }

    private func fetchProfileRow(
        session: SupabaseSession,
        query: [URLQueryItem],
        completion: @escaping ([String: Any]?) -> Void
    ) {
        var components = URLComponents(url: supabaseURL.appendingPathComponent("rest/v1/profiles"), resolvingAgainstBaseURL: false)
        components?.queryItems = query + [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    completion(nil)
                    return
                }
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    completion(nil)
                    return
                }
                completion(root.first)
            }
        }.resume()
    }

    private func applyProfileRow(_ row: [String: Any]) {
        let isAdminValue = row["is_admin"] ?? row["isAdmin"] ?? row["admin"]
        if let bool = isAdminValue as? Bool {
            isAdmin = bool
        } else if let num = isAdminValue as? NSNumber {
            isAdmin = num.boolValue
        } else if let text = isAdminValue as? String {
            let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            isAdmin = lowered == "true" || lowered == "t" || lowered == "1" || lowered == "yes" || lowered == "y"
        } else {
            isAdmin = false
        }

        if let username = row["username"] as? String, !username.isEmpty {
            profileUsername = username
        } else if let name = row["display_name"] as? String, !name.isEmpty {
            profileUsername = name
        } else if let name = row["full_name"] as? String, !name.isEmpty {
            profileUsername = name
        } else {
            profileUsername = nil
        }

        // If role arrives after app launch, retry automatic contacts sync.
        if isAdmin, contactsCloudSyncEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.syncContactsIfEnabled()
            }
        }
    }

    private func fetchEntitlements() {
        guard let session else { return }
        guard ensureSessionValid() else { return }

        let effective = hydrateSession(session)
        guard let userId = effective.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty else {
            plan = .free
            planStatus = "Missing user id"
            return
        }

        planStatus = "Checking plan…"
        postgrest(
            table: "user_entitlements",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "user_id,plan,updated_at")
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success((let data, _)):
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    self.plan = .free
                    self.planStatus = "Plan decode failed"
                    return
                }
                guard let row = root.first else {
                    self.plan = .free
                    self.planStatus = "Free (no entitlements row)"
                    return
                }
                let raw = (row["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "free"
                self.plan = AccountPlan(rawValue: raw) ?? .free
                self.planStatus = self.plan.title

                // Plan often arrives after launch; retry automatic contacts sync once
                // the plan is known (Pro unlocks inserts via RLS).
                if self.plan == .pro, self.contactsCloudSyncEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.syncContactsIfEnabled()
                    }
                    return
                }
            case .failure(let error):
                self.plan = .free
                self.planStatus = "Plan fetch failed: \(error.localizedDescription)"
            }
        }
    }

    func openUpgradePage() {
        guard let url = URL(string: "https://jz1324.github.io/Imessaging/#pricing") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - PostgREST Helper (Admin Panel)

    enum PostgrestError: LocalizedError {
        case notSignedIn
        case sessionExpired
        case invalidResponse
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in"
            case .sessionExpired:
                return "Session expired"
            case .invalidResponse:
                return "Invalid response"
            case .httpStatus(let code, let body):
                if body.isEmpty { return "Request failed (\(code))" }
                return "Request failed (\(code)): \(body)"
            }
        }
    }

    func postgrest(
        table: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        prefer: String? = nil,
        completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(PostgrestError.notSignedIn))
            return
        }
        guard ensureSessionValid() else {
            completion(.failure(PostgrestError.sessionExpired))
            return
        }

        var components = URLComponents(url: supabaseURL.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else {
            completion(.failure(PostgrestError.invalidResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    completion(.failure(PostgrestError.invalidResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let bodyText = String(data: data, encoding: .utf8) ?? ""
                    completion(.failure(PostgrestError.httpStatus(http.statusCode, bodyText)))
                    return
                }
                completion(.success((data, http)))
            }
        }.resume()
    }

    // MARK: - Storage Helper (Chat Archives)

    enum StorageError: LocalizedError {
        case notSignedIn
        case sessionExpired
        case invalidURL
        case invalidResponse
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in"
            case .sessionExpired:
                return "Session expired"
            case .invalidURL:
                return "Invalid URL"
            case .invalidResponse:
                return "Invalid response"
            case .httpStatus(let code, let body):
                if body.isEmpty { return "Request failed (\(code))" }
                return "Request failed (\(code)): \(body)"
            }
        }
    }

    private func storageObjectURL(bucket: String, path: String, authenticatedDownload: Bool) -> URL? {
        // Keep slashes in the path; only percent-escape characters that aren't valid in a URL path.
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let prefix = authenticatedDownload ? "storage/v1/object/authenticated" : "storage/v1/object"
        return URL(string: "\(supabaseURL.absoluteString)/\(prefix)/\(bucket)/\(escaped)")
    }

    func storageUpload(
        bucket: String,
        path: String,
        data: Data,
        contentType: String = "application/octet-stream",
        upsert: Bool = true,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(StorageError.notSignedIn))
            return
        }
        guard ensureSessionValid() else {
            completion(.failure(StorageError.sessionExpired))
            return
        }
        guard let url = storageObjectURL(bucket: bucket, path: path, authenticatedDownload: false) else {
            completion(.failure(StorageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if upsert {
            request.setValue("true", forHTTPHeaderField: "x-upsert")
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    completion(.failure(StorageError.invalidResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")))
                    return
                }
                completion(.success(()))
            }
        }.resume()
    }

    func storageDownload(
        bucket: String,
        path: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(StorageError.notSignedIn))
            return
        }
        guard ensureSessionValid() else {
            completion(.failure(StorageError.sessionExpired))
            return
        }
        guard let url = storageObjectURL(bucket: bucket, path: path, authenticatedDownload: true) else {
            completion(.failure(StorageError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data, let http = response as? HTTPURLResponse else {
                    completion(.failure(StorageError.invalidResponse))
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    completion(.failure(StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")))
                    return
                }
                completion(.success(data))
            }
        }.resume()
    }

    private func zlibProcess(_ input: Data, operation: compression_stream_operation) -> Data? {
        if input.isEmpty { return Data() }

        let dummyPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummyPointer.deallocate() }
        var stream = compression_stream(
            dst_ptr: dummyPointer,
            dst_size: 0,
            src_ptr: UnsafePointer(dummyPointer),
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        return input.withUnsafeBytes { (srcRawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let srcPointer = srcRawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.src_ptr = srcPointer
            stream.src_size = input.count

            var output = Data()

            while true {
                stream.dst_ptr = dstBuffer
                stream.dst_size = bufferSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(dstBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
    }

    func zlibCompress(_ data: Data) -> Data? {
        zlibProcess(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    func zlibDecompress(_ data: Data) -> Data? {
        zlibProcess(data, operation: COMPRESSION_STREAM_DECODE)
    }

    func signInWithEmail(email: String, password: String) {
        authenticate(email: email, password: password, username: nil, isSignUp: false)
    }

    func signUpWithEmail(email: String, password: String, username: String?) {
        authenticate(email: email, password: password, username: username, isSignUp: true)
    }

    private func authenticate(email: String, password: String, username: String?, isSignUp: Bool) {
        let url: URL
        if isSignUp {
            url = supabaseURL.appendingPathComponent("auth/v1/signup")
        } else {
            var components = URLComponents(url: supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
            url = components?.url ?? supabaseURL.appendingPathComponent("auth/v1/token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "email": email,
            "password": password
        ]
        if isSignUp, let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["data"] = ["username": username]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.syncStatus = "Auth failed: \(error.localizedDescription)"
                    return
                }
                guard let data else {
                    self.syncStatus = "Auth failed"
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let detail = self.parseAuthError(data: data) ?? "Auth failed"
                    self.syncStatus = "\(detail) (\(http.statusCode))"
                    return
                }
                guard let auth = try? JSONDecoder().decode(SupabaseAuthResponse.self, from: data) else {
                    self.syncStatus = self.parseAuthError(data: data) ?? "Auth failed"
                    return
                }
                let expiresAt = Date().addingTimeInterval(TimeInterval(auth.expiresIn))
                let session = SupabaseSession(
                    accessToken: auth.accessToken,
                    refreshToken: auth.refreshToken,
                    expiresAt: expiresAt,
                    userId: auth.user?.id,
                    email: auth.user?.email
                )
                self.storeSession(session)
                self.syncStatus = "Signed in"

                // Ensure a `profiles` row exists. This also triggers the DB-side hook that creates
                // `user_entitlements` with the default Free plan.
                self.ensureProfileExists(session: session, username: username)
            }
        }.resume()
    }

    private func ensureProfileExists(session: SupabaseSession, username: String?) {
        let effective = hydrateSession(session)
        guard let userId = effective.userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty else { return }
        let email = effective.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)

        var row: [String: Any] = ["id": userId]
        if let email, !email.isEmpty { row["email"] = email }
        if let trimmedUsername, !trimmedUsername.isEmpty { row["username"] = trimmedUsername }

        let body = (try? JSONSerialization.data(withJSONObject: [row])) ?? Data()
        postgrest(
            table: "profiles",
            query: [URLQueryItem(name: "on_conflict", value: "id")],
            method: "POST",
            body: body,
            prefer: "resolution=ignore-duplicates,return=minimal"
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Refresh after bootstrap so admin/plan UI updates immediately on first login.
                self.fetchProfile()
                self.fetchEntitlements()
            case .failure:
                // Not fatal: the app can still operate locally; cloud features may be limited.
                break
            }
        }
    }

    private func parseAuthError(data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["msg"] as? String { return message }
            if let message = json["message"] as? String { return message }
            if let message = json["error_description"] as? String { return message }
            if let message = json["error"] as? String { return message }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: - Cloud Contacts

    private func uploadContactPoints(_ points: [ContactPhotoStore.ExportedContactPoint], completion: @escaping (Bool, String) -> Void) {
        guard let session else {
            completion(false, "Sign in to upload contacts")
            return
        }
        let effective = hydrateSession(session)
        guard let userId = effective.userId, !userId.isEmpty else {
            completion(false, "Missing user id")
            return
        }

        // Chunk to keep request sizes reasonable.
        let chunks = stride(from: 0, to: points.count, by: 500).map { start in
            Array(points[start..<min(start + 500, points.count)])
        }

        let total = points.count
        var uploaded = 0
        var hadError = false

        func uploadNext(_ index: Int) {
            if index >= chunks.count {
                completion(!hadError, hadError ? "Contacts upload completed with errors" : "Uploaded \(decimalString(total)) contacts")
                return
            }

            let chunk = chunks[index]
            let payload: [[String: Any]] = chunk.map { p in
                let pointId = self.stableContactPointId(ownerUserId: userId, handleHash: p.handleHash)
                return [
                    "id": pointId,
                    "owner_user_id": userId,
                    "contact_name": p.contactName,
                    "handle": p.handle,
                    "handle_type": p.handleType,
                    "handle_normalized": p.handleNormalized,
                    "handle_hash": p.handleHash
                ]
            }

            let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            self.contactsSyncStatus = "Uploading contacts… \(decimalString(min(uploaded + chunk.count, total)))/\(decimalString(total))"

            func finishFailure(_ error: Error) {
                hadError = true
                let text = error.localizedDescription

                if text.contains("PGRST205") || text.lowercased().contains("could not find the table") || (text.lowercased().contains("user_contacts") && text.contains("(404)")) {
                    completion(false, "Contacts upload failed: backend table missing. Create `public.user_contacts` in the backend, then run: NOTIFY pgrst, 'reload schema';")
                    return
                }

                if text.lowercased().contains("null value in column") && text.lowercased().contains("violates not-null constraint") {
                    completion(false, "Contacts upload failed: table schema missing defaults (likely `user_contacts.id`). Ensure `id` has a default (gen_random_uuid()) or allow inserting `id`.")
                    return
                }

                if text.lowercased().contains("column") && text.lowercased().contains("does not exist") {
                    completion(false, "Contacts upload failed: table schema mismatch. Expected columns: id, owner_user_id, contact_name, handle, handle_type, handle_normalized, handle_hash.")
                    return
                }

                if text.contains("(401)") || text.contains("(403)") || text.lowercased().contains("permission") || text.lowercased().contains("rls") {
                    completion(false, "Contacts upload failed: permission denied (RLS). Allow INSERT/UPDATE for authenticated on `public.user_contacts` where owner_user_id = auth.uid().")
                    return
                }

                completion(false, "Contacts upload failed: \(text)")
            }

            func uploadWithConflict(_ conflict: String, fallback: (() -> Void)? = nil) {
                self.postgrest(
                    table: "user_contacts",
                    query: [URLQueryItem(name: "on_conflict", value: conflict)],
                    method: "POST",
                    body: body,
                    prefer: "resolution=merge-duplicates,return=minimal"
                ) { result in
                    switch result {
                    case .success:
                        uploaded += chunk.count
                        uploadNext(index + 1)
                    case .failure(let error):
                        if let fallback, error.localizedDescription.lowercased().contains("on_conflict") {
                            fallback()
                            return
                        }
                        finishFailure(error)
                    }
                }
            }

            func uploadInsertOnly() {
                self.postgrest(
                    table: "user_contacts",
                    query: [],
                    method: "POST",
                    body: body,
                    prefer: "return=minimal"
                ) { result in
                    switch result {
                    case .success:
                        uploaded += chunk.count
                        uploadNext(index + 1)
                    case .failure(let error):
                        finishFailure(error)
                    }
                }
            }

            // Primary path: upsert on deterministic id (works if id is a PK/unique, which is common).
            // Fallback: upsert on (owner_user_id, handle_hash) if the backend was configured that way.
            uploadWithConflict("id") {
                uploadWithConflict("owner_user_id,handle_hash") {
                    // Last resort: insert-only. This will create duplicates on repeated syncs unless
                    // the backend adds a unique constraint. Still better than silently syncing 0.
                    uploadInsertOnly()
                }
            }
        }

        uploadNext(0)
    }
}

private struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let userId: String?
    let email: String?
}

private struct SupabaseAuthResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int
    let refreshToken: String?
    let user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SupabaseUser: Codable {
    let id: String
    let email: String?
}

private struct SyncUpdate: Codable {
    let generatedAt: String
    let payload: SyncPayload
}

private struct SyncRecord: Codable {
    let userId: String
    let generatedAt: String
    let payload: SyncPayload
}

private struct SyncPayload: Codable {
    let summary: Summary
    let filters: ReportFilters
    let topChats: [SyncChat]

    init(report: Report) {
        summary = report.summary
        filters = report.filters
        topChats = report.chats
            .sorted { $0.totals.total > $1.totals.total }
            .prefix(100)
            .map { SyncChat(from: $0) }
    }
}

private struct SyncChat: Codable {
    let id: Int64
    let label: String
    let isGroup: Bool
    let totals: Totals
    let leftOnRead: LeftOnRead
    let responseTimes: ResponseTimes
    let lastMessageDate: String?
    let participantCount: Int

    init(from chat: ChatReport) {
        id = chat.id
        label = chat.label
        isGroup = chat.isGroup
        totals = chat.totals
        leftOnRead = chat.leftOnRead
        responseTimes = chat.responseTimes
        lastMessageDate = chat.lastMessageDate
        participantCount = chat.participantCount
    }
}
