import Foundation

enum AccountPlan: String, Codable, CaseIterable, Identifiable {
    case free
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .pro: return "Pro"
        }
    }
}

struct Totals: Codable {
    let sent: Int
    let received: Int
    let total: Int

    enum CodingKeys: String, CodingKey {
        case sent
        case received
        case total
    }
}

struct LeftOnRead: Codable {
    let youLeftThem: Int
    let theyLeftYou: Int

    enum CodingKeys: String, CodingKey {
        case youLeftThem = "you_left_them"
        case theyLeftYou = "they_left_you"
    }
}

struct ResponseStats: Codable {
    let count: Int
    let avgMinutes: Double?
    let medianMinutes: Double?
    let p90Minutes: Double?

    enum CodingKeys: String, CodingKey {
        case count
        case avgMinutes = "avg_minutes"
        case medianMinutes = "median_minutes"
        case p90Minutes = "p90_minutes"
    }
}

struct ResponseTimes: Codable {
    let youReply: ResponseStats
    let theyReply: ResponseStats

    enum CodingKeys: String, CodingKey {
        case youReply = "you_reply"
        case theyReply = "they_reply"
    }
}

struct ConversationLine: Codable, Identifiable {
    let id: String
    let sender: String
    let text: String
}

struct ReplyBucketStats: Codable {
    let under5m: Int
    let under1h: Int
    let under6h: Int
    let under24h: Int
    let under7d: Int
    let over7d: Int

    enum CodingKeys: String, CodingKey {
        case under5m = "under_5m"
        case under1h = "under_1h"
        case under6h = "under_6h"
        case under24h = "under_24h"
        case under7d = "under_7d"
        case over7d = "over_7d"
    }
}

struct ReplySpeedBuckets: Codable {
    let you: ReplyBucketStats
    let them: ReplyBucketStats

    enum CodingKeys: String, CodingKey {
        case you
        case them
    }
}

struct MoodSummary: Codable {
    let friendly: Int
    let romantic: Int
    let professional: Int
    let neutral: Int
}

struct WeekdayBin: Codable, Identifiable {
    let id: Int
    let weekday: Int
    let total: Int
    let you: Int
    let them: Int
}

struct MoodDaily: Codable, Identifiable {
    let id: String
    let date: String
    let friendly: Int
    let romantic: Int
    let professional: Int
    let neutral: Int
}

struct GreetingStats: Codable {
    let youMorning: Int
    let themMorning: Int
    let youNight: Int
    let themNight: Int

    enum CodingKeys: String, CodingKey {
        case youMorning = "you_morning"
        case themMorning = "them_morning"
        case youNight = "you_night"
        case themNight = "them_night"
    }
}

struct ParticipantReplyStat: Codable, Identifiable {
    let id: String
    let label: String
    let avgMinutes: Double?
}

struct PhraseStat: Codable, Identifiable {
    let id: String
    let phrase: String
    let count: Int
}

struct PhraseMoodStat: Codable, Identifiable {
    let id: String
    let phrase: String
    let mood: String
    let youCount: Int
    let themCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case phrase
        case mood
        case youCount = "you_count"
        case themCount = "them_count"
    }
}

struct StreakStats: Codable {
    let currentDays: Int
    let longestDays: Int
    let longestSilenceDays: Int

    enum CodingKeys: String, CodingKey {
        case currentDays = "current_days"
        case longestDays = "longest_days"
        case longestSilenceDays = "longest_silence_days"
    }
}

struct InitiatorStats: Codable {
    let youStarted: Int
    let themStarted: Int

    enum CodingKeys: String, CodingKey {
        case youStarted = "you_started"
        case themStarted = "them_started"
    }
}

struct ConversationPeak: Codable {
    let date: String?
    let total: Int
    let longestBackAndForth: Int

    enum CodingKeys: String, CodingKey {
        case date
        case total
        case longestBackAndForth = "longest_back_and_forth"
    }
}

struct ReengagementStats: Codable {
    let youAvgGapHours: Double?
    let themAvgGapHours: Double?
    let youCount: Int
    let themCount: Int

    enum CodingKeys: String, CodingKey {
        case youAvgGapHours = "you_avg_gap_hours"
        case themAvgGapHours = "them_avg_gap_hours"
        case youCount = "you_count"
        case themCount = "them_count"
    }
}

struct TimeOfDayBin: Codable, Identifiable {
    let id: Int
    let hour: Int
    let total: Int
    let you: Int
    let them: Int

    enum CodingKeys: String, CodingKey {
        case id
        case hour
        case total
        case you
        case them
    }
}

struct RecentBalance: Codable {
    let last30: Int
    let last90: Int
    let total: Int
    let last30Pct: Double
    let last90Pct: Double

    enum CodingKeys: String, CodingKey {
        case last30 = "last_30"
        case last90 = "last_90"
        case total
        case last30Pct = "last_30_pct"
        case last90Pct = "last_90_pct"
    }
}

struct AttachmentStats: Codable {
    let you: Int
    let them: Int
    let total: Int
}

struct EmojiStat: Codable, Identifiable {
    let id: String
    let emoji: String
    let count: Int
}

struct ReactionStat: Codable, Identifiable {
    let id: String
    let reaction: String
    let count: Int
}

struct ParticipantStat: Codable, Identifiable {
    let id: String
    let label: String
    let count: Int
}

struct WordStat: Codable, Identifiable {
    let id: String
    let word: String
    let count: Int
}

// MARK: - Cloud Contacts (Admin / Mutual Contacts)

