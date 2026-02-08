import Foundation

final class ReportGenerator {
    private let dbReader = DatabaseReader()
    private let appleEpoch = Date(timeIntervalSince1970: 978307200)
    private let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "so", "to", "of", "in", "on", "at",
        "for", "from", "with", "about", "as", "is", "are", "was", "were", "be", "been", "being",
        "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his", "she", "her", "hers",
        "they", "them", "their", "theirs", "we", "us", "our", "ours", "it", "its",
        "this", "that", "these", "those", "there", "here", "not", "no", "yes", "yeah", "yep",
        "ok", "okay", "lol", "lmao", "omg", "idk", "imo", "im", "ive", "dont", "cant", "wont",
        "u", "ur", "r", "ya", "yall", "pls", "please", "thx", "thanks"
    ]
    private let romanticKeywords = [
        "love", "luv", "miss you", "xoxo", "babe", "baby", "bae", "sweetheart", "darling", "kiss",
        "heart", "ily", "i love you"
    ]
    private let professionalKeywords = [
        "meeting", "schedule", "deadline", "project", "report", "invoice", "client", "presentation",
        "email", "review", "sync", "agenda", "calendar", "update", "follow up", "follow-up", "deliverable"
    ]
    private let friendlyKeywords = [
        "lol", "haha", "lmao", "bro", "dude", "buddy", "pal", "hey", "yo", "sup", "cool", "nice",
        "chill", "omg", "idk", "thx", "thanks"
    ]

    struct Settings {
        let since: Date?
        let until: Date?
        let thresholdHours: Double
        let top: Int
    }

    func generate(dbURL: URL, outputFolder: URL, settings: Settings) throws -> ReportOutput {
        let (divisor, scaleLabel) = try dbReader.detectScaleFromDatabase(dbURL: dbURL)

        let sinceRaw: Int64?
        if let since = settings.since {
            sinceRaw = dateToAppleRaw(since, divisor: divisor)
        } else {
            sinceRaw = nil
        }

        let untilRaw: Int64?
        if let until = settings.until {
            let inclusive = Calendar.current.date(byAdding: .day, value: 1, to: until) ?? until
            untilRaw = dateToAppleRaw(inclusive, divisor: divisor)
        } else {
            untilRaw = nil
        }

        let messages = try dbReader.loadMessages(dbURL: dbURL, sinceRaw: sinceRaw, untilRaw: untilRaw)
        let groupPhotoMap = try dbReader.loadGroupPhotoMap(dbURL: dbURL)
        let report = buildReport(
            messages: messages,
            divisor: divisor,
            groupPhotoMap: groupPhotoMap,
            thresholdHours: settings.thresholdHours,
            top: settings.top,
            scaleLabel: scaleLabel,
            since: settings.since,
            until: settings.until
        )

        let outputURLs = try writeReport(report: report, outputFolder: outputFolder)
        return ReportOutput(report: report, htmlURL: outputURLs.htmlURL, jsonURL: outputURLs.jsonURL)
    }

    private func dateToAppleRaw(_ date: Date, divisor: Double) -> Int64 {
        let seconds = date.timeIntervalSince(appleEpoch)
        return Int64(seconds * divisor)
    }

    private func dateFromAppleRaw(_ raw: Int64, divisor: Double) -> Date {
        let seconds = Double(raw) / divisor
        return appleEpoch.addingTimeInterval(seconds)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        var tokens: [String] = []
        var current = ""

        func flush() {
            if current.count >= 3,
               !stopWords.contains(current),
               current.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil {
                tokens.append(current)
            }
            current = ""
        }

        for ch in lower {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty { flush() }
            }
        }
        if !current.isEmpty { flush() }
        return tokens
    }

    private func phrases(from text: String) -> [String] {
        let tokens = tokenize(text)
        guard tokens.count >= 2 else { return [] }
        var result: [String] = []
        for i in 0..<(tokens.count - 1) {
            let phrase = "\(tokens[i]) \(tokens[i + 1])"
            result.append(phrase)
        }
        return result
    }

    private func extractEmojis(_ text: String) -> [String] {
        var result: [String] = []
        for ch in text {
            let scalars = ch.unicodeScalars
            let isEmoji = scalars.contains(where: { scalar in
                if scalar.properties.isEmojiPresentation { return true }
                if scalar.properties.isEmoji && !scalar.isASCII { return true }
                return false
            })
            if isEmoji {
                let isOnlyAlnum = scalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                if isOnlyAlnum { continue }
                result.append(String(ch))
            }
        }
        return result
    }

    private enum MoodCategory: String {
        case friendly
        case romantic
        case professional
        case neutral
    }

    private func moodCategory(for text: String) -> MoodCategory {
        let lower = text.lowercased()
        if romanticKeywords.contains(where: { lower.contains($0) }) {
            return .romantic
        }
        if professionalKeywords.contains(where: { lower.contains($0) }) {
            return .professional
        }
        if friendlyKeywords.contains(where: { lower.contains($0) }) {
            return .friendly
        }
        return .neutral
    }

    private func moodLabel(_ mood: MoodCategory) -> String {
        switch mood {
        case .friendly: return "Friendly"
        case .romantic: return "Romantic"
        case .professional: return "Professional"
        case .neutral: return "Neutral"
        }
    }

    private func isGoodMorning(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.contains("good morning")
            || lower == "gm"
            || lower.hasPrefix("gm ")
            || lower.contains(" goodmorning")
    }

    private func isGoodNight(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower.contains("good night")
            || lower.contains("goodnight")
            || lower == "gn"
            || lower.hasPrefix("gn ")
            || lower.contains(" gnight")
    }

    private func replyBuckets(from minutes: [Double]) -> ReplyBucketStats {
        var under5m = 0
        var under1h = 0
        var under6h = 0
        var under24h = 0
        var under7d = 0
        var over7d = 0

        for value in minutes {
            if value <= 5 { under5m += 1 }
            else if value <= 60 { under1h += 1 }
            else if value <= 360 { under6h += 1 }
            else if value <= 1440 { under24h += 1 }
            else if value <= 10080 { under7d += 1 }
            else { over7d += 1 }
        }

        return ReplyBucketStats(
            under5m: under5m,
            under1h: under1h,
            under6h: under6h,
            under24h: under24h,
            under7d: under7d,
            over7d: over7d
        )
    }

    private func reactionLabel(from text: String?) -> String? {
        guard let text else { return nil }
        let candidates = [
            "Loved",
            "Liked",
            "Disliked",
            "Laughed at",
            "Emphasized",
            "Questioned"
        ]
        for prefix in candidates {
            if text.hasPrefix(prefix) {
                return prefix
            }
        }
        return nil
    }

    private func computeStreaks(activeDays: [Date]) -> StreakStats {
        guard !activeDays.isEmpty else {
            return StreakStats(currentDays: 0, longestDays: 0, longestSilenceDays: 0)
        }

        let calendar = Calendar.current
        let sorted = activeDays.sorted()
        var longest = 1
        var currentRun = 1
        var longestSilence = 0

        for idx in 1..<sorted.count {
            let prev = sorted[idx - 1]
            let current = sorted[idx]
            let diff = calendar.dateComponents([.day], from: prev, to: current).day ?? 0
            if diff == 1 {
                currentRun += 1
            } else {
                if diff > 1 {
                    longestSilence = max(longestSilence, diff - 1)
                }
                longest = max(longest, currentRun)
                currentRun = 1
            }
        }
        longest = max(longest, currentRun)

        let last = sorted.last!
        var streak = 1
        var cursor = last
        for idx in stride(from: sorted.count - 2, through: 0, by: -1) {
            let prev = sorted[idx]
            let diff = calendar.dateComponents([.day], from: prev, to: cursor).day ?? 0
            if diff == 1 {
                streak += 1
                cursor = prev
            } else {
                break
            }
        }

        return StreakStats(currentDays: streak, longestDays: longest, longestSilenceDays: longestSilence)
    }

    private func computeEnergyScore(totalMessages: Int, activeDays: Int, rangeDays: Int, switchRate: Double) -> Int {
        guard totalMessages > 0 else { return 0 }
        let perActiveDay = Double(totalMessages) / Double(max(activeDays, 1))
        let activityScore = min(1.0, log10(perActiveDay + 1) / log10(50))
        let consistencyScore = min(1.0, Double(activeDays) / Double(max(rangeDays, 1)))
        let backAndForthScore = min(1.0, max(0.0, switchRate))
        let score = 100.0 * (0.4 * activityScore + 0.3 * consistencyScore + 0.3 * backAndForthScore)
        return Int(score.rounded())
    }

    private func cleanIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("iMessage;") {
            return String(trimmed.dropFirst("iMessage;".count))
        }
        if trimmed.hasPrefix("SMS;") {
            return String(trimmed.dropFirst("SMS;".count))
        }
        if trimmed.hasPrefix("mailto:") {
            return String(trimmed.dropFirst(7))
        }
        if trimmed.hasPrefix("tel:") {
            return String(trimmed.dropFirst(4))
        }
        if trimmed.hasPrefix("p:") || trimmed.hasPrefix("e:") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private func looksLikeHandle(_ value: String) -> Bool {
        let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("@") { return true }
        let digits = lower.filter { $0.isNumber }
        let letters = lower.filter { $0.isLetter }
        return !digits.isEmpty && letters.isEmpty
    }

    private func extractHandleList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: "|")
            .map { cleanIdentifier(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func extractHandleListRaw(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func contactHandleVariants(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        var cleaned = trimmed
        let lower = cleaned.lowercased()
        if lower.hasPrefix("imessage;") {
            cleaned = String(cleaned.dropFirst("iMessage;".count))
        } else if lower.hasPrefix("sms;") {
            cleaned = String(cleaned.dropFirst("SMS;".count))
        } else if lower.hasPrefix("mailto:") {
            cleaned = String(cleaned.dropFirst("mailto:".count))
        } else if lower.hasPrefix("tel:") {
            cleaned = String(cleaned.dropFirst("tel:".count))
        } else if lower.hasPrefix("p:") || lower.hasPrefix("e:") {
            cleaned = String(cleaned.dropFirst(2))
        }

        let normalized = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        var variants: [String] = []
        if !trimmed.isEmpty { variants.append(trimmed) }
        if !normalized.isEmpty { variants.append(normalized) }
        let normalizedLower = normalized.lowercased()
        if normalizedLower != normalized { variants.append(normalizedLower) }

        if normalizedLower.contains("@") {
            return Array(Set(variants))
        }

        let digits = normalizedLower.filter { $0.isNumber }
        if !digits.isEmpty {
            variants.append(digits)
            if digits.count > 10 {
                variants.append(String(digits.suffix(10)))
            }
        }

        return Array(Set(variants))
    }

    private func normalizedMergeKey(_ value: String) -> String? {
        let variants = contactHandleVariants(value)
        if let email = variants.first(where: { $0.contains("@") }) {
            return email.lowercased()
        }
        if let digits = variants.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
            return digits
        }
        return variants.first
    }

    private func buildReport(
        messages: [Message],
        divisor: Double,
        groupPhotoMap: [Int64: String],
        thresholdHours: Double,
        top: Int,
        scaleLabel: String,
        since: Date?,
        until: Date?
    ) -> Report {
        let thresholdSeconds = thresholdHours * 3600
        let maxLeftOnReadSeconds = 7.0 * 24.0 * 3600.0
        let initiationGapSeconds = 6.0 * 3600.0
        let silenceThresholdSeconds = 12.0 * 3600.0
        let nowDate = Date()
        let nowRaw = dateToAppleRaw(nowDate, divisor: divisor)

        var messagesByChat: [Int64: [Message]] = [:]
        for msg in messages {
            messagesByChat[msg.chatId, default: []].append(msg)
        }

        let contactResolver = ContactsResolver()
        let isoFormatter = ISO8601DateFormatter()

        var chatReports: [ChatReport] = []
        var totalsSent = 0
        var totalsReceived = 0
        var leftOnReadYou = 0
        var leftOnReadThem = 0
        var youReplyMinutes: [Double] = []
        var themReplyMinutes: [Double] = []

        var dailyMap: [Date: (sent: Int, received: Int)] = [:]
        var latestDate: Date?
        let calendar = Calendar.current
        let cutoff30 = calendar.date(byAdding: .day, value: -30, to: nowDate)
        let cutoff90 = calendar.date(byAdding: .day, value: -90, to: nowDate)

        for (_, msgs) in messagesByChat {
            guard let first = msgs.first else { continue }
            func keyForHandle(_ handle: String?) -> String {
                let cleaned = handle.map(cleanIdentifier(_:))
                return nonEmpty(cleaned ?? handle) ?? "unknown"
            }
            let rawDisplayName = nonEmpty(first.displayName)
            let displayName = rawDisplayName.flatMap { looksLikeHandle($0) ? nil : $0 }
            let nonMeHandle = msgs.first(where: { $0.isFromMe == 0 && $0.handle != nil })?.handle
            let fallbackHandleRaw = nonMeHandle ?? msgs.first(where: { $0.handle != nil })?.handle
            let fallbackHandle = fallbackHandleRaw.map(cleanIdentifier(_:))
            let chatIdentifier = cleanIdentifier(first.chatIdentifier)
            let handleList = extractHandleList(first.handleList)
            let handleListRaw = extractHandleListRaw(first.handleList)
            let resolvedName = ([fallbackHandleRaw, fallbackHandle, chatIdentifier] + handleList)
                .compactMap { $0 }
                .compactMap { contactResolver.displayName(for: $0) }
                .first
            let hasOther = msgs.contains { $0.isFromMe == 0 }

            var sent = 0
            var received = 0
            var youLeft = 0
            var themLeft = 0
            var youReply: [Double] = []
            var themReply: [Double] = []
            var lastMessageDate: Date?
            var firstMessageText: String?
            var firstMessageDate: Date?
            var firstMessageFromMe: Bool?
            var firstDateInChat: Date?
            var firstConversation: [(sender: String, text: String)] = []
            var firstConversationStarted = false
            var firstConversationClosed = false
            var lastConversationDate: Date?
            let conversationBreakSeconds = 5.0 * 60.0

            var switchCount = 0
            var previousSender: Int?
            var previousDate: Date?
            var currentDay: Date?
            var previousSenderForDay: Int?
            var currentAltRun = 1
            var longestBackAndForth = 1

            var initiationsYou = 0
            var initiationsThem = 0
            var reengageGapsYou: [Double] = []
            var reengageGapsThem: [Double] = []
            var reengageCountYou = 0
            var reengageCountThem = 0

            var hoursYou = Array(repeating: 0, count: 24)
            var hoursThem = Array(repeating: 0, count: 24)
            var activeDays: Set<Date> = []
            var dailyChatMap: [Date: Int] = [:]

            var emojiCounts: [String: Int] = [:]
            var emojiCountsYou: [String: Int] = [:]
            var emojiCountsThem: [String: Int] = [:]
            var reactionCounts: [String: Int] = [:]
            var attachmentsYou = 0
            var attachmentsThem = 0
            var last30Count = 0
            var last90Count = 0
            var moodSummaryCounts = (friendly: 0, romantic: 0, professional: 0, neutral: 0)
            var moodDailyMap: [Date: (friendly: Int, romantic: Int, professional: Int, neutral: Int)] = [:]
            var greetYouMorning = 0
            var greetThemMorning = 0
            var greetYouNight = 0
            var greetThemNight = 0
            var replyTimesByParticipant: [String: [Double]] = [:]
            var weekdayCounts = Array(repeating: (total: 0, you: 0, them: 0), count: 7)
            var phraseCounts: [String: Int] = [:]
            var phraseMoodCounts: [MoodCategory: [String: (you: Int, them: Int)]] = [:]
            var otherHandles: Set<String> = []

            let nextTimes = nextOppositeTimes(msgs)
            var nextNonMeIndex: [Int?] = Array(repeating: nil, count: msgs.count)
            var lastNonMe: Int?
            for idx in stride(from: msgs.count - 1, through: 0, by: -1) {
                nextNonMeIndex[idx] = lastNonMe
                if msgs[idx].isFromMe == 0 {
                    lastNonMe = idx
                }
            }

            var senderCounts: [String: Int] = [:]
            var senderLabels: [String: String] = [:]
            var wordCounts: [String: Int] = [:]
            var wordCountsYou: [String: Int] = [:]
            var wordCountsThem: [String: Int] = [:]
            for (idx, msg) in msgs.enumerated() {
                let isReaction = (msg.associatedMessageType ?? 0) != 0
                if msg.isFromMe == 1 {
                    sent += 1
                    senderCounts["me", default: 0] += 1
                    senderLabels["me"] = "You"
                } else {
                    received += 1
                    let rawHandle = msg.handle
                    let key = keyForHandle(rawHandle)
                    senderCounts[key, default: 0] += 1
                    let display = rawHandle.flatMap { contactResolver.displayName(for: $0) }
                        ?? contactResolver.displayName(for: key)
                        ?? (key == "unknown" ? "Unknown" : key)
                    senderLabels[key] = display
                    if let rawHandle {
                        for variant in contactHandleVariants(rawHandle) {
                            otherHandles.insert(variant)
                        }
                    }
                }
                if let text = msg.text, !text.isEmpty, !isReaction {
                    for word in tokenize(text) {
                        wordCounts[word, default: 0] += 1
                        if msg.isFromMe == 1 {
                            wordCountsYou[word, default: 0] += 1
                        } else {
                            wordCountsThem[word, default: 0] += 1
                        }
                    }

                    for emoji in extractEmojis(text) {
                        emojiCounts[emoji, default: 0] += 1
                        if msg.isFromMe == 1 {
                            emojiCountsYou[emoji, default: 0] += 1
                        } else {
                            emojiCountsThem[emoji, default: 0] += 1
                        }
                    }

                    if let reaction = reactionLabel(from: text) {
                        reactionCounts[reaction, default: 0] += 1
                    }

                    let mood = moodCategory(for: text)

                    for phrase in phrases(from: text) {
                        phraseCounts[phrase, default: 0] += 1
                        var entry = phraseMoodCounts[mood]?[phrase] ?? (0, 0)
                        if msg.isFromMe == 1 {
                            entry.you += 1
                        } else {
                            entry.them += 1
                        }
                        var moodMap = phraseMoodCounts[mood] ?? [:]
                        moodMap[phrase] = entry
                        phraseMoodCounts[mood] = moodMap
                    }
                    switch mood {
                    case .friendly: moodSummaryCounts.friendly += 1
                    case .romantic: moodSummaryCounts.romantic += 1
                    case .professional: moodSummaryCounts.professional += 1
                    case .neutral: moodSummaryCounts.neutral += 1
                    }

                    if let dayDate = msg.dateRaw.map({ dateFromAppleRaw($0, divisor: divisor) }).map({ calendar.startOfDay(for: $0) }) {
                        var entry = moodDailyMap[dayDate] ?? (0, 0, 0, 0)
                        switch mood {
                        case .friendly: entry.friendly += 1
                        case .romantic: entry.romantic += 1
                        case .professional: entry.professional += 1
                        case .neutral: entry.neutral += 1
                        }
                        moodDailyMap[dayDate] = entry
                    }

                    if isGoodMorning(text) {
                        if msg.isFromMe == 1 { greetYouMorning += 1 } else { greetThemMorning += 1 }
                    }
                    if isGoodNight(text) {
                        if msg.isFromMe == 1 { greetYouNight += 1 } else { greetThemNight += 1 }
                    }
                }

                if msg.attachmentCount > 0 {
                    if msg.isFromMe == 1 {
                        attachmentsYou += msg.attachmentCount
                    } else {
                        attachmentsThem += msg.attachmentCount
                    }
                }

                let messageDate = msg.dateRaw.map { dateFromAppleRaw($0, divisor: divisor) }

                if firstMessageText == nil, let text = nonEmpty(msg.text), !isReaction {
                    firstMessageText = text
                    firstMessageFromMe = (msg.isFromMe == 1)
                    if let date = messageDate {
                        firstMessageDate = date
                    }
                }

                if !firstConversationClosed, let text = nonEmpty(msg.text), !isReaction {
                    let senderLabel: String
                    if msg.isFromMe == 1 {
                        senderLabel = "You"
                    } else {
                        let rawHandle = msg.handle
                        let cleaned = rawHandle.map(cleanIdentifier(_:))
                        senderLabel = rawHandle.flatMap { contactResolver.displayName(for: $0) }
                            ?? cleaned.flatMap { contactResolver.displayName(for: $0) }
                            ?? cleaned
                            ?? rawHandle
                            ?? "Unknown"
                    }

                    if let currentDate = messageDate, let lastDate = lastConversationDate, firstConversationStarted {
                        let gap = currentDate.timeIntervalSince(lastDate)
                        if gap > conversationBreakSeconds {
                            firstConversationClosed = true
                        }
                    }

                    if !firstConversationClosed {
                        firstConversation.append((sender: senderLabel, text: text))
                        firstConversationStarted = true
                        if let currentDate = messageDate {
                            lastConversationDate = currentDate
                        }
                    }
                }

                if let date = messageDate {
                    if firstDateInChat == nil { firstDateInChat = date }

                    if let last = lastMessageDate {
                        if date > last { lastMessageDate = date }
                    } else {
                        lastMessageDate = date
                    }

                    let day = calendar.startOfDay(for: date)
                    activeDays.insert(day)
                    dailyChatMap[day, default: 0] += 1

                    var entry = dailyMap[day] ?? (0, 0)
                    if msg.isFromMe == 1 {
                        entry.sent += 1
                    } else {
                        entry.received += 1
                    }
                    dailyMap[day] = entry
                    if let latest = latestDate {
                        if date > latest { latestDate = date }
                    } else {
                        latestDate = date
                    }

                    let hour = calendar.component(.hour, from: date)
                    if msg.isFromMe == 1 {
                        hoursYou[hour] += 1
                    } else {
                        hoursThem[hour] += 1
                    }

                    let weekdayIndex = (calendar.component(.weekday, from: date) + 5) % 7
                    weekdayCounts[weekdayIndex].total += 1
                    if msg.isFromMe == 1 {
                        weekdayCounts[weekdayIndex].you += 1
                    } else {
                        weekdayCounts[weekdayIndex].them += 1
                    }

                    if let cutoff30, date >= cutoff30 {
                        last30Count += 1
                    }
                    if let cutoff90, date >= cutoff90 {
                        last90Count += 1
                    }

                    if let prev = previousDate {
                        let gap = date.timeIntervalSince(prev)
                        if gap > initiationGapSeconds {
                            if msg.isFromMe == 1 {
                                initiationsYou += 1
                            } else {
                                initiationsThem += 1
                            }
                        }
                        if gap > silenceThresholdSeconds {
                            if msg.isFromMe == 1 {
                                reengageGapsYou.append(gap)
                                reengageCountYou += 1
                            } else {
                                reengageGapsThem.append(gap)
                                reengageCountThem += 1
                            }
                        }
                    } else {
                        if msg.isFromMe == 1 {
                            initiationsYou += 1
                        } else {
                            initiationsThem += 1
                        }
                    }
                    previousDate = date

                    if currentDay == nil || currentDay != day {
                        currentDay = day
                        previousSenderForDay = msg.isFromMe
                        currentAltRun = 1
                    } else {
                        if let previousSenderForDay {
                            if msg.isFromMe != previousSenderForDay {
                                currentAltRun += 1
                            } else {
                                currentAltRun = 1
                            }
                        }
                        previousSenderForDay = msg.isFromMe
                    }
                    longestBackAndForth = max(longestBackAndForth, currentAltRun)
                }

                if let prevSender = previousSender {
                    if msg.isFromMe != prevSender {
                        switchCount += 1
                    }
                }
                previousSender = msg.isFromMe

                if msg.isFromMe == 1, let nextIndex = nextNonMeIndex[idx] {
                    if let nextRaw = msgs[nextIndex].dateRaw, let dateRaw = msg.dateRaw {
                        let dtSeconds = Double(nextRaw - dateRaw) / divisor
                        if dtSeconds >= 0 {
                            let minutes = dtSeconds / 60
                            let key = keyForHandle(msgs[nextIndex].handle)
                            replyTimesByParticipant[key, default: []].append(minutes)
                        }
                    }
                }

                if let nextRaw = nextTimes[idx], let dateRaw = msg.dateRaw {
                    let dtSeconds = Double(nextRaw - dateRaw) / divisor
                    if dtSeconds >= 0 {
                        let minutes = dtSeconds / 60
                        if msg.isFromMe == 1 {
                            themReply.append(minutes)
                        } else {
                            youReply.append(minutes)
                        }
                    }
                }

                let dateReadRaw = (msg.dateReadRaw == 0) ? nil : msg.dateReadRaw
                if let readRaw = dateReadRaw, msg.dateRaw != nil {
                    let nextRaw = nextTimes[idx]
                    var repliedInTime = false
                    if let nextRaw = nextRaw {
                        let dtSeconds = Double(nextRaw - readRaw) / divisor
                        if dtSeconds >= 0 && dtSeconds <= thresholdSeconds {
                            repliedInTime = true
                        }
                    }
                    let withinMaxWindow: Bool
                    if let nextRaw = nextRaw {
                        let dtSeconds = Double(nextRaw - readRaw) / divisor
                        withinMaxWindow = dtSeconds >= 0 && dtSeconds <= maxLeftOnReadSeconds
                    } else {
                        let dtToNow = Double(nowRaw - readRaw) / divisor
                        withinMaxWindow = dtToNow >= 0 && dtToNow <= maxLeftOnReadSeconds
                    }
                    if msg.isFromMe == 1 {
                        if withinMaxWindow && !repliedInTime { themLeft += 1 }
                    } else {
                        if withinMaxWindow && !repliedInTime { youLeft += 1 }
                    }
                }
            }

            let totalMessages = sent + received
            let activeDayList = Array(activeDays)
            let streaks = computeStreaks(activeDays: activeDayList)
            let rangeDays: Int = {
                guard let first = firstDateInChat, let last = lastMessageDate else {
                    return max(activeDayList.count, 1)
                }
                let diff = calendar.dateComponents([.day], from: first, to: last).day ?? 0
                return max(diff + 1, 1)
            }()
            let switchRate = totalMessages > 1 ? Double(switchCount) / Double(totalMessages - 1) : 0
            let energyScore = computeEnergyScore(
                totalMessages: totalMessages,
                activeDays: activeDayList.count,
                rangeDays: rangeDays,
                switchRate: switchRate
            )

            let mostIntense: (date: Date?, total: Int) = {
                if let maxEntry = dailyChatMap.max(by: { $0.value < $1.value }) {
                    return (maxEntry.key, maxEntry.value)
                }
                return (nil, 0)
            }()

            let timeBins: [TimeOfDayBin] = (0..<24).map { hour in
                let you = hoursYou[hour]
                let them = hoursThem[hour]
                return TimeOfDayBin(id: hour, hour: hour, total: you + them, you: you, them: them)
            }

            let totalForBalance = max(totalMessages, 1)
            let recentBalance = RecentBalance(
                last30: last30Count,
                last90: last90Count,
                total: totalMessages,
                last30Pct: (Double(last30Count) / Double(totalForBalance)) * 100.0,
                last90Pct: (Double(last90Count) / Double(totalForBalance)) * 100.0
            )

            let reengagement = ReengagementStats(
                youAvgGapHours: reengageGapsYou.isEmpty ? nil : reengageGapsYou.reduce(0, +) / Double(reengageGapsYou.count) / 3600.0,
                themAvgGapHours: reengageGapsThem.isEmpty ? nil : reengageGapsThem.reduce(0, +) / Double(reengageGapsThem.count) / 3600.0,
                youCount: reengageCountYou,
                themCount: reengageCountThem
            )

            let attachments = AttachmentStats(
                you: attachmentsYou,
                them: attachmentsThem,
                total: attachmentsYou + attachmentsThem
            )

            let topEmojis = emojiCounts
                .sorted { $0.value > $1.value }
                .prefix(10)
                .map { EmojiStat(id: $0.key, emoji: $0.key, count: $0.value) }

            let topEmojisYou = emojiCountsYou
                .sorted { $0.value > $1.value }
                .prefix(10)
                .map { EmojiStat(id: $0.key, emoji: $0.key, count: $0.value) }

            let topEmojisThem = emojiCountsThem
                .sorted { $0.value > $1.value }
                .prefix(10)
                .map { EmojiStat(id: $0.key, emoji: $0.key, count: $0.value) }

            let reactions = reactionCounts
                .sorted { $0.value > $1.value }
                .prefix(6)
                .map { ReactionStat(id: $0.key, reaction: $0.key, count: $0.value) }

            let participantReplySpeeds: [ParticipantReplyStat] = replyTimesByParticipant
                .filter { $0.key != "unknown" }
                .map { key, times in
                    let avg = times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
                    let label = senderLabels[key] ?? key
                    return ParticipantReplyStat(id: key, label: label, avgMinutes: avg)
                }
                .sorted { ($0.avgMinutes ?? 1e12) < ($1.avgMinutes ?? 1e12) }

            let weekdayActivity: [WeekdayBin] = weekdayCounts.enumerated().map { idx, entry in
                WeekdayBin(id: idx, weekday: idx, total: entry.total, you: entry.you, them: entry.them)
            }

            let topPhrases: [PhraseStat] = phraseCounts
                .sorted { $0.value > $1.value }
                .prefix(10)
                .map { PhraseStat(id: $0.key, phrase: $0.key, count: $0.value) }

            let phraseMoods: [PhraseMoodStat] = phraseMoodCounts.flatMap { mood, phrases in
                phrases.map { phrase, counts in
                    PhraseMoodStat(
                        id: "\(mood.rawValue)-\(phrase)",
                        phrase: phrase,
                        mood: moodLabel(mood),
                        youCount: counts.you,
                        themCount: counts.them
                    )
                }
            }

            let replyBuckets = ReplySpeedBuckets(
                you: replyBuckets(from: youReply),
                them: replyBuckets(from: themReply)
            )

            let moodSummary = MoodSummary(
                friendly: moodSummaryCounts.friendly,
                romantic: moodSummaryCounts.romantic,
                professional: moodSummaryCounts.professional,
                neutral: moodSummaryCounts.neutral
            )

            let moodTimeline = moodDailyMap.keys.sorted().map { day in
                let entry = moodDailyMap[day] ?? (0, 0, 0, 0)
                return MoodDaily(
                    id: isoFormatter.string(from: day),
                    date: isoFormatter.string(from: day),
                    friendly: entry.friendly,
                    romantic: entry.romantic,
                    professional: entry.professional,
                    neutral: entry.neutral
                )
            }

            let greetings = GreetingStats(
                youMorning: greetYouMorning,
                themMorning: greetThemMorning,
                youNight: greetYouNight,
                themNight: greetThemNight
            )

            totalsSent += sent
            totalsReceived += received
            leftOnReadYou += youLeft
            leftOnReadThem += themLeft
            youReplyMinutes.append(contentsOf: youReply)
            themReplyMinutes.append(contentsOf: themReply)

            let distinctOtherKeys = Set(senderCounts.keys.filter { $0 != "me" && $0 != "unknown" })
            let isGroup = distinctOtherKeys.count > 1 || first.chatIdentifier.lowercased().hasPrefix("chat")
            let displayParticipantCount = isGroup ? max(distinctOtherKeys.count + 1, 2) : (hasOther ? 2 : 1)

            let handleNames = handleList.compactMap { contactResolver.displayName(for: $0) }.filter { !$0.isEmpty }
            let groupLabelFallback: String? = {
                if !handleNames.isEmpty {
                    return handleNames.prefix(3).joined(separator: ", ")
                }
                if !handleList.isEmpty {
                    return handleList.prefix(3).joined(separator: ", ")
                }
                return nil
            }()

            let finalLabel: String = {
                if isGroup {
                    if let displayName, !displayName.isEmpty { return displayName }
                    if let resolvedName, !resolvedName.isEmpty { return resolvedName }
                    if let groupLabelFallback { return groupLabelFallback }
                    return "Group chat"
                } else {
                    if let displayName, !displayName.isEmpty { return displayName }
                    if let resolvedName, !resolvedName.isEmpty { return resolvedName }
                    if let fallbackHandle, !fallbackHandle.isEmpty { return fallbackHandle }
                    return chatIdentifier.isEmpty ? "Unknown" : chatIdentifier
                }
            }()

            if !isGroup, let otherKey = distinctOtherKeys.first {
                senderLabels[otherKey] = finalLabel
            }

            if !isGroup, !finalLabel.isEmpty {
                firstConversation = firstConversation.map { line in
                    if line.sender == "You" { return line }
                    return (sender: finalLabel, text: line.text)
                }
            }

            if otherHandles.isEmpty {
                for handle in handleListRaw {
                    for variant in contactHandleVariants(handle) {
                        otherHandles.insert(variant)
                    }
                }
            }
            if let fallbackHandleRaw, !fallbackHandleRaw.isEmpty {
                for variant in contactHandleVariants(fallbackHandleRaw) {
                    otherHandles.insert(variant)
                }
            }
            if !chatIdentifier.isEmpty {
                for variant in contactHandleVariants(chatIdentifier) {
                    otherHandles.insert(variant)
                }
            }
            let contactHandles = Array(otherHandles).sorted()

            let contactKey: String? = {
                guard !isGroup else { return nil }
                let candidates: [String] = ([fallbackHandleRaw, fallbackHandle, chatIdentifier] + handleListRaw + handleList)
                    .compactMap { $0 }

                for candidate in candidates {
                    if let id = contactResolver.contactIdentifier(for: candidate) {
                        return "contact:\(id)"
                    }
                }

                if let id = contactResolver.contactIdentifier(forName: finalLabel) {
                    return "contact:\(id)"
                }

                for candidate in candidates {
                    if let normalized = normalizedMergeKey(candidate) {
                        return "handle:\(normalized)"
                    }
                }
                return nil
            }()

            let chatReport = ChatReport(
                id: first.chatId,
                chatIdentifier: first.chatIdentifier,
                displayName: first.displayName,
                label: finalLabel,
                contactHandles: contactHandles,
                contactKey: contactKey,
                groupPhotoPath: groupPhotoMap[first.chatId],
                totals: Totals(sent: sent, received: received, total: totalMessages),
                leftOnRead: LeftOnRead(youLeftThem: youLeft, theyLeftYou: themLeft),
                responseTimes: ResponseTimes(
                    youReply: summarizeResponseTimes(youReply),
                    theyReply: summarizeResponseTimes(themReply)
                ),
                lastMessageDate: lastMessageDate.map { isoFormatter.string(from: $0) },
                firstMessageText: firstMessageText,
                firstMessageDate: firstMessageDate.map { isoFormatter.string(from: $0) },
                firstMessageFromMe: firstMessageFromMe,
                energyScore: energyScore,
                streaks: streaks,
                initiators: InitiatorStats(youStarted: initiationsYou, themStarted: initiationsThem),
                peak: ConversationPeak(
                    date: mostIntense.date.map { isoFormatter.string(from: $0) },
                    total: mostIntense.total,
                    longestBackAndForth: longestBackAndForth
                ),
                reengagement: reengagement,
                timeOfDay: timeBins,
                recentBalance: recentBalance,
                attachments: attachments,
                topEmojis: topEmojis,
                topEmojisYou: topEmojisYou,
                topEmojisThem: topEmojisThem,
                reactions: reactions,
                replyBuckets: replyBuckets,
                moodSummary: moodSummary,
                moodTimeline: moodTimeline,
                greetings: greetings,
                firstConversation: firstConversation.enumerated().map { idx, line in
                    ConversationLine(id: "\(first.chatId)-\(idx)", sender: line.sender, text: line.text)
                },
                participantReplySpeeds: participantReplySpeeds,
                weekdayActivity: weekdayActivity,
                topPhrases: topPhrases,
                phraseMoods: phraseMoods,
                participantCount: displayParticipantCount,
                isGroup: isGroup,
                participants: senderCounts
                    .map { ParticipantStat(id: $0.key, label: senderLabels[$0.key] ?? $0.key, count: $0.value) }
                    .sorted { $0.count > $1.count },
                topWords: wordCounts
                    .sorted { $0.value > $1.value }
                    .prefix(10)
                    .map { WordStat(id: $0.key, word: $0.key, count: $0.value) },
                topWordsYou: wordCountsYou
                    .sorted { $0.value > $1.value }
                    .prefix(10)
                    .map { WordStat(id: $0.key, word: $0.key, count: $0.value) },
                topWordsThem: wordCountsThem
                    .sorted { $0.value > $1.value }
                    .prefix(10)
                    .map { WordStat(id: $0.key, word: $0.key, count: $0.value) }
            )
            chatReports.append(chatReport)
        }

        let endDay = calendar.startOfDay(for: latestDate ?? Date())
        let startDay = calendar.date(byAdding: .day, value: -29, to: endDay) ?? endDay
        var daily: [DailyCount] = []
        let labelFormatter = DateFormatter()
        labelFormatter.locale = Locale.current
        labelFormatter.dateFormat = "MMM d"
        let idFormatter = DateFormatter()
        idFormatter.locale = Locale.current
        idFormatter.dateFormat = "yyyy-MM-dd"

        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let entry = dailyMap[day] ?? (0, 0)
            let total = entry.sent + entry.received
            daily.append(
                DailyCount(
                    id: idFormatter.string(from: day),
                    date: labelFormatter.string(from: day),
                    sent: entry.sent,
                    received: entry.received,
                    total: total
                )
            )
        }

        chatReports.sort { $0.totals.total > $1.totals.total }
        if chatReports.count > top {
            chatReports = Array(chatReports.prefix(top))
        }

        let summary = Summary(
            totals: Totals(sent: totalsSent, received: totalsReceived, total: totalsSent + totalsReceived),
            leftOnRead: LeftOnRead(youLeftThem: leftOnReadYou, theyLeftYou: leftOnReadThem),
            responseTimes: ResponseTimes(
                youReply: summarizeResponseTimes(youReplyMinutes),
                theyReply: summarizeResponseTimes(themReplyMinutes)
            )
        )

        let dateFormatter = ISO8601DateFormatter()
        let report = Report(
            summary: summary,
            chats: chatReports,
            daily: daily,
            generatedAt: dateFormatter.string(from: Date()),
            filters: ReportFilters(
                since: since.map { dateFormatter.string(from: $0) },
                until: until.map { dateFormatter.string(from: $0) },
                thresholdHours: thresholdHours,
                top: top,
                dateScale: scaleLabel
            )
        )

        return report
    }

    private func nextOppositeTimes(_ messages: [Message]) -> [Int64?] {
        var nextFromMe: Int64?
        var nextFromThem: Int64?
        var nextTimes: [Int64?] = Array(repeating: nil, count: messages.count)

        for idx in stride(from: messages.count - 1, through: 0, by: -1) {
            let msg = messages[idx]
            if msg.isFromMe == 1 {
                nextTimes[idx] = nextFromThem
                if let date = msg.dateRaw { nextFromMe = date }
            } else {
                nextTimes[idx] = nextFromMe
                if let date = msg.dateRaw { nextFromThem = date }
            }
        }
        return nextTimes
    }

    private func summarizeResponseTimes(_ durations: [Double]) -> ResponseStats {
        guard !durations.isEmpty else {
            return ResponseStats(count: 0, avgMinutes: nil, medianMinutes: nil, p90Minutes: nil)
        }
        let absoluteCapMinutes = 7.0 * 24.0 * 60.0
        let capped = durations.filter { $0 <= absoluteCapMinutes }
        guard !capped.isEmpty else {
            return ResponseStats(count: 0, avgMinutes: nil, medianMinutes: nil, p90Minutes: nil)
        }
        let sorted = capped.sorted()
        let avg = sorted.reduce(0, +) / Double(sorted.count)
        let median: Double
        if sorted.count % 2 == 0 {
            let mid = sorted.count / 2
            median = (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        let p90Index = max(0, Int(round(0.9 * Double(sorted.count - 1))))
        let p95Index = max(0, Int(round(0.95 * Double(sorted.count - 1))))
        let p95Value = sorted[p95Index]
        let cap = min(p95Value, absoluteCapMinutes)
        let trimmed = sorted.filter { $0 <= cap }
        let trimmedAvg = trimmed.isEmpty ? avg : (trimmed.reduce(0, +) / Double(trimmed.count))

        return ResponseStats(
            count: sorted.count,
            avgMinutes: roundToTwo(trimmedAvg),
            medianMinutes: roundToTwo(median),
            p90Minutes: roundToTwo(sorted[p90Index])
        )
    }

    private func roundToTwo(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func writeReport(report: Report, outputFolder: URL) throws -> (htmlURL: URL, jsonURL: URL) {
        let htmlURL = outputFolder.appendingPathComponent("report.html")
        let jsonURL = outputFolder.appendingPathComponent("report.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: jsonURL, options: .atomic)

        let html = renderHTML(report: report)
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        return (htmlURL, jsonURL)
    }

    private func renderHTML(report: Report) -> String {
        let summary = report.summary

        let decimalFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = Locale.current.groupingSeparator
            return formatter
        }()

        func fmt(_ value: Double?) -> String {
            return humanizeMinutes(value)
        }
        func fmtInt(_ value: Int) -> String {
            return decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        func percent(_ value: Int, _ total: Int) -> Int {
            guard total > 0 else { return 0 }
            return Int(round((Double(value) / Double(total)) * 100))
        }
        func percentDouble(_ value: Double, _ maxValue: Double) -> Int {
            guard maxValue > 0 else { return 0 }
            return Int(round((value / maxValue) * 100))
        }
        func humanizeMinutes(_ value: Double?) -> String {
            guard let minutes = value else { return "—" }
            if minutes < 60 {
                let rounded = Int(minutes.rounded())
                return "\(rounded) min"
            }
            let hours = minutes / 60
            if hours < 24 {
                let rounded = hours.rounded()
                if abs(hours - rounded) < 0.05 {
                    let h = Int(rounded)
                    return "\(h) \(h == 1 ? "hr" : "hrs")"
                }
                return String(format: "%.1f hrs", hours)
            }
            let days = hours / 24
            let rounded = days.rounded()
            if abs(days - rounded) < 0.05 {
                let d = Int(rounded)
                return "\(d) \(d == 1 ? "day" : "days")"
            }
            return String(format: "%.1f days", days)
        }
        func polarPoint(cx: Double, cy: Double, radius: Double, angleDegrees: Double) -> (Double, Double) {
            let radians = angleDegrees * Double.pi / 180
            return (cx + radius * cos(radians), cy + radius * sin(radians))
        }
        func svgPie(segments: [(label: String, value: Int, color: String)], size: Int) -> String {
            let total = segments.reduce(0) { $0 + $1.value }
            if total == 0 {
                return "<div class=\\\"subtitle\\\">No data</div>"
            }
            let radius = Double(size) / 2.0
            let cx = radius
            let cy = radius
            var startAngle = -90.0
            var paths: [String] = []

            for seg in segments where seg.value > 0 {
                let angle = (Double(seg.value) / Double(total)) * 360.0
                let endAngle = startAngle + angle
                let largeArc = angle > 180.0 ? 1 : 0
                let (x1, y1) = polarPoint(cx: cx, cy: cy, radius: radius, angleDegrees: startAngle)
                let (x2, y2) = polarPoint(cx: cx, cy: cy, radius: radius, angleDegrees: endAngle)
                let d = "M \(cx) \(cy) L \(x1) \(y1) A \(radius) \(radius) 0 \(largeArc) 1 \(x2) \(y2) Z"
                paths.append("<path d=\"\(d)\" fill=\"\(seg.color)\" />")
                startAngle = endAngle
            }

            return "<svg width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 \(size) \(size)\">\(paths.joined())</svg>"
        }
        func svgTrendChart(daily: [DailyCount]) -> String {
            if daily.isEmpty {
                return "<div class=\\\"subtitle\\\">No data</div>"
            }
            let width = 720.0
            let height = 180.0
            let padding = 24.0
            let count = daily.count
            let maxTotal = max(daily.map { $0.total }.max() ?? 0, 1)
            let areaWidth = width - padding * 2
            let areaHeight = height - padding * 2
            let step = areaWidth / Double(max(count, 1))
            let barWidth = max(6.0, min(18.0, step * 0.7))

            var bars: [String] = []
            for i in 0..<count {
                let item = daily[i]
                let x = padding + step * Double(i) + (step - barWidth) / 2
                let totalHeight = (Double(item.total) / Double(maxTotal)) * areaHeight
                let sentHeight = (Double(item.sent) / Double(maxTotal)) * areaHeight
                let receivedHeight = (Double(item.received) / Double(maxTotal)) * areaHeight
                let yBase = padding + areaHeight
                let ySent = yBase - sentHeight
                let yReceived = ySent - receivedHeight

                let sentRect = "<rect x=\"\(x)\" y=\"\(ySent)\" width=\"\(barWidth)\" height=\"\(sentHeight)\" fill=\"var(--accent)\" rx=\"3\" />"
                let receivedRect = "<rect x=\"\(x)\" y=\"\(yReceived)\" width=\"\(barWidth)\" height=\"\(receivedHeight)\" fill=\"var(--accent-2)\" rx=\"3\" />"
                let outline = "<rect x=\"\(x)\" y=\"\(yBase - totalHeight)\" width=\"\(barWidth)\" height=\"\(totalHeight)\" fill=\"none\" stroke=\"rgba(255,255,255,0.04)\" />"
                bars.append(receivedRect + sentRect + outline)
            }

            let gridLines = [0.25, 0.5, 0.75].map { fraction -> String in
                let y = padding + areaHeight * (1.0 - fraction)
                return "<line class=\"trend-grid\" x1=\"\(padding)\" y1=\"\(y)\" x2=\"\(width - padding)\" y2=\"\(y)\" />"
            }.joined()

            let labelIndices = Array(Set([0, count / 2, max(count - 1, 0)])).sorted()
            let labels = labelIndices.map { idx -> String in
                guard daily.indices.contains(idx) else { return "" }
                let label = daily[idx].date
                let x = padding + step * Double(idx) + step / 2
                let y = height - 6
                return "<text class=\"trend-label\" x=\"\(x)\" y=\"\(y)\" text-anchor=\"middle\">\(escapeHTML(label))</text>"
            }.joined()

            return "<svg class=\"trend\" width=\"100%\" viewBox=\"0 0 \(Int(width)) \(Int(height))\">\(gridLines)\(bars.joined())\(labels)</svg>"
        }

        let sent = summary.totals.sent
        let received = summary.totals.received
        let total = max(summary.totals.total, 1)
        let youLeft = summary.leftOnRead.youLeftThem
        let theyLeft = summary.leftOnRead.theyLeftYou

        let sentPctOfTotal = percent(sent, total)
        let receivedPctOfTotal = 100 - sentPctOfTotal

        let leftTotal = max(youLeft + theyLeft, 1)
        let youLeftOverallPct = percent(youLeft, leftTotal)
        let theyLeftOverallPct = 100 - youLeftOverallPct

        let youAvg = summary.responseTimes.youReply.avgMinutes ?? 0
        let theyAvg = summary.responseTimes.theyReply.avgMinutes ?? 0
        let replyMax = max(youAvg, theyAvg, 1)
        let youAvgPct = percentDouble(youAvg, replyMax)
        let theyAvgPct = percentDouble(theyAvg, replyMax)

        let pieSentReceived = svgPie(
            segments: [
                ("Sent", sent, "var(--accent)"),
                ("Received", received, "var(--accent-2)")
            ],
            size: 160
        )
        let pieLeftOnRead = svgPie(
            segments: [
                ("You Left", youLeft, "var(--accent-3)"),
                ("They Left", theyLeft, "var(--accent-4)")
            ],
            size: 160
        )
        let trendChart = svgTrendChart(daily: report.daily)

        let chatCards = report.chats.map { chat in
            return """
            <div class=\"chat-card\">
              <div class=\"chat-header\">
                <h3>\(escapeHTML(chat.label))</h3>
                <span class=\"pill\">Total \(fmtInt(chat.totals.total))</span>
              </div>
              <div class=\"chat-grid\">
                <div class=\"mini\">
                  <div class=\"mini-label\">Sent</div>
                  <div class=\"mini-value\">\(fmtInt(chat.totals.sent))</div>
                </div>
                <div class=\"mini\">
                  <div class=\"mini-label\">Received</div>
                  <div class=\"mini-value\">\(fmtInt(chat.totals.received))</div>
                </div>
                <div class=\"mini\">
                  <div class=\"mini-label\">You left</div>
                  <div class=\"mini-value\">\(fmtInt(chat.leftOnRead.youLeftThem))</div>
                </div>
                <div class=\"mini\">
                  <div class=\"mini-label\">They left</div>
                  <div class=\"mini-value\">\(fmtInt(chat.leftOnRead.theyLeftYou))</div>
                </div>
              </div>
            <div class=\"chat-footer\">
                <span>Your avg reply (trimmed): \(fmt(chat.responseTimes.youReply.avgMinutes))</span>
                <span>Their avg reply (trimmed): \(fmt(chat.responseTimes.theyReply.avgMinutes))</span>
              </div>
            </div>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang=\"en\">
        <head>
        <meta charset=\"utf-8\" />
        <title>iMessages Stats Report</title>
        <style>
        :root {
          --bg: #0b0e14;
          --bg-2: #121522;
          --card: #141926;
          --card-2: #0f1320;
          --text: #e9ecf5;
          --muted: #9aa4b2;
          --accent: #6ea8ff;
          --accent-2: #57e3c6;
          --accent-3: #ffb44c;
          --accent-4: #ff7ab6;
        }
        * { box-sizing: border-box; }
        body {
          font-family: \"SF Pro Display\", -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
          margin: 0;
          color: var(--text);
          background: radial-gradient(circle at 12% 12%, #1b2236 0%, transparent 38%),
                      radial-gradient(circle at 80% 10%, #1e1930 0%, transparent 32%),
                      linear-gradient(135deg, var(--bg), var(--bg-2));
        }
        .container { max-width: 1200px; margin: 0 auto; padding: 32px; }
        header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; }
        h1 { margin: 0; font-size: 28px; letter-spacing: 0.2px; }
        .subtitle { color: var(--muted); font-size: 13px; }
        .pill { background: rgba(255,255,255,0.08); padding: 6px 10px; border-radius: 999px; font-size: 12px; color: var(--muted); }
        .grid-2 { display: grid; grid-template-columns: 2fr 1fr; gap: 16px; }
        .grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
        .card {
          background: var(--card);
          border: 1px solid rgba(255,255,255,0.06);
          border-radius: 16px;
          padding: 16px;
          box-shadow: 0 20px 40px rgba(0,0,0,0.35);
        }
        .kpi {
          background: linear-gradient(135deg, rgba(110,168,255,0.12), rgba(87,227,198,0.08));
          border-radius: 14px;
          padding: 12px;
          border: 1px solid rgba(255,255,255,0.06);
        }
        .kpi .label { color: var(--muted); font-size: 12px; }
        .kpi .value { font-size: 22px; font-weight: 700; }
        .chart-title { font-size: 13px; color: var(--muted); margin-bottom: 10px; }
        .bar-track { height: 10px; background: rgba(255,255,255,0.08); border-radius: 999px; overflow: hidden; }
        .bar-fill { height: 100%; border-radius: 999px; }
        .bar-item { display: grid; grid-template-columns: 80px 1fr 60px; align-items: center; gap: 12px; margin-bottom: 10px; }
        .bar-item:last-child { margin-bottom: 0; }
        .pie-wrap { display: flex; flex-direction: column; align-items: center; gap: 10px; }
        .pie-legend { display: flex; justify-content: center; gap: 12px; font-size: 12px; color: var(--muted); }
        .legend-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
        .trend { margin-top: 6px; }
        .trend-legend { display: flex; gap: 16px; font-size: 12px; color: var(--muted); margin-top: 8px; }
        .trend-label { fill: var(--muted); font-size: 10px; }
        .trend-grid { stroke: rgba(255,255,255,0.08); stroke-width: 1; }
        .chat-card {
          background: var(--card-2);
          border-radius: 14px;
          padding: 14px;
          border: 1px solid rgba(255,255,255,0.05);
          margin-bottom: 12px;
        }
        .chat-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
        .chat-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 8px; }
        .mini { background: rgba(255,255,255,0.04); padding: 8px; border-radius: 10px; }
        .mini-label { color: var(--muted); font-size: 11px; margin-bottom: 4px; }
        .mini-value { font-size: 16px; font-weight: 600; }
        .chat-footer { display: flex; justify-content: space-between; color: var(--muted); font-size: 12px; }
        .section-title { font-size: 16px; margin: 0 0 12px 0; }
        .footer { color: var(--muted); font-size: 11px; margin-top: 18px; }
        </style>
        </head>
        <body>
        <div class=\"container\">
          <header>
            <div>
              <h1>iMessages Stats Report</h1>
              <div class=\"subtitle\">Generated locally · \(escapeHTML(report.generatedAt))</div>
            </div>
            <span class=\"pill\">Local Only</span>
          </header>

          <section class=\"card\">
            <h2 class=\"section-title\">Overview</h2>
            <div class=\"grid-3\">
              <div class=\"kpi\"><div class=\"label\">Sent</div><div class=\"value\">\(fmtInt(sent))</div></div>
              <div class=\"kpi\"><div class=\"label\">Received</div><div class=\"value\">\(fmtInt(received))</div></div>
              <div class=\"kpi\"><div class=\"label\">Total</div><div class=\"value\">\(fmtInt(summary.totals.total))</div></div>
              <div class=\"kpi\"><div class=\"label\">You left them</div><div class=\"value\">\(fmtInt(youLeft))</div></div>
              <div class=\"kpi\"><div class=\"label\">They left you</div><div class=\"value\">\(fmtInt(theyLeft))</div></div>
              <div class=\"kpi\"><div class=\"label\">Your avg reply</div><div class=\"value\">\(fmt(summary.responseTimes.youReply.avgMinutes))</div></div>
            </div>
          </section>

          <section class=\"grid-2\" style=\"margin-top:16px;\">
            <div class=\"card\">
              <h2 class=\"section-title\">Message Mix</h2>
              <div class=\"pie-wrap\">
                \(pieSentReceived)
                <div class=\"pie-legend\">
                  <span><span class=\"legend-dot\" style=\"background: var(--accent);\"></span>Sent \(sentPctOfTotal)%</span>
                  <span><span class=\"legend-dot\" style=\"background: var(--accent-2);\"></span>Received \(receivedPctOfTotal)%</span>
                </div>
              </div>
            </div>
            <div class=\"card\">
              <h2 class=\"section-title\">Left on Read</h2>
              <div class=\"pie-wrap\">
                \(pieLeftOnRead)
                <div class=\"pie-legend\">
                  <span><span class=\"legend-dot\" style=\"background: var(--accent-3);\"></span>You left \(youLeftOverallPct)%</span>
                  <span><span class=\"legend-dot\" style=\"background: var(--accent-4);\"></span>They left \(theyLeftOverallPct)%</span>
                </div>
              </div>
            </div>
          </section>

          <section class=\"card\" style=\"margin-top:16px;\">
            <h2 class=\"section-title\">Average Reply Time (trimmed)</h2>
            <div class=\"bar-item\">
              <div class=\"chart-title\">You</div>
              <div class=\"bar-track\"><div class=\"bar-fill\" style=\"width: \(youAvgPct)%; background: var(--accent);\"></div></div>
              <div>\(fmt(summary.responseTimes.youReply.avgMinutes))</div>
            </div>
            <div class=\"bar-item\">
              <div class=\"chart-title\">Them</div>
              <div class=\"bar-track\"><div class=\"bar-fill\" style=\"width: \(theyAvgPct)%; background: var(--accent-2);\"></div></div>
              <div>\(fmt(summary.responseTimes.theyReply.avgMinutes))</div>
            </div>
          </section>

          <section class=\"card\" style=\"margin-top:16px;\">
            <h2 class=\"section-title\">Trends (Last 30 days)</h2>
            \(trendChart)
            <div class=\"trend-legend\">
              <span><span class=\"legend-dot\" style=\"background: var(--accent);\"></span>Sent</span>
              <span><span class=\"legend-dot\" style=\"background: var(--accent-2);\"></span>Received</span>
            </div>
          </section>

          <section style=\"margin-top:16px;\">
            <h2 class=\"section-title\">Top Chats</h2>
            \(chatCards)
          </section>

          <div class=\"footer\">Filters: since=\(escapeHTML(report.filters.since ?? "—")) · until=\(escapeHTML(report.filters.until ?? "—")) · threshold=\(report.filters.thresholdHours)h · left-on-read cap=7d</div>
        </div>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
