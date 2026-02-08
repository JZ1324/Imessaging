import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Message {
    let messageId: Int64
    let chatId: Int64
    let chatIdentifier: String
    let displayName: String?
    let handle: String?
    let dateRaw: Int64?
    let dateReadRaw: Int64?
    let isFromMe: Int
    let participantCount: Int
    let text: String?
    let associatedMessageType: Int?
    let attachmentCount: Int
    let handleList: String?
}

/// Minimal message row used for cloud sync (admin tools). Keep this separate from `Message` so
/// incremental sync queries stay lightweight.
struct MessageSyncRow {
    let messageId: Int64
    let chatId: Int64
    let dateRaw: Int64?
    let isFromMe: Int
    let handle: String?
    let text: String?
}

enum DatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case queryFailed(String)

    var description: String {
        switch self {
        case .openFailed(let msg):
            return msg
        case .queryFailed(let msg):
            return msg
        }
    }
}

final class DatabaseReader {
    private let appleEpoch = Date(timeIntervalSince1970: 978307200)

    private func openReadOnly(_ dbURL: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE
        let rc = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db {
                sqlite3_close(db)
            }
            throw DatabaseError.openFailed("Failed to open database: \(msg)")
        }
        return db
    }

    // MARK: - Incremental Sync Helpers

    func maxMessageId(dbURL: URL) throws -> Int64? {
        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let sql = "SELECT MAX(ROWID) FROM message"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to read max message id: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    func loadMessagesForCloudSync(
        dbURL: URL,
        afterMessageId: Int64,
        maxMessageId: Int64,
        chatIds: [Int64],
        limit: Int
    ) throws -> [MessageSyncRow] {
        guard !chatIds.isEmpty, limit > 0 else { return [] }

        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        let sql = """
            SELECT
                m.ROWID as message_id,
                m.date as date_raw,
                m.is_from_me as is_from_me,
                c.ROWID as chat_id,
                h.id as handle,
                m.text as text
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ? AND m.ROWID <= ?
              AND c.ROWID IN (\(placeholders))
            ORDER BY m.ROWID ASC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to prepare message upload query: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_int64(stmt, bindIndex, afterMessageId)
        bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, maxMessageId)
        bindIndex += 1
        for chatId in chatIds {
            sqlite3_bind_int64(stmt, bindIndex, chatId)
            bindIndex += 1
        }
        sqlite3_bind_int64(stmt, bindIndex, Int64(limit))

        var rows: [MessageSyncRow] = []
        rows.reserveCapacity(min(limit, 2048))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = sqlite3_column_int64(stmt, 0)
            let dateRaw = columnInt64(stmt, 1)
            let isFromMe = Int(sqlite3_column_int(stmt, 2))
            let chatId = sqlite3_column_int64(stmt, 3)
            let handle = columnString(stmt, 4)
            let text = columnString(stmt, 5)

            rows.append(
                MessageSyncRow(
                    messageId: messageId,
                    chatId: chatId,
                    dateRaw: dateRaw,
                    isFromMe: isFromMe,
                    handle: handle,
                    text: text
                )
            )
        }

        return rows
    }

    func loadMessagesForCloudBackfill(
        dbURL: URL,
        beforeMessageId: Int64,
        chatIds: [Int64],
        limit: Int
    ) throws -> [MessageSyncRow] {
        guard !chatIds.isEmpty, limit > 0 else { return [] }

        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: chatIds.count).joined(separator: ",")
        let sql = """
            SELECT
                m.ROWID as message_id,
                m.date as date_raw,
                m.is_from_me as is_from_me,
                c.ROWID as chat_id,
                h.id as handle,
                m.text as text
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID < ?
              AND c.ROWID IN (\(placeholders))
              AND m.text IS NOT NULL
              AND length(trim(m.text)) > 0
            ORDER BY m.ROWID DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to prepare message history query: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        sqlite3_bind_int64(stmt, bindIndex, beforeMessageId)
        bindIndex += 1
        for chatId in chatIds {
            sqlite3_bind_int64(stmt, bindIndex, chatId)
            bindIndex += 1
        }
        sqlite3_bind_int64(stmt, bindIndex, Int64(limit))

        var rows: [MessageSyncRow] = []
        rows.reserveCapacity(min(limit, 2048))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = sqlite3_column_int64(stmt, 0)
            let dateRaw = columnInt64(stmt, 1)
            let isFromMe = Int(sqlite3_column_int(stmt, 2))
            let chatId = sqlite3_column_int64(stmt, 3)
            let handle = columnString(stmt, 4)
            let text = columnString(stmt, 5)

            rows.append(
                MessageSyncRow(
                    messageId: messageId,
                    chatId: chatId,
                    dateRaw: dateRaw,
                    isFromMe: isFromMe,
                    handle: handle,
                    text: text
                )
            )
        }

        return rows
    }

    func loadRecentTextMessagesForCloudSync(
        dbURL: URL,
        chatId: Int64,
        limit: Int
    ) throws -> [MessageSyncRow] {
        guard limit > 0 else { return [] }

        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let sql = """
            SELECT
                m.ROWID as message_id,
                m.date as date_raw,
                m.is_from_me as is_from_me,
                c.ROWID as chat_id,
                h.id as handle,
                m.text as text
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE c.ROWID = ?
              AND m.text IS NOT NULL
              AND length(trim(m.text)) > 0
            ORDER BY m.ROWID DESC
            LIMIT ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to prepare recent messages query: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, chatId)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var rows: [MessageSyncRow] = []
        rows.reserveCapacity(min(limit, 2048))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = sqlite3_column_int64(stmt, 0)
            let dateRaw = columnInt64(stmt, 1)
            let isFromMe = Int(sqlite3_column_int(stmt, 2))
            let chatId = sqlite3_column_int64(stmt, 3)
            let handle = columnString(stmt, 4)
            let text = columnString(stmt, 5)

            rows.append(
                MessageSyncRow(
                    messageId: messageId,
                    chatId: chatId,
                    dateRaw: dateRaw,
                    isFromMe: isFromMe,
                    handle: handle,
                    text: text
                )
            )
        }

        return rows
    }

    func detectDateScale(maxDateValue: Int64?) -> (Double, String) {
        guard let value = maxDateValue, value > 0 else {
            return (1, "seconds")
        }
        if value > 100_000_000_000_000_000 {
            return (1_000_000_000, "nanoseconds")
        }
        if value > 100_000_000_000_000 {
            return (1_000_000, "microseconds")
        }
        if value > 100_000_000_000 {
            return (1_000, "milliseconds")
        }
        return (1, "seconds")
    }

    func dateToAppleRaw(_ date: Date, divisor: Double) -> Int64 {
        let seconds = date.timeIntervalSince(appleEpoch)
        return Int64(seconds * divisor)
    }

    func loadMessages(dbURL: URL, sinceRaw: Int64?, untilRaw: Int64?) throws -> [Message] {
        let db = try openReadOnly(dbURL)
        defer {
            sqlite3_close(db)
        }

        var conditions: [String] = []
        var params: [Int64] = []
        if let sinceRaw {
            conditions.append("m.date >= ?")
            params.append(sinceRaw)
        }
        if let untilRaw {
            conditions.append("m.date <= ?")
            params.append(untilRaw)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"

        let sql = """
            SELECT
                m.ROWID as message_id,
                m.date as date_raw,
                m.date_read as date_read_raw,
                m.is_from_me as is_from_me,
                m.handle_id as handle_id,
                m.associated_message_type as associated_message_type,
                c.ROWID as chat_id,
                c.chat_identifier as chat_identifier,
                c.display_name as display_name,
                h.id as handle,
                m.text as text,
                COALESCE(
                    NULLIF((SELECT COUNT(DISTINCT chj.handle_id) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID), 0),
                    (SELECT COUNT(DISTINCT m2.handle_id)
                        FROM message m2
                        JOIN chat_message_join cmj2 ON m2.ROWID = cmj2.message_id
                        WHERE cmj2.chat_id = c.ROWID AND m2.handle_id IS NOT NULL),
                    1
                ) as participant_count,
                (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) as attachment_count,
                (SELECT GROUP_CONCAT(h2.id, '|') FROM chat_handle_join chj2 JOIN handle h2 ON h2.ROWID = chj2.handle_id WHERE chj2.chat_id = c.ROWID) as handle_list
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            \(whereClause)
            ORDER BY c.ROWID ASC, m.date ASC
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to prepare query: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (index, value) in params.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), value)
        }

        var messages: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let messageId = sqlite3_column_int64(stmt, 0)
            let dateRaw = columnInt64(stmt, 1)
            let dateReadRaw = columnInt64(stmt, 2)
            let isFromMe = Int(sqlite3_column_int(stmt, 3))
            let associatedMessageType = columnInt64(stmt, 5).map { Int($0) }
            let chatId = sqlite3_column_int64(stmt, 6)
            let chatIdentifier = columnString(stmt, 7) ?? "\(chatId)"
            let displayName = columnString(stmt, 8)
            let handle = columnString(stmt, 9)
            let text = columnString(stmt, 10)
            let participantCount = Int(sqlite3_column_int(stmt, 11))
            let attachmentCount = Int(sqlite3_column_int(stmt, 12))
            let handleList = columnString(stmt, 13)

            messages.append(
                Message(
                    messageId: messageId,
                    chatId: chatId,
                    chatIdentifier: chatIdentifier,
                    displayName: displayName,
                    handle: handle,
                    dateRaw: dateRaw,
                    dateReadRaw: dateReadRaw,
                    isFromMe: isFromMe,
                    participantCount: participantCount,
                    text: text,
                    associatedMessageType: associatedMessageType,
                    attachmentCount: attachmentCount,
                    handleList: handleList
                )
            )
        }

        return messages
    }

    func loadGroupPhotoMap(dbURL: URL) throws -> [Int64: String] {
        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let chatColumns = tableColumns(db, table: "chat")
        let photoColumn = preferredPhotoColumn(from: chatColumns)
        let hasProperties = chatColumns.contains("properties")

        var photoMap: [Int64: String] = [:]
        if let photoColumn {
            let sql = "SELECT ROWID, \(photoColumn) FROM chat WHERE \(photoColumn) IS NOT NULL"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.queryFailed("Failed to read group photos: \(msg)")
            }
            defer { sqlite3_finalize(stmt) }

            let attachByGuidSQL = "SELECT filename FROM attachment WHERE guid = ? LIMIT 1"
            let attachByRowSQL = "SELECT filename FROM attachment WHERE ROWID = ? LIMIT 1"
            var attachByGuidStmt: OpaquePointer?
            var attachByRowStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, attachByGuidSQL, -1, &attachByGuidStmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.queryFailed("Failed to prepare attachment lookup: \(msg)")
            }
            if sqlite3_prepare_v2(db, attachByRowSQL, -1, &attachByRowStmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.queryFailed("Failed to prepare attachment lookup: \(msg)")
            }
            defer {
                sqlite3_finalize(attachByGuidStmt)
                sqlite3_finalize(attachByRowStmt)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let chatId = sqlite3_column_int64(stmt, 0)
                guard let rawValue = columnString(stmt, 1), !rawValue.isEmpty else { continue }
                if let filename = lookupAttachmentFilename(db,
                                                         guidOrRow: rawValue,
                                                         byGuidStmt: attachByGuidStmt,
                                                         byRowStmt: attachByRowStmt) {
                    photoMap[chatId] = filename
                }
            }
        } else if hasProperties {
            let sql = "SELECT ROWID, properties FROM chat WHERE properties IS NOT NULL"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.queryFailed("Failed to read chat properties: \(msg)")
            }
            defer { sqlite3_finalize(stmt) }

            let attachByGuidSQL = "SELECT filename FROM attachment WHERE guid = ? LIMIT 1"
            var attachByGuidStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, attachByGuidSQL, -1, &attachByGuidStmt, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.queryFailed("Failed to prepare attachment lookup: \(msg)")
            }
            defer { sqlite3_finalize(attachByGuidStmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let chatId = sqlite3_column_int64(stmt, 0)
                guard let blob = columnData(stmt, 1) else { continue }
                if let photoGuid = extractGroupPhotoGuid(from: blob) {
                    if let filename = lookupAttachmentFilename(db,
                                                              guidOrRow: photoGuid,
                                                              byGuidStmt: attachByGuidStmt,
                                                              byRowStmt: nil) {
                        photoMap[chatId] = filename
                    }
                } else if let photoPath = extractGroupPhotoPath(from: blob) {
                    photoMap[chatId] = photoPath
                }
            }
        }

        return photoMap
    }

    func detectScaleFromDatabase(dbURL: URL) throws -> (Double, String) {
        let db = try openReadOnly(dbURL)
        defer { sqlite3_close(db) }

        let sql = "SELECT MAX(date) FROM message"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.queryFailed("Failed to read max date: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var maxDateValue: Int64?
        if sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                maxDateValue = sqlite3_column_int64(stmt, 0)
            }
        }

        return detectDateScale(maxDateValue: maxDateValue)
    }

    private func columnInt64(_ stmt: OpaquePointer?, _ idx: Int32) -> Int64? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL {
            return nil
        }
        return sqlite3_column_int64(stmt, idx)
    }

    private func columnData(_ stmt: OpaquePointer?, _ idx: Int32) -> Data? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL {
            return nil
        }
        guard let bytes = sqlite3_column_blob(stmt, idx) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, idx))
        return Data(bytes: bytes, count: length)
    }

    private func columnString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let stmt else { return nil }
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL {
            return nil
        }
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private func tableColumns(_ db: OpaquePointer?, table: String) -> [String] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var columns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnString(stmt, 1) {
                columns.append(name)
            }
        }
        return columns
    }

    private func preferredPhotoColumn(from columns: [String]) -> String? {
        let candidates = [
            "group_photo_guid",
            "group_photo_id",
            "photo_guid",
            "photo_id"
        ]
        for candidate in candidates {
            if columns.contains(candidate) { return candidate }
        }
        return nil
    }

    private func lookupAttachmentFilename(_ db: OpaquePointer?,
                                          guidOrRow: String,
                                          byGuidStmt: OpaquePointer?,
                                          byRowStmt: OpaquePointer?) -> String? {
        let trimmed = guidOrRow.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if let byRowStmt, let rowId = Int64(trimmed) {
            sqlite3_reset(byRowStmt)
            sqlite3_clear_bindings(byRowStmt)
            sqlite3_bind_int64(byRowStmt, 1, rowId)
            if sqlite3_step(byRowStmt) == SQLITE_ROW {
                if let filename = columnString(byRowStmt, 0) { return filename }
            }
        }

        if let byGuidStmt {
            sqlite3_reset(byGuidStmt)
            sqlite3_clear_bindings(byGuidStmt)
            sqlite3_bind_text(byGuidStmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            if sqlite3_step(byGuidStmt) == SQLITE_ROW {
                if let filename = columnString(byGuidStmt, 0) { return filename }
            }
        }

        return nil
    }

    private func extractGroupPhotoGuid(from data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            if let found = findString(in: plist, keys: ["groupPhotoGuid", "group_photo_guid"]) {
                return found
            }
        }
        if let unarchived = unarchivePlist(from: data) {
            if let found = findString(in: unarchived, keys: ["groupPhotoGuid", "group_photo_guid"]) {
                return found
            }
        }
        return nil
    }

    private func extractGroupPhotoPath(from data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            if let found = findString(in: plist, keys: ["groupPhotoPath", "group_photo_path"]) {
                return found
            }
        }
        if let unarchived = unarchivePlist(from: data) {
            if let found = findString(in: unarchived, keys: ["groupPhotoPath", "group_photo_path"]) {
                return found
            }
        }
        return nil
    }

    private func unarchivePlist(from data: Data) -> Any? {
        let classes: [AnyClass] = [
            NSDictionary.self,
            NSArray.self,
            NSString.self,
            NSNumber.self,
            NSData.self
        ]
        return try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)
    }

    private func findString(in value: Any, keys: Set<String>) -> String? {
        if let dict = value as? [String: Any] {
            for (key, val) in dict {
                if keys.contains(key), let str = val as? String {
                    return str
                }
                if let found = findString(in: val, keys: keys) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findString(in: item, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }
}