struct UserContactPoint: Codable, Identifiable {
    let id: String
    let ownerUserId: String
    let contactName: String
    let handle: String
    let handleType: String
    let handleNormalized: String
    let handleHash: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserId = "owner_user_id"
        case contactName = "contact_name"
        case handle
        case handleType = "handle_type"
        case handleNormalized = "handle_normalized"
        case handleHash = "handle_hash"
        case createdAt = "created_at"
    }

    init(
        id: String,
        ownerUserId: String,
        contactName: String,
        handle: String,
        handleType: String,
        handleNormalized: String,
        handleHash: String,
        createdAt: String?
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.contactName = contactName
        self.handle = handle
        self.handleType = handleType
        self.handleNormalized = handleNormalized
        self.handleHash = handleHash
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        ownerUserId = (try? c.decodeIfPresent(String.self, forKey: .ownerUserId)) ?? ""
        contactName = (try? c.decodeIfPresent(String.self, forKey: .contactName)) ?? ""
        handle = (try? c.decodeIfPresent(String.self, forKey: .handle)) ?? ""
        handleType = (try? c.decodeIfPresent(String.self, forKey: .handleType)) ?? ""
        handleNormalized = (try? c.decodeIfPresent(String.self, forKey: .handleNormalized)) ?? ""
        handleHash = (try? c.decodeIfPresent(String.self, forKey: .handleHash)) ?? ""
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct ChatReport: Codable, Identifiable {
    let id: Int64
    let chatIdentifier: String
    let displayName: String?
    let label: String
    let contactHandles: [String]
    let contactKey: String?
    let groupPhotoPath: String?
    let totals: Totals
    let leftOnRead: LeftOnRead
    let responseTimes: ResponseTimes
    let lastMessageDate: String?
    let firstMessageText: String?
    let firstMessageDate: String?
    let firstMessageFromMe: Bool?
    let energyScore: Int
    let streaks: StreakStats
    let initiators: InitiatorStats
    let peak: ConversationPeak
    let reengagement: ReengagementStats
    let timeOfDay: [TimeOfDayBin]
    let recentBalance: RecentBalance
    let attachments: AttachmentStats
    let topEmojis: [EmojiStat]
    let topEmojisYou: [EmojiStat]
    let topEmojisThem: [EmojiStat]
    let reactions: [ReactionStat]
    let replyBuckets: ReplySpeedBuckets
    let moodSummary: MoodSummary
    let moodTimeline: [MoodDaily]
    let greetings: GreetingStats
    let firstConversation: [ConversationLine]
    let participantReplySpeeds: [ParticipantReplyStat]
    let weekdayActivity: [WeekdayBin]
    let topPhrases: [PhraseStat]
    let phraseMoods: [PhraseMoodStat]
    let participantCount: Int
    let isGroup: Bool
    let participants: [ParticipantStat]
    let topWords: [WordStat]
    let topWordsYou: [WordStat]
    let topWordsThem: [WordStat]

    enum CodingKeys: String, CodingKey {
        case id = "chat_id"
        case chatIdentifier = "chat_identifier"
        case displayName = "display_name"
        case label
        case contactHandles = "contact_handles"
        case contactKey = "contact_key"
        case groupPhotoPath = "group_photo_path"
        case totals
        case leftOnRead = "left_on_read"
        case responseTimes = "response_times"
        case lastMessageDate = "last_message_date"
        case firstMessageText = "first_message_text"
        case firstMessageDate = "first_message_date"
        case firstMessageFromMe = "first_message_from_me"
        case energyScore = "energy_score"
        case streaks
        case initiators
        case peak
        case reengagement
        case timeOfDay = "time_of_day"
        case recentBalance = "recent_balance"
        case attachments
        case topEmojis = "top_emojis"
        case topEmojisYou = "top_emojis_you"
        case topEmojisThem = "top_emojis_them"
        case reactions
        case replyBuckets = "reply_buckets"
        case moodSummary = "mood_summary"
        case moodTimeline = "mood_timeline"
        case greetings
        case firstConversation = "first_conversation"
        case participantReplySpeeds = "participant_reply_speeds"
        case weekdayActivity = "weekday_activity"
        case topPhrases = "top_phrases"
        case phraseMoods = "phrase_moods"
        case participantCount = "participant_count"
        case isGroup = "is_group"
        case participants
        case topWords = "top_words"
        case topWordsYou = "top_words_you"
        case topWordsThem = "top_words_them"
    }
}

struct Summary: Codable {
    let totals: Totals
    let leftOnRead: LeftOnRead
    let responseTimes: ResponseTimes

    enum CodingKeys: String, CodingKey {
        case totals
        case leftOnRead = "left_on_read"
        case responseTimes = "response_times"
    }
}

struct ReportFilters: Codable {
    let since: String?
    let until: String?
    let thresholdHours: Double
    let top: Int
    let dateScale: String

    enum CodingKeys: String, CodingKey {
        case since
        case until
        case thresholdHours = "threshold_hours"
        case top
        case dateScale = "date_scale"
    }
}

struct DailyCount: Codable, Identifiable {
    let id: String
    let date: String
    let sent: Int
    let received: Int
    let total: Int
}

struct Report: Codable {
    let summary: Summary
    let chats: [ChatReport]
    let daily: [DailyCount]
    let generatedAt: String
    let filters: ReportFilters

    enum CodingKeys: String, CodingKey {
        case summary
        case chats
        case daily
        case generatedAt = "generated_at"
        case filters
    }
}

struct ReportOutput {
    let report: Report
    let htmlURL: URL
    let jsonURL: URL
}
