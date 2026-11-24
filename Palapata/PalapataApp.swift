import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications
import zlib

@main
struct PalapataApp: App {
    @UIApplicationDelegateAdaptor(ReviewNotificationAppDelegate.self) private var notificationDelegate
    var body: some Scene {
        WindowGroup {
            TodayScreen()
        }
    }
}

private enum Style {
    static func heading(_ size: CGFloat) -> Font { .custom("DMSans-Black", size: size) }

    static let background = Color(red: 1.00, green: 0.984, blue: 0.956)
    static let ink = Color(red: 0.105, green: 0.224, blue: 0.251)
    static let teal = Color(red: 0.090, green: 0.427, blue: 0.439)
    static let coral = Color(red: 1.00, green: 0.522, blue: 0.420)
    static let yellow = Color(red: 0.972, green: 0.918, blue: 0.492)
    static let paleYellow = Color(red: 1.00, green: 0.946, blue: 0.813)
    static let lavender = Color(red: 0.902, green: 0.897, blue: 0.963)
    static let peach = Color(red: 1.00, green: 0.887, blue: 0.819)
    static let mint = Color(red: 0.886, green: 0.932, blue: 0.905)
    static let quiet = Color(red: 0.38, green: 0.44, blue: 0.43)
    static let ghost = Color(red: 0.36, green: 0.43, blue: 0.46)
    static let purpleInk = Color(red: 0.32, green: 0.27, blue: 0.43)
}

private func wordCountLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "word" : "words")" }

private enum AppTab: CaseIterable {
    case today, library, collections, settings
}

private enum LearningStatus: String, Codable {
    case new, learning, reviewing, mastered
}

private enum LearningCategory {
    static let unsortedID = "palapata.learning.unsorted"
}

private struct VocabularyHeadword: Codable, Identifiable {
    var id = UUID()
    var spelling: String
    var pronunciation = ""
    var audioFile: String? = nil
    var createdAt = Date()
}

private struct LexicalEntry: Codable, Identifiable {
    var id = UUID()
    var headwordID: UUID
    var homonymNumber: Int
}

private enum ReviewScheduler {
    static let successIntervals: [TimeInterval] = [10 * 3600, 86400, 3 * 86400, 7 * 86400,
                                                   14 * 86400, 30 * 86400, 60 * 86400, 120 * 86400]
    static let missedInterval: TimeInterval = 10 * 60

    static func interval(for consecutiveCorrect: Int, recentMisses: Int, sessionMisses: Int) -> TimeInterval {
        let stage = max(1, consecutiveCorrect)
        var interval = successIntervals[min(stage - 1, successIntervals.count - 1)]
        if stage > successIntervals.count {
            for _ in successIntervals.count..<stage { interval = min(interval * 2, 365 * 86400) }
        }
        interval *= recentMisses >= 2 ? 0.5 : recentMisses == 1 ? 0.75 : 1
        if sessionMisses > 0 { interval = min(interval, sessionMisses >= 2 ? 4 * 3600 : 10 * 3600) }
        return interval
    }

    static func nextInterval(after previous: TimeInterval) -> TimeInterval {
        successIntervals.first { $0 > previous } ?? min(previous * 2, 365 * 86400)
    }

    static func legacyStreak(intervalDays: Int, reviewCount: Int) -> Int {
        guard reviewCount > 0 else { return 0 }
        if intervalDays == 0 { return 1 }
        let stage = successIntervals.firstIndex { $0 >= TimeInterval(intervalDays) * 86400 }
        return (stage ?? successIntervals.count - 1) + 1
    }
}

private struct WordRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var word: String
    var meaning: String
    var headwordID: UUID? = nil
    var lexicalEntryID: UUID? = nil
    var homonymNumber: Int? = nil
    var senseNumber: Int? = nil
    var partOfSpeech: String? = nil
    var legacyUnmapped: Bool? = nil
    var pronunciation = ""
    var example = ""
    var translation = ""
    var additionalExamples: [SentenceExample]? = nil
    var collectionIDs: [String] = []
    var audioFile: String? = nil
    var createdAt = Date()
    var lastReviewed: Date? = nil
    var nextReview: Date? = nil
    var intervalDays = 0
    var reviewCount = 0
    var currentReviewInterval: TimeInterval? = nil
    var consecutiveCorrectReviews: Int? = nil
    var totalMisses: Int? = nil
    var recentMisses: Int? = nil
    var lastSessionAttempts: Int? = nil
    var lastSessionMisses: Int? = nil
    var firstAttemptCorrect: Bool? = nil
    var learningStatus: LearningStatus? = .new
    var learningStartedAt: Date? = nil

    var status: LearningStatus { learningStatus ?? .new }
    var homonym: Int { homonymNumber ?? 1 }
    var sense: Int { senseNumber ?? 1 }
    func isDue(asOf date: Date) -> Bool { status != .new && nextReview.map { $0 <= date } == true }
    var isDue: Bool { isDue(asOf: Date()) }
    var isRecent: Bool { lastReviewed.map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false }
    func isEligibleForNewLearning(in selected: Set<String>) -> Bool {
        status == .new && (collectionIDs.isEmpty
            ? selected.contains(LearningCategory.unsortedID)
            : collectionIDs.contains(where: selected.contains))
    }
    mutating func beginLearning(alreadyKnown: Bool, misses: Int = 0, at date: Date) {
        learningStatus = alreadyKnown ? .reviewing : .learning
        learningStartedAt = date
        lastReviewed = nil
        reviewCount = 0
        intervalDays = alreadyKnown ? (misses == 0 ? 7 : 1) : 0
        let firstInterval: TimeInterval = alreadyKnown ? (misses == 0 ? 7 * 86400 : 86400) : (misses == 0 ? 10 * 60 : 5 * 60)
        currentReviewInterval = firstInterval
        consecutiveCorrectReviews = 0
        totalMisses = misses
        recentMisses = min(misses, 4)
        lastSessionAttempts = misses + 1
        lastSessionMisses = misses
        firstAttemptCorrect = misses == 0
        nextReview = date.addingTimeInterval(firstInterval)
    }
}

private enum VocabularyHierarchy {
    static func spellingKey(_ spelling: String) -> String { ExcelImportLogic.key(spelling) }
    static func senseKey(_ spelling: String, homonym: Int, sense: Int) -> String {
        "\(spellingKey(spelling))|\(homonym)|\(sense)"
    }
    static func safelyMatchesLegacy(_ existing: String, _ imported: String) -> Bool {
        let old = ExcelImportLogic.key(existing)
        let new = ExcelImportLogic.key(imported)
        return !old.isEmpty && old == new
    }

    static func migrate(words source: [WordRecord], headwords sourceHeadwords: [VocabularyHeadword],
                        entries sourceEntries: [LexicalEntry]) -> (words: [WordRecord], headwords: [VocabularyHeadword], entries: [LexicalEntry]) {
        var words = source
        var headwords = sourceHeadwords
        var entries = sourceEntries
        var headwordIndex: [String: Int] = [:]
        for index in headwords.indices where headwordIndex[spellingKey(headwords[index].spelling)] == nil {
            headwordIndex[spellingKey(headwords[index].spelling)] = index
        }
        var entryIndex: [String: Int] = [:]
        for index in entries.indices {
            entryIndex["\(entries[index].headwordID)|\(entries[index].homonymNumber)"] = index
        }
        var usedSenses: [UUID: Set<Int>] = [:]
        for index in words.indices {
            if words[index].headwordID == nil { words[index].legacyUnmapped = words[index].legacyUnmapped ?? true }
            let spelling = words[index].word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = spellingKey(spelling)
            guard !key.isEmpty else { continue }
            let headIndex: Int
            if let existing = headwordIndex[key] { headIndex = existing }
            else {
                headwords.append(VocabularyHeadword(spelling: spelling, pronunciation: words[index].pronunciation,
                                                    audioFile: words[index].audioFile, createdAt: words[index].createdAt))
                headIndex = headwords.count - 1
                headwordIndex[key] = headIndex
            }
            let headID = headwords[headIndex].id
            if headwords[headIndex].pronunciation.isEmpty && !words[index].pronunciation.isEmpty {
                headwords[headIndex].pronunciation = words[index].pronunciation
            }
            if headwords[headIndex].audioFile == nil { headwords[headIndex].audioFile = words[index].audioFile }
            let homonym = words[index].legacyUnmapped == true ? max(0, words[index].homonym) : max(1, words[index].homonym)
            let entryKey = "\(headID)|\(homonym)"
            let lexicalIndex: Int
            if let existing = entryIndex[entryKey] { lexicalIndex = existing }
            else {
                entries.append(LexicalEntry(headwordID: headID, homonymNumber: homonym))
                lexicalIndex = entries.count - 1
                entryIndex[entryKey] = lexicalIndex
            }
            let entryID = entries[lexicalIndex].id
            var sense = words[index].legacyUnmapped == true ? max(0, words[index].sense) : max(1, words[index].sense)
            while usedSenses[entryID, default: []].contains(sense) { sense += 1 }
            usedSenses[entryID, default: []].insert(sense)
            words[index].headwordID = headID
            words[index].lexicalEntryID = entryID
            words[index].homonymNumber = homonym
            words[index].senseNumber = sense
            words[index].word = headwords[headIndex].spelling
            if words[index].pronunciation.isEmpty { words[index].pronunciation = headwords[headIndex].pronunciation }
            if words[index].audioFile == nil { words[index].audioFile = headwords[headIndex].audioFile }
        }
        return (words, headwords, entries)
    }
}

private enum LearnSessionPhase: String, Codable { case overview, introduction, practice, complete }

private struct LearnSessionProgress: Codable {
    var batchIDs: [UUID]
    var phase: LearnSessionPhase
    var introductionIndex: Int
    var introductionChoices: [UUID: Bool]
    var postponedIDs: Set<UUID>
    var practiceQueue: [UUID]
    var completedIDs: Set<UUID>
    var attempts: [UUID: Int]
    var misses: [UUID: Int]
    var isRevealed: Bool
    var allowBeyondGoal: Bool

    var currentID: UUID? {
        switch phase {
        case .introduction: batchIDs.indices.contains(introductionIndex) ? batchIDs[introductionIndex] : nil
        case .practice: practiceQueue.first
        case .overview, .complete: nil
        }
    }
    var remainingCount: Int {
        switch phase {
        case .introduction: max(0, batchIDs.count - introductionIndex)
        case .practice: practiceQueue.count
        case .overview, .complete: 0
        }
    }
}

private struct SentenceExample: Codable, Equatable, Identifiable {
    var id = UUID()
    var sentenceID: UUID?
    var kweyol: String
    var english: String
}

private struct SentenceRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var kweyol: String
    var english: String
    var pronunciation = ""
    var notes = ""
    var collectionIDs: [String] = []
    var audioFile: String? = nil
    var createdAt = Date()
}

private struct SavedCollection: Codable, Identifiable {
    var id = UUID().uuidString
    var title: String
    var description: String
    var icon: String
    var colorIndex: Int
}

private struct AppPreferences: Codable {
    var autoplay = true
    var showHint = true
    var sessionSize = 20
    var newWordsPerDay = 10
    var selectedLearningCategoryIDs: [String]? = nil
    var reviewNotificationsEnabled = false

    init() {}
    private enum CodingKeys: String, CodingKey { case autoplay, showHint, sessionSize, newWordsPerDay, selectedLearningCategoryIDs, reviewNotificationsEnabled }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoplay = try values.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        showHint = try values.decodeIfPresent(Bool.self, forKey: .showHint) ?? true
        sessionSize = try values.decodeIfPresent(Int.self, forKey: .sessionSize) ?? 20
        newWordsPerDay = try values.decodeIfPresent(Int.self, forKey: .newWordsPerDay) ?? 10
        selectedLearningCategoryIDs = try values.decodeIfPresent([String].self, forKey: .selectedLearningCategoryIDs)
        reviewNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .reviewNotificationsEnabled) ?? false
    }
}

private enum ReviewNotificationRouting {
    static let prefix = "palapata.review."
    static let overdueID = prefix + "overdue"
    static let pendingOpenKey = "palapata.openDueReview"
    static let lastOverdueScheduledKey = "palapata.lastOverdueReminder"
    static let openDueReview = Notification.Name("palapata.openDueReview")
}

private final class ReviewNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(ReviewNotificationRouting.prefix) ? [.banner, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix(ReviewNotificationRouting.prefix) {
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: ReviewNotificationRouting.pendingOpenKey)
                NotificationCenter.default.post(name: ReviewNotificationRouting.openDueReview, object: nil)
            }
        }
        completionHandler()
    }
}

private enum ReviewReminderCopy {
    struct Message { let title: String; let body: String }

    static func message(for due: [WordRecord], variation: Int) -> Message {
        let words = Array(due.prefix(2)).map(\.word)
        guard let first = words.first else { return Message(title: "It's time to review", body: "Your Kwéyòl words are ready.") }
        let list: String
        if due.count == 1 { list = first }
        else if due.count == 2 { list = "\(first) and \(words[1])" }
        else { list = "\(first), \(words[1]), and \(due.count - 2) other \(due.count - 2 == 1 ? "word" : "words")" }
        switch variation % 5 {
        case 0: return Message(title: "It's time to review", body: "Start with \(list).")
        case 1:
            let rest = due.count - 1
            return Message(title: "Quick Kwéyòl check", body: "Do you remember what “\(first)” means?\(rest > 0 ? " \(rest) more \(rest == 1 ? "word is" : "words are") due." : "")")
        case 2: return Message(title: "People could be talking about you in Kwéyòl 👀", body: "Review \(list) and stay in the conversation.")
        case 3: return Message(title: "Annou alé! 🇱🇨", body: "Time to review \(list).")
        default: return Message(title: "A little Kwéyòl catch-up", body: "Ready for a quick review? Start with \(list).")
        }
    }
}

@MainActor private enum ReviewNotificationScheduler {
    static func sync(words: [WordRecord], enabled: Bool) async -> String? {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let owned = pending.filter { $0.identifier.hasPrefix(ReviewNotificationRouting.prefix) }
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            return nil
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else {
            center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier))
            return nil
        }
        let now = Date()
        let currentlyDue = words.filter { $0.isDue(asOf: now) }
        let pendingOverdue = owned.first { $0.identifier == ReviewNotificationRouting.overdueID }
        let hasPendingOverdue = !currentlyDue.isEmpty && pendingOverdue != nil
        center.removePendingNotificationRequests(withIdentifiers: owned.map(\.identifier).filter { !hasPendingOverdue || $0 != ReviewNotificationRouting.overdueID })
        if hasPendingOverdue, let pendingOverdue {
            let fireDate = (pendingOverdue.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() ?? now.addingTimeInterval(60)
            let due = sortedDue(words, asOf: fireDate)
            let copy = ReviewReminderCopy.message(for: due, variation: variation(for: fireDate, index: 0))
            if pendingOverdue.content.title != copy.title || pendingOverdue.content.body != copy.body {
                if let error = await addReminder(center: center, id: ReviewNotificationRouting.overdueID, at: fireDate, due: due, variation: variation(for: fireDate, index: 0)) { return error }
            }
        }
        if !currentlyDue.isEmpty && !hasPendingOverdue {
            let last = UserDefaults.standard.object(forKey: ReviewNotificationRouting.lastOverdueScheduledKey) as? Date
            if last == nil || now.timeIntervalSince(last!) >= 12 * 3600 {
                let fireDate = now.addingTimeInterval(60)
                let due = sortedDue(words, asOf: fireDate)
                if let error = await addReminder(center: center, id: ReviewNotificationRouting.overdueID, at: fireDate, due: due, variation: variation(for: fireDate, index: 0)) { return error }
                UserDefaults.standard.set(now, forKey: ReviewNotificationRouting.lastOverdueScheduledKey)
            }
        }
        var dates: [Date] = []
        var bucketStart: Date?
        for date in words.filter({ $0.status != .new }).compactMap(\.nextReview).filter({ $0 > now }).sorted() {
            if let bucketStart, date.timeIntervalSince(bucketStart) < 30 * 60 { dates[dates.count - 1] = date }
            else { dates.append(date); bucketStart = date }
            if dates.count >= 32 { break }
        }
        for (index, date) in dates.enumerated() {
            let due = sortedDue(words, asOf: date)
            let id = ReviewNotificationRouting.prefix + String(Int(date.timeIntervalSince1970))
            if let error = await addReminder(center: center, id: id, at: date, due: due, variation: variation(for: date, index: index + 1)) { return error }
        }
        return nil
    }

    private static func sortedDue(_ words: [WordRecord], asOf date: Date) -> [WordRecord] {
        words.filter { $0.isDue(asOf: date) }.sorted {
            if $0.nextReview != $1.nextReview { return ($0.nextReview ?? .distantPast) > ($1.nextReview ?? .distantPast) }
            return $0.word.localizedStandardCompare($1.word) == .orderedAscending
        }
    }
    private static func variation(for date: Date, index: Int) -> Int {
        (Int(date.timeIntervalSince1970 / 3600) + index) % 5
    }
    private static func addReminder(center: UNUserNotificationCenter, id: String, at date: Date, due: [WordRecord], variation: Int) async -> String? {
        guard !due.isEmpty else { return nil }
        let copy = ReviewReminderCopy.message(for: due, variation: variation)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.threadIdentifier = "palapata.reviews"
        content.userInfo = ["destination": "dueReview"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return nil
        } catch {
            return "A review reminder could not be scheduled: \(error.localizedDescription)"
        }
    }
}

private enum RecallRating: String, Codable, CaseIterable { case gotIt = "Got It", missedIt = "Missed It" }

private struct SessionResult {
    var ratings: [RecallRating] = []
    var completedWords = 0
    var collectionCount = 0
    var featuredWord = ""
    var wordsWithMultipleAttempts = 0
    var date = Date()
    func count(_ rating: RecallRating) -> Int { ratings.filter { $0 == rating }.count }
}

@MainActor private final class VocabularyStore: ObservableObject {
    private var player: AVAudioPlayer?
    private var dueTimer: Timer?
    private var isApplyingImport = false
    private var notificationSyncPending = false
    private var notificationSyncInProgress = false
    private var notificationRequestGeneration = 0
    private let saveQueue = DispatchQueue(label: "palapata.persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    @Published var playbackError: String?
    @Published var notificationError: String?
    @Published var words: [WordRecord] = [] { didSet { if !isApplyingImport { save() }; refreshDueTimer(); if preferences.reviewNotificationsEnabled { queueNotificationSync() } } }
    @Published var headwords: [VocabularyHeadword] = [] { didSet { if !isApplyingImport { save() } } }
    @Published var lexicalEntries: [LexicalEntry] = [] { didSet { if !isApplyingImport { save() } } }
    @Published var sentences: [SentenceRecord] = [] { didSet { if !isApplyingImport { save() } } }
    @Published var collections: [SavedCollection] = [] { didSet { if !isApplyingImport { save() } } }
    @Published var preferences = AppPreferences() { didSet { if !isApplyingImport { save() }; if oldValue.reviewNotificationsEnabled != preferences.reviewNotificationsEnabled { queueNotificationSync() } } }
    @Published var pendingLearnSession: LearnSessionProgress? { didSet { if !isApplyingImport { save() } } }
    @Published var lastSession = SessionResult()

    private struct Snapshot: Codable {
        var words: [WordRecord]
        var headwords: [VocabularyHeadword]?
        var lexicalEntries: [LexicalEntry]?
        var sentences: [SentenceRecord]?
        var collections: [SavedCollection]
        var preferences: AppPreferences
        var pendingLearnSession: LearnSessionProgress?
    }

    private let fileURL: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("palapata.json")
        if let data = try? Data(contentsOf: fileURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let migratedStatusWords = snapshot.words.map { word in
                var migrated = word
                if migrated.learningStatus == nil || (migrated.status == .new && (migrated.reviewCount > 0 || migrated.nextReview != nil)) {
                    migrated.learningStatus = word.reviewCount == 0 && word.nextReview == nil ? .new :
                        word.intervalDays >= 21 ? .mastered :
                        word.intervalDays > 0 ? .reviewing : .learning
                }
                if migrated.status != .new && migrated.learningStartedAt == nil {
                    migrated.learningStartedAt = migrated.createdAt
                }
                return migrated
            }
            let hierarchy = VocabularyHierarchy.migrate(words: migratedStatusWords,
                headwords: snapshot.headwords ?? [], entries: snapshot.lexicalEntries ?? [])
            words = hierarchy.words
            headwords = hierarchy.headwords
            lexicalEntries = hierarchy.entries
            collections = snapshot.collections
            sentences = snapshot.sentences ?? []
            preferences = snapshot.preferences
            pendingLearnSession = snapshot.pendingLearnSession
            if words != snapshot.words || snapshot.headwords == nil || snapshot.lexicalEntries == nil { save() }
        }
        refreshDueTimer()
        queueNotificationSync()
    }

    private func save() {
        let snapshot = Snapshot(words: words, headwords: headwords, lexicalEntries: lexicalEntries, sentences: sentences, collections: collections, preferences: preferences, pendingLearnSession: pendingLearnSession)
        let destination = fileURL
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = Snapshot(words: words, headwords: headwords, lexicalEntries: lexicalEntries, sentences: sentences, collections: collections, preferences: preferences, pendingLearnSession: pendingLearnSession)
        let destination = fileURL
        saveQueue.sync {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    func setReviewNotificationsEnabled(_ enabled: Bool) {
        notificationRequestGeneration += 1
        let generation = notificationRequestGeneration
        if !enabled {
            preferences.reviewNotificationsEnabled = false
            notificationError = nil
            UserDefaults.standard.removeObject(forKey: ReviewNotificationRouting.lastOverdueScheduledKey)
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard generation == notificationRequestGeneration else { return }
                preferences.reviewNotificationsEnabled = granted
                notificationError = granted ? nil : "Allow notifications for Palapata in iPhone Settings to receive review reminders."
            } catch {
                guard generation == notificationRequestGeneration else { return }
                preferences.reviewNotificationsEnabled = false
                notificationError = "Notifications could not be enabled: \(error.localizedDescription)"
            }
        }
    }

    func refreshNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if preferences.reviewNotificationsEnabled && settings.authorizationStatus == .denied {
                preferences.reviewNotificationsEnabled = false
            } else {
                queueNotificationSync()
            }
        }
    }

    private func queueNotificationSync() {
        notificationSyncPending = true
        guard !notificationSyncInProgress else { return }
        notificationSyncInProgress = true
        Task { [weak self] in
            guard let self else { return }
            while self.notificationSyncPending {
                self.notificationSyncPending = false
                if let error = await ReviewNotificationScheduler.sync(words: self.words, enabled: self.preferences.reviewNotificationsEnabled) {
                    self.notificationError = error
                }
            }
            self.notificationSyncInProgress = false
        }
    }

    func commitImport(words importedWords: [WordRecord], headwords importedHeadwords: [VocabularyHeadword],
                      lexicalEntries importedEntries: [LexicalEntry], collections importedCollections: [SavedCollection]) throws {
        let snapshot = Snapshot(words: importedWords, headwords: importedHeadwords, lexicalEntries: importedEntries,
                                sentences: sentences, collections: importedCollections, preferences: preferences, pendingLearnSession: pendingLearnSession)
        pendingSave?.cancel()
        pendingSave = nil
        let destination = fileURL
        try saveQueue.sync {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: destination, options: .atomic)
        }
        isApplyingImport = true
        words = importedWords
        headwords = importedHeadwords
        lexicalEntries = importedEntries
        collections = importedCollections
        isApplyingImport = false
    }

    var dueWords: [WordRecord] {
        let now = Date()
        return words.filter { $0.isDue(asOf: now) }
    }
    var selectedLearningCategoryIDs: Set<String> {
        var available = Set(collections.map(\.id))
        if words.contains(where: { $0.collectionIDs.isEmpty }) { available.insert(LearningCategory.unsortedID) }
        return Set(preferences.selectedLearningCategoryIDs ?? Array(available)).intersection(available)
    }
    var learnedTodayCount: Int {
        words.filter { $0.learningStartedAt.map { Calendar.current.isDateInToday($0) } ?? false }.count
    }
    var remainingNewWordSlots: Int { max(0, preferences.newWordsPerDay - learnedTodayCount) }
    var eligibleNewWords: [WordRecord] {
        let selected = selectedLearningCategoryIDs
        return words.filter { $0.isEligibleForNewLearning(in: selected) }
    }
    var resumableLearnSession: LearnSessionProgress? {
        guard let session = pendingLearnSession, session.remainingCount > 0,
              let currentID = session.currentID else { return nil }
        let availableIDs = Set(words.map(\.id))
        guard availableIDs.contains(currentID), session.batchIDs.allSatisfy(availableIDs.contains),
              session.practiceQueue.allSatisfy(availableIDs.contains) else { return nil }
        return session
    }
    func setLearningCategories(_ ids: Set<String>) {
        preferences.selectedLearningCategoryIDs = Array(ids).sorted()
    }
    @discardableResult func introduce(_ id: UUID, alreadyKnown: Bool, misses: Int = 0, allowBeyondGoal: Bool = false) -> Bool {
        guard var item = word(id), item.status == .new,
              allowBeyondGoal || remainingNewWordSlots > 0 else { return false }
        item.beginLearning(alreadyKnown: alreadyKnown, misses: misses, at: Date())
        upsert(item)
        return true
    }
    func refreshDueState() {
        objectWillChange.send()
        refreshDueTimer()
    }
    private func refreshDueTimer() {
        dueTimer?.invalidate()
        let now = Date()
        let nextReview = words.filter({ $0.status != .new }).compactMap(\.nextReview).filter({ $0 > now }).min()
        let calendar = Calendar.current
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        let nextDate = min(nextReview ?? .distantFuture, nextMidnight)
        let timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDueState() }
        }
        dueTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    var staleWords: [WordRecord] { words.filter { $0.lastReviewed.map { Date().timeIntervalSince($0) > 30 * 86400 } ?? false } }
    func word(_ id: UUID) -> WordRecord? { words.first { $0.id == id } }
    func headword(for word: WordRecord) -> VocabularyHeadword? {
        headwords.first { $0.id == word.headwordID } ??
        headwords.first { VocabularyHierarchy.spellingKey($0.spelling) == VocabularyHierarchy.spellingKey(word.word) }
    }
    func draftSense(for word: WordRecord, separate: Bool) -> WordRecord {
        let related = senses(for: word)
        let homonym = separate ? (related.map(\.homonym).max() ?? 0) + 1 : word.homonym
        let senseNumber = separate ? 1 : (related.filter { $0.homonym == homonym }.map(\.sense).max() ?? 0) + 1
        var draft = WordRecord(word: word.word, meaning: "")
        draft.headwordID = word.headwordID
        draft.lexicalEntryID = separate ? nil : word.lexicalEntryID
        draft.homonymNumber = homonym
        draft.senseNumber = senseNumber
        draft.legacyUnmapped = false
        draft.pronunciation = headword(for: word)?.pronunciation ?? word.pronunciation
        draft.audioFile = headword(for: word)?.audioFile ?? word.audioFile
        return draft
    }
    func senses(for word: WordRecord) -> [WordRecord] {
        let key = VocabularyHierarchy.spellingKey(word.word)
        return words.filter { (word.headwordID != nil && $0.headwordID == word.headwordID) || VocabularyHierarchy.spellingKey($0.word) == key }
            .sorted { ($0.homonym, $0.sense, $0.createdAt) < ($1.homonym, $1.sense, $1.createdAt) }
    }
    var displayedWords: [WordRecord] {
        var seen = Set<String>()
        return words.filter { seen.insert(VocabularyHierarchy.spellingKey($0.word)).inserted }
    }
    func sentence(_ id: UUID) -> SentenceRecord? { sentences.first { $0.id == id } }
    func upsert(_ sentence: SentenceRecord) {
        if let index = sentences.firstIndex(where: { $0.id == sentence.id }) {
            if let old = sentences[index].audioFile, old != sentence.audioFile { removeAudio(old) }
            sentences[index] = sentence
        } else { sentences.append(sentence) }
    }
    func deleteSentence(_ id: UUID) {
        if let audio = sentence(id)?.audioFile { removeAudio(audio) }
        sentences.removeAll { $0.id == id }
    }
    func duplicate(of text: String) -> WordRecord? {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.first {
            $0.word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ") == normalized
        }
    }
    func addExample(to wordID: UUID, from sentence: SentenceRecord) {
        guard var word = word(wordID) else { return }
        if word.example.isEmpty {
            word.example = sentence.kweyol
            word.translation = sentence.english
        } else if word.example != sentence.kweyol || word.translation != sentence.english {
            var examples = word.additionalExamples ?? []
            guard !examples.contains(where: { $0.sentenceID == sentence.id || ($0.kweyol == sentence.kweyol && $0.english == sentence.english) }) else { return }
            examples.append(SentenceExample(sentenceID: sentence.id, kweyol: sentence.kweyol, english: sentence.english))
            word.additionalExamples = examples
        }
        upsert(word)
    }
    func upsert(_ word: WordRecord) {
        if let index = words.firstIndex(where: { $0.id == word.id }) {
            let old = words[index]
            if let headID = old.headwordID, let headIndex = headwords.firstIndex(where: { $0.id == headID }) {
                var updated = word
                updated.headwordID = headID
                updated.lexicalEntryID = old.lexicalEntryID
                let spellingChanged = word.word != old.word
                let pronunciationChanged = word.pronunciation != old.pronunciation
                let audioChanged = word.audioFile != old.audioFile
                if spellingChanged { headwords[headIndex].spelling = word.word }
                if pronunciationChanged { headwords[headIndex].pronunciation = word.pronunciation }
                if audioChanged { headwords[headIndex].audioFile = word.audioFile }
                if spellingChanged || pronunciationChanged || audioChanged {
                    words = words.enumerated().map { position, existing in
                        var sense = position == index ? updated : existing
                        if sense.headwordID == headID {
                            sense.word = headwords[headIndex].spelling
                            sense.pronunciation = headwords[headIndex].pronunciation
                            sense.audioFile = headwords[headIndex].audioFile
                        }
                        return sense
                    }
                    if audioChanged, let priorAudio = old.audioFile,
                       !words.contains(where: { $0.audioFile == priorAudio }),
                       !headwords.contains(where: { $0.audioFile == priorAudio }) { removeAudio(priorAudio) }
                } else { words[index] = updated }
            } else {
                var updated = words
                updated[index] = word
                let hierarchy = VocabularyHierarchy.migrate(words: updated, headwords: headwords, entries: lexicalEntries)
                words = hierarchy.words; headwords = hierarchy.headwords; lexicalEntries = hierarchy.entries
            }
        }
        else {
            let hierarchy = VocabularyHierarchy.migrate(words: words + [word], headwords: headwords, entries: lexicalEntries)
            words = hierarchy.words; headwords = hierarchy.headwords; lexicalEntries = hierarchy.entries
        }
    }
    func delete(_ id: UUID) {
        let removed = word(id)
        words.removeAll { $0.id == id }
        if let headID = removed?.headwordID, !words.contains(where: { $0.headwordID == headID }) {
            if let audio = headwords.first(where: { $0.id == headID })?.audioFile,
               !headwords.contains(where: { $0.id != headID && $0.audioFile == audio }) { removeAudio(audio) }
            headwords.removeAll { $0.id == headID }
            lexicalEntries.removeAll { $0.headwordID == headID }
        } else if let entryID = removed?.lexicalEntryID, !words.contains(where: { $0.lexicalEntryID == entryID }) {
            lexicalEntries.removeAll { $0.id == entryID }
        }
    }
    func deleteHeadword(for word: WordRecord) {
        let related = senses(for: word)
        let ids = Set(related.map(\.id))
        let headID = word.headwordID
        let audio = headword(for: word)?.audioFile
        words.removeAll { ids.contains($0.id) }
        if let headID {
            headwords.removeAll { $0.id == headID }
            lexicalEntries.removeAll { $0.headwordID == headID }
        }
        if let audio, !headwords.contains(where: { $0.audioFile == audio }) { removeAudio(audio) }
    }
    func collectionTitle(_ id: String) -> String { collections.first { $0.id == id }?.title ?? "Unsorted" }
    func collectionWords(_ id: String) -> [WordRecord] { words.filter { $0.collectionIDs.contains(id) } }
    func deleteCollection(_ id: String) {
        collections.removeAll { $0.id == id }
        words = words.map { var item = $0; item.collectionIDs.removeAll { $0 == id }; return item }
        sentences = sentences.map { var item = $0; item.collectionIDs.removeAll { $0 == id }; return item }
    }
    func audioURL(_ file: String) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(file)
    }
    func playAudio(_ file: String?) {
        guard let file else { return }
        let url = audioURL(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            playbackError = "This recording is missing. Please record the pronunciation again."
            return
        }
        do {
            player?.stop()
            player = nil
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let recording = try AVAudioPlayer(contentsOf: url)
            guard recording.prepareToPlay(), recording.play() else {
                playbackError = "This recording could not be played. Please record the pronunciation again."
                return
            }
            player = recording
            playbackError = nil
        } catch {
            playbackError = "This recording could not be played: \(error.localizedDescription)"
        }
    }
    func removeAudio(_ file: String?) { if let file { try? FileManager.default.removeItem(at: audioURL(file)) } }
    func rate(_ id: UUID, _ rating: RecallRating, sessionAttempts: Int, sessionMisses: Int) {
        guard var item = word(id), item.status != .new else { return }
        let now = Date()
        item.lastReviewed = now
        item.reviewCount += 1
        item.lastSessionAttempts = sessionAttempts
        item.lastSessionMisses = sessionMisses
        item.firstAttemptCorrect = sessionAttempts == 1 && rating == .gotIt
        item.totalMisses = item.totalMisses ?? 0
        switch rating {
        case .missedIt:
            item.consecutiveCorrectReviews = 0
            item.totalMisses = (item.totalMisses ?? 0) + 1
            item.recentMisses = min(4, (item.recentMisses ?? 0) + 1)
            item.currentReviewInterval = ReviewScheduler.missedInterval
            item.intervalDays = 0
            item.nextReview = now.addingTimeInterval(ReviewScheduler.missedInterval)
            item.learningStatus = .learning
        case .gotIt:
            let previousStreak = item.consecutiveCorrectReviews ?? ReviewScheduler.legacyStreak(intervalDays: item.intervalDays, reviewCount: item.reviewCount - 1)
            let streak = previousStreak + 1
            let recentMisses = item.recentMisses ?? 0
            var interval = ReviewScheduler.interval(for: streak, recentMisses: recentMisses, sessionMisses: sessionMisses)
            let previousInterval = item.currentReviewInterval ?? TimeInterval(item.intervalDays) * 86400
            if sessionMisses == 0 && previousInterval >= 86400 && interval <= previousInterval {
                interval = ReviewScheduler.nextInterval(after: previousInterval)
            }
            item.consecutiveCorrectReviews = streak
            item.recentMisses = max(0, recentMisses - (sessionMisses == 0 ? 1 : 0))
            item.currentReviewInterval = interval
            item.intervalDays = Int(interval / 86400)
            item.nextReview = now.addingTimeInterval(interval)
            item.learningStatus = interval < 86400 ? .learning : item.intervalDays >= 21 ? .mastered : .reviewing
        }
        upsert(item)
        lastSession.ratings.append(rating)
    }
    func resetProgress(_ id: UUID) {
        guard var item = word(id) else { return }
        item.lastReviewed = nil
        item.nextReview = nil
        item.intervalDays = 0
        item.reviewCount = 0
        item.currentReviewInterval = nil
        item.consecutiveCorrectReviews = nil
        item.totalMisses = nil
        item.recentMisses = nil
        item.lastSessionAttempts = nil
        item.lastSessionMisses = nil
        item.firstAttemptCorrect = nil
        item.learningStatus = .new
        item.learningStartedAt = nil
        upsert(item)
    }
    func resetProgress() {
        words = words.map { var item = $0; item.lastReviewed = nil; item.nextReview = nil; item.intervalDays = 0; item.reviewCount = 0; item.currentReviewInterval = nil; item.consecutiveCorrectReviews = nil; item.totalMisses = nil; item.recentMisses = nil; item.lastSessionAttempts = nil; item.lastSessionMisses = nil; item.firstAttemptCorrect = nil; item.learningStatus = .new; item.learningStartedAt = nil; return item }
    }
    func clearVocabulary(includeCollections: Bool) throws {
        let preservedAudio = Set(sentences.compactMap(\.audioFile))
        let wordAudio = Set(words.compactMap(\.audioFile) + headwords.compactMap(\.audioFile))
            .subtracting(preservedAudio)
        let remainingSentences = includeCollections ? sentences.map { sentence in
            var updated = sentence
            updated.collectionIDs = []
            return updated
        } : sentences
        var remainingPreferences = preferences
        if includeCollections { remainingPreferences.selectedLearningCategoryIDs = nil }
        let snapshot = Snapshot(words: [], headwords: [], lexicalEntries: [], sentences: remainingSentences,
                                collections: includeCollections ? [] : collections, preferences: remainingPreferences,
                                pendingLearnSession: nil)
        let destination = fileURL
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try saveQueue.sync {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            save()
            throw error
        }
        isApplyingImport = true
        words = []
        headwords = []
        lexicalEntries = []
        sentences = remainingSentences
        if includeCollections { collections = [] }
        preferences = remainingPreferences
        pendingLearnSession = nil
        lastSession = SessionResult()
        isApplyingImport = false
        UserDefaults.standard.removeObject(forKey: ReviewNotificationRouting.lastOverdueScheduledKey)
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier)
                .filter { $0.hasPrefix(ReviewNotificationRouting.prefix) })
        }
        for file in wordAudio { removeAudio(file) }
    }
    func exportBackup() -> URL {
        struct Backup: Codable { let words: [WordRecord]; let sentences: [SentenceRecord]; let collections: [SavedCollection]; let preferences: AppPreferences; let audio: [String: Data] }
        var audio: [String: Data] = [:]
        for word in words { if let file = word.audioFile { audio[file] = try? Data(contentsOf: audioURL(file)) } }
        for sentence in sentences { if let file = sentence.audioFile { audio[file] = try? Data(contentsOf: audioURL(file)) } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Palapata-backup.json")
        if let data = try? JSONEncoder().encode(Backup(words: words, sentences: sentences, collections: collections, preferences: preferences, audio: audio)) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }
}

private enum SpreadsheetReader {
    enum ImportError: LocalizedError {
        case invalidFile, missingSheet, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidFile: "This file is not a readable .xlsx spreadsheet."
            case .missingSheet: "The spreadsheet has no readable first sheet."
            case .tooLarge: "This spreadsheet is too large to import."
            }
        }
    }

    static func read(_ url: URL) throws -> [[String]] {
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 50_000_000 }) == true { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url)
        let archive = try ZipEntries(data)
        guard archive.file("[Content_Types].xml") != nil else { throw ImportError.invalidFile }
        let shared = try archive.file("xl/sharedStrings.xml").map { try SharedStringParser.parse($0) } ?? []
        var sheetPath: String?
        if let workbook = archive.file("xl/workbook.xml"), let relationships = archive.file("xl/_rels/workbook.xml.rels"),
           let relationshipID = try FirstSheetParser.parse(workbook),
           let target = try SheetRelationshipParser.parse(relationships, id: relationshipID) {
            let resolved = target.hasPrefix("/") ? target : "/xl/" + target
            sheetPath = String(URL(fileURLWithPath: resolved).standardizedFileURL.path.dropFirst())
        }
        if sheetPath == nil {
            sheetPath = archive.entries.keys.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }.sorted().first
        }
        guard let sheetPath, let sheet = archive.file(sheetPath) else { throw ImportError.missingSheet }
        return try SheetParser.parse(sheet, shared: shared)
    }

    private struct ZipEntries {
        let bytes: [UInt8]
        let entries: [String: (method: Int, offset: Int, packed: Int, size: Int)]
        init(_ data: Data) throws {
            let bytes = Array(data)
            self.bytes = bytes
            guard bytes.count >= 22 else { throw ImportError.invalidFile }
            func number(_ offset: Int, _ count: Int) -> Int {
                guard offset >= 0, offset + count <= bytes.count else { return 0 }
                return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
            }
            guard let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1).first(where: { number($0, 4) == 0x06054b50 }) else { throw ImportError.invalidFile }
            let entryCount = number(end + 10, 2)
            var cursor = number(end + 16, 4)
            var found: [String: (method: Int, offset: Int, packed: Int, size: Int)] = [:]
            for _ in 0..<min(entryCount, 10000) {
                guard number(cursor, 4) == 0x02014b50, cursor + 46 <= bytes.count else { throw ImportError.invalidFile }
                let nameLength = number(cursor + 28, 2), extraLength = number(cursor + 30, 2), commentLength = number(cursor + 32, 2)
                guard cursor + 46 + nameLength <= bytes.count else { throw ImportError.invalidFile }
                let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
                found[name] = (number(cursor + 10, 2), number(cursor + 42, 4), number(cursor + 20, 4), number(cursor + 24, 4))
                cursor += 46 + nameLength + extraLength + commentLength
            }
            entries = found
        }
        func file(_ name: String) -> Data? {
            guard let entry = entries[name], entry.size < 50_000_000, entry.packed < 50_000_000,
                  entry.offset + 30 <= bytes.count else { return nil }
            func number(_ offset: Int, _ count: Int) -> Int {
                guard offset >= 0, offset + count <= bytes.count else { return 0 }
                return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
            }
            guard number(entry.offset, 4) == 0x04034b50 else { return nil }
            let start = entry.offset + 30 + number(entry.offset + 26, 2) + number(entry.offset + 28, 2)
            guard start + entry.packed <= bytes.count else { return nil }
            let compressed = Data(bytes[start..<(start + entry.packed)])
            if entry.method == 0 { return compressed }
            guard entry.method == 8 else { return nil }
            var output = Data(count: entry.size)
            let outputSize = output.count
            var stream = z_stream()
            let status = compressed.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputSize)
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Z_DATA_ERROR }
                    let result = inflate(&stream, Z_FINISH)
                    inflateEnd(&stream)
                    return result
                }
            }
            return status == Z_STREAM_END ? output : nil
        }
    }

    private final class SharedStringParser: NSObject, XMLParserDelegate {
        var values: [String] = []
        private var insideItem = false
        private var insideText = false
        private var current = ""
        static func parse(_ data: Data) throws -> [String] {
            let delegate = SharedStringParser(), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = delegate
            guard parser.parse() else { throw ImportError.invalidFile }
            return delegate.values
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "si" { insideItem = true; current = "" }
            if insideItem && elementName == "t" { insideText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if insideText { current += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "t" { insideText = false }
            if elementName == "si" { values.append(current); insideItem = false }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        var rows: [[String]] = []
        let shared: [String]
        private var cells: [Int: String] = [:]
        private var column = 0
        private var cellType = ""
        private var capture = false
        private var value = ""
        init(shared: [String]) { self.shared = shared }
        static func parse(_ data: Data, shared: [String]) throws -> [[String]] {
            let delegate = SheetParser(shared: shared), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = delegate
            guard parser.parse() else { throw ImportError.invalidFile }
            return delegate.rows
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "row" { cells = [:] }
            if elementName == "c" {
                column = 0; value = ""; cellType = attributeDict["t"] ?? ""
                for scalar in (attributeDict["r"] ?? "").unicodeScalars where scalar.value >= 65 && scalar.value <= 90 {
                    column = column * 26 + Int(scalar.value - 64)
                }
                column = max(0, column - 1)
            }
            if elementName == "v" || elementName == "t" { capture = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if capture { value += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "v" || elementName == "t" { capture = false }
            if elementName == "c" {
                if cellType == "s", let index = Int(value), shared.indices.contains(index) { cells[column] = shared[index] }
                else { cells[column] = value }
            }
            if elementName == "row" {
                let count = min((cells.keys.max() ?? -1) + 1, 16_384)
                rows.append((0..<count).map { cells[$0] ?? "" })
            }
        }
    }

    private final class FirstSheetParser: NSObject, XMLParserDelegate {
        var relationshipID: String?
        static func parse(_ data: Data) throws -> String? {
            let delegate = FirstSheetParser(), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = delegate
            guard parser.parse() else { throw ImportError.invalidFile }
            return delegate.relationshipID
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "sheet", relationshipID == nil { relationshipID = attributeDict["r:id"] ?? attributeDict["id"] }
        }
    }

    private final class SheetRelationshipParser: NSObject, XMLParserDelegate {
        let id: String
        var target: String?
        init(id: String) { self.id = id }
        static func parse(_ data: Data, id: String) throws -> String? {
            let delegate = SheetRelationshipParser(id: id), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = delegate
            guard parser.parse() else { throw ImportError.invalidFile }
            return delegate.target
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "Relationship", attributeDict["Id"] == id,
               attributeDict["Type"]?.hasSuffix("/worksheet") == true {
                target = attributeDict["Target"]
            }
        }
    }
}

private enum ScreenRoute: Equatable {
    case addWord
    case learnNewWords(Bool)
    case addSentence
    case editSentence(UUID)
    case extractSentence(UUID)
    case sentenceDetails(UUID)
    case importExcel
    case review
    case reviewStale
    case reviewComplete
    case reviewSession
    case reviewSettings
    case recordPronunciation(WordRecord)
    case collection(String)
    case wordDetails(WordRecord)
    case editWord(WordRecord)
}

struct TodayScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = VocabularyStore()
    @State private var selectedTab: AppTab = .today
    @State private var route: ScreenRoute?
    @State private var routeHistory: [ScreenRoute] = []
    @State private var draft = WordRecord(word: "", meaning: "")
    @State private var reviewIDs: [UUID] = []
    @State private var learnIDs: [UUID] = []
    @State private var showReviewCollectionPicker = false
    @State private var showAddContentPicker = false
    @State private var showLearningCategoryPicker = false
    @State private var selectedReviewCollections: Set<String> = []

    private var collections: [CollectionExample] { store.collections.map { CollectionExample(saved: $0, count: store.collectionWords($0.id).count) } }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 476

            VStack(spacing: 0) {
                if let route {
                    switch route {
                    case .addWord:
                        AddWordScreen(word: $draft, collections: collections, onBack: goBack, onRecord: { navigate(.recordPronunciation(draft)) }, onSaveCollection: saveCollection, onSave: {
                            draft.legacyUnmapped = false
                            store.upsert(draft)
                            let headwordID = store.word(draft.id)?.headwordID
                            for var sense in $0 {
                                sense.word = draft.word
                                sense.headwordID = headwordID
                                sense.legacyUnmapped = false
                                sense.pronunciation = draft.pronunciation
                                sense.audioFile = draft.audioFile
                                store.upsert(sense)
                            }
                            selectTab(.library)
                        }, store: store)
                    case .learnNewWords(let allowBeyondGoal):
                        LearnNewWordsScreen(items: learnIDs.compactMap(store.word), store: store, allowBeyondGoal: allowBeyondGoal,
                                            progress: store.resumableLearnSession, onClose: returnHome,
                                            onAddContent: { showAddContentPicker = true }, onSelectTab: selectTab)
                    case .addSentence:
                        SentenceFlowScreen(existing: nil, startAtExtract: false, collections: collections, store: store, onClose: goBack, onDone: { selectTab(.library) }, onOpenWord: openExistingWord, onSaveCollection: saveCollection)
                    case .editSentence(let id):
                        SentenceFlowScreen(existing: store.sentence(id), startAtExtract: false, collections: collections, store: store, onClose: goBack, onDone: { selectTab(.library) }, onOpenWord: openExistingWord, onSaveCollection: saveCollection)
                    case .extractSentence(let id):
                        SentenceFlowScreen(existing: store.sentence(id), startAtExtract: true, collections: collections, store: store, onClose: goBack, onDone: { selectTab(.library) }, onOpenWord: openExistingWord, onSaveCollection: saveCollection)
                    case .sentenceDetails(let id):
                        if let sentence = store.sentence(id) {
                            SentenceDetailScreen(sentence: sentence, store: store, onBack: goBack, onEdit: { navigate(.editSentence(id)) }, onExtract: { navigate(.extractSentence(id)) }, onDelete: { store.deleteSentence(id); selectTab(.library) })
                        }
                    case .wordDetails(let word):
                        WordDetailsScreen(word: store.word(word.id) ?? word, onBack: goBack,
                                          onEdit: { navigate(.editWord(word)) }, onEditSense: { navigate(.editWord($0)) },
                                          onCollection: { if let id = store.word(word.id)?.collectionIDs.first { navigate(.collection(id)) } else { navigate(.editWord(word)) } },
                                          store: store, onDelete: { store.deleteHeadword(for: word); selectTab(.library) })
                    case .editWord(let word):
                        EditWordScreen(word: store.word(word.id) ?? word, collections: collections, onBack: goBack,
                                       onRecord: { navigate(.recordPronunciation(store.word(word.id) ?? word)) },
                                       onSave: { edited in store.upsert(edited); self.route = .wordDetails(edited) },
                                       onAddMeaning: { separate in navigate(.editWord(store.draftSense(for: store.word(word.id) ?? word, separate: separate))) },
                                       onDelete: { store.delete(word.id); selectTab(.library) }, store: store)
                            .id("\(word.id)-\(store.word(word.id)?.audioFile ?? "")")
                    case .recordPronunciation(let word):
                        RecordingScreen(word: word, onBack: goBack, onSave: { audioFile in
                            if word.id == draft.id { store.removeAudio(draft.audioFile); draft.audioFile = audioFile }
                            else if var saved = store.word(word.id) { saved.audioFile = audioFile; store.upsert(saved) }
                            else if var saved = store.senses(for: word).first {
                                saved.audioFile = audioFile
                                store.upsert(saved)
                            }
                            goBack()
                        }, store: store)
                    case .review, .reviewStale:
                        ReviewScreen(items: reviewIDs.compactMap(store.word), store: store, onClose: goBack, onComplete: {
                            routeHistory.removeAll()
                            self.route = .reviewComplete
                        })
                    case .reviewComplete:
                        ReviewCompleteScreen(result: store.lastSession, onSession: { navigate(.reviewSession) }, onHome: returnHome,
                                             onAddContent: { showAddContentPicker = true }, onSelectTab: selectTab)
                    case .reviewSession:
                        ReviewSessionScreen(result: store.lastSession, dueCount: store.dueWords.count, onBack: goBack, onReviewAgain: restartReview, onHome: returnHome)
                    case .reviewSettings:
                        ReviewSettingsScreen(selectedTab: selectedTab, store: store, onBack: goBack, onSelectTab: selectTab)
                    case .collection(let name):
                        CollectionDetailScreen(name: name, collection: collections.first(where: { $0.id == name }) ?? CollectionExample.named(name), words: store.collectionWords(name), store: store, onBack: goBack, onNavigate: navigate, onSave: saveCollection, onSelectTab: selectTab, onShowVocabulary: {
                            self.route = nil
                            routeHistory.removeAll()
                            selectedTab = .library
                        })
                    default:
                        DestinationScreen(route: route, selectedTab: selectedTab, store: store, onBack: goBack, onNavigate: navigate, onSelectTab: selectTab)
                    }
                } else if selectedTab == .library {
                    VocabularyScreen(store: store, onNavigate: navigate, onAddContent: { showAddContentPicker = true }, onSelectTab: { selectedTab = $0 })
                } else if selectedTab == .collections {
                    CollectionsScreen(collections: collections, onNavigate: navigate, onSelectTab: { selectedTab = $0 }, onSave: saveCollection)
                } else if selectedTab == .settings {
                    SettingsScreen(store: store, onNavigate: navigate, onSelectTab: selectTab)
                } else {
                    AppHeader(onAdd: { showAddContentPicker = true }, addAccessibilityLabel: "Add content", bottomPadding: 0)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            switch selectedTab {
                            case .today:
                                TodayIntroduction()
                                if store.words.isEmpty {
                                    EmptyTodayContent(wordCount: store.displayedWords.count, collectionCount: collections.count, onNavigate: navigate, onSelectTab: { selectedTab = $0 })
                                } else {
                                    PopulatedTodayContent(dueCount: store.dueWords.count, newWordCount: store.eligibleNewWords.count,
                                                          pendingWordCount: store.resumableLearnSession?.remainingCount ?? 0,
                                                          learnedToday: store.learnedTodayCount, dailyLimit: store.preferences.newWordsPerDay,
                                                          selectedCategoryCount: store.selectedLearningCategoryIDs.count,
                                                          wordCount: store.displayedWords.count, collectionCount: collections.count,
                                                          featuredWord: store.dueWords.first?.word ?? store.eligibleNewWords.first?.word ?? "Kwéyòl",
                                                          onLearn: { startLearningSession(allowBeyondGoal: false) },
                                                          onLearnMore: { startLearningSession(allowBeyondGoal: true) },
                                                          onCategories: { showLearningCategoryPicker = true }, onNavigate: navigate, onSelectTab: { selectedTab = $0 })
                                }
                            case .library:
                                EmptyView()
                            case .collections:
                                EmptyView()
                            case .settings:
                                EmptyView()
                            }
                        }
                        .padding(.horizontal, 23)
                        .padding(.bottom, 32)
                    }

                    BottomNavigation(selected: selectedTab, onSelect: { selectedTab = $0 })
                }
            }
            .frame(width: 476, height: geometry.size.height / scale)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Style.background.ignoresSafeArea())
        .foregroundStyle(Style.ink)
        .preferredColorScheme(.light)
        .onAppear { openPendingDueReview() }
        .onReceive(NotificationCenter.default.publisher(for: ReviewNotificationRouting.openDueReview)) { _ in openPendingDueReview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshDueState()
                store.refreshNotificationPermission()
                openPendingDueReview()
            } else if phase == .background {
                store.flushSave()
            }
        }
        .alert("Unable to play pronunciation", isPresented: Binding(get: { store.playbackError != nil }, set: { if !$0 { store.playbackError = nil } })) {
            Button("OK", role: .cancel) { store.playbackError = nil }
        } message: { Text(store.playbackError ?? "") }
        .sheet(isPresented: $showReviewCollectionPicker) {
            NavigationStack {
                List {
                    ForEach(store.collections) { collection in
                        Button {
                            if !selectedReviewCollections.insert(collection.id).inserted { selectedReviewCollections.remove(collection.id) }
                        } label: {
                            HStack {
                                Text(collection.title)
                                Spacer()
                                Text("\(store.collectionWords(collection.id).count)")
                                if selectedReviewCollections.contains(collection.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Style.teal) }
                            }
                        }.foregroundStyle(Style.ink)
                    }
                }
                .navigationTitle("Review collections")
                .safeAreaInset(edge: .bottom) {
                    let reviewableCount = store.words.filter { $0.status != .new && !$0.collectionIDs.filter(selectedReviewCollections.contains).isEmpty }.count
                    Button {
                        startReview(collectionIDs: Array(selectedReviewCollections))
                        showReviewCollectionPicker = false
                        route = .review
                    } label: {
                        Text("Start review · \(wordCountLabel(reviewableCount))")
                            .font(Style.heading(18)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 60)
                            .background(Style.teal, in: RoundedRectangle(cornerRadius: 17))
                    }
                    .disabled(selectedReviewCollections.isEmpty || reviewableCount == 0)
                    .padding(20)
                }
            }
        }
        .sheet(isPresented: $showAddContentPicker) {
            AddContentTypeSheet(onWord: { showAddContentPicker = false; navigate(.addWord) }, onSentence: { showAddContentPicker = false; navigate(.addSentence) }, onCancel: { showAddContentPicker = false })
                .presentationDetents([.height(355)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
        .sheet(isPresented: $showLearningCategoryPicker) {
            LearningCategoriesSheet(store: store, onDone: { showLearningCategoryPicker = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
    }

    private func navigate(_ destination: ScreenRoute) {
        if destination == .addWord { store.removeAudio(draft.audioFile); draft = WordRecord(word: "", meaning: "") }
        if destination == .review { startReview(collectionID: nil) }
        if destination == .reviewStale { startReview(stale: true) }
        if case .collection(let id) = route, destination == .review { startReview(collectionID: id) }
        if let route {
            routeHistory.append(route)
        }
        route = destination
    }

    private func goBack() {
        if route == .addWord { store.removeAudio(draft.audioFile); draft.audioFile = nil }
        route = routeHistory.popLast()
    }

    private func restartReview() {
        routeHistory.removeAll()
        startReview(collectionID: nil)
        route = .review
    }

    private func returnHome() {
        routeHistory.removeAll()
        route = nil
        selectedTab = .today
    }

    private func openPendingDueReview() {
        guard UserDefaults.standard.bool(forKey: ReviewNotificationRouting.pendingOpenKey) else { return }
        UserDefaults.standard.set(false, forKey: ReviewNotificationRouting.pendingOpenKey)
        selectTab(.today)
        if !store.dueWords.isEmpty { navigate(.review) }
    }

    private func openExistingWord(_ word: WordRecord) {
        selectTab(.library)
        navigate(.wordDetails(word))
    }

    private func selectTab(_ tab: AppTab) {
        routeHistory.removeAll()
        route = nil
        selectedTab = tab
    }

    private func saveCollection(_ collection: CollectionExample) {
        let saved = collection.saved
        if let index = store.collections.firstIndex(where: { $0.id == saved.id }) {
            store.collections[index] = saved
        } else {
            store.collections.append(saved)
        }
    }

    private func startReview(collectionID: String? = nil, stale: Bool = false, collectionIDs: [String] = []) {
        let candidates: [WordRecord]
        if !collectionIDs.isEmpty { candidates = store.words.filter { !$0.collectionIDs.filter(collectionIDs.contains).isEmpty } }
        else if let collectionID { candidates = store.collectionWords(collectionID) }
        else if stale { candidates = store.staleWords }
        else { candidates = store.dueWords }
        let selected = Array(candidates.filter { $0.status != .new }.prefix(store.preferences.sessionSize))
        reviewIDs = selected.map(\.id)
        store.lastSession = SessionResult(collectionCount: Set(selected.flatMap(\.collectionIDs)).count, featuredWord: selected.first?.word ?? "")
    }

    private func startLearningSession(allowBeyondGoal: Bool) {
        if let pending = store.resumableLearnSession {
            learnIDs = pending.batchIDs
            routeHistory.removeAll()
            route = .learnNewWords(pending.allowBeyondGoal)
            return
        }
        if store.pendingLearnSession != nil { store.pendingLearnSession = nil }
        let limit = allowBeyondGoal ? store.preferences.newWordsPerDay : store.remainingNewWordSlots
        var selected: [WordRecord] = []
        var selectedHeadwords = Set<String>()
        for sense in store.eligibleNewWords where selected.count < max(0, limit) {
            if selectedHeadwords.insert(VocabularyHierarchy.spellingKey(sense.word)).inserted { selected.append(sense) }
        }
        guard !selected.isEmpty else { return }
        learnIDs = selected.map(\.id)
        routeHistory.removeAll()
        route = .learnNewWords(allowBeyondGoal)
    }
}

private struct AppHeader: View {
    let onAdd: (() -> Void)?
    let addAccessibilityLabel: String
    let bottomPadding: CGFloat

    init(onAdd: (() -> Void)? = nil, addAccessibilityLabel: String = "Add word", bottomPadding: CGFloat = 21) {
        self.onAdd = onAdd
        self.addAccessibilityLabel = addAccessibilityLabel
        self.bottomPadding = bottomPadding
    }

    var body: some View {
        HStack(spacing: 12) {
            BrandLockup()

            Spacer()

            if let onAdd {
                Button(action: onAdd) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(Style.coral.opacity(0.43))
                            .offset(x: 4, y: 5)
                        RoundedRectangle(cornerRadius: 17)
                            .fill(Style.coral)
                        Image(systemName: "plus")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 49, height: 49)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(addAccessibilityLabel)
            }
        }
        .padding(.horizontal, 23)
        .padding(.top, 11)
        .padding(.bottom, bottomPadding)
        .background(Style.background)
    }
}

private struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 12) {
            FlowerLogo()
                .frame(width: 49, height: 49)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("my kwéyòl")
                    .font(Style.heading(23))
                    .tracking(-1.3)
                Text(".")
                    .font(Style.heading(25))
                    .foregroundStyle(Style.coral)
            }
        }
    }
}

private struct FlowerLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Style.teal)
                .rotationEffect(.degrees(-7))

            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(Style.background)
                    .frame(width: 3.4, height: 17)
                    .offset(y: -9)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle()
                .fill(Style.yellow)
                .frame(width: 9, height: 9)
        }
    }
}

private struct DropdownChoice: Identifiable {
    let id: String
    let title: String
}

private struct DropdownOptionsCard: View {
    let options: [DropdownChoice]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 3) {
                ForEach(options) { option in
                    Button { onSelect(option.id) } label: {
                        HStack(spacing: 10) {
                            Text(option.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Style.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if selectedID == option.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Style.teal)
                            }
                        }
                        .padding(.horizontal, 13)
                        .frame(height: 43)
                        .background(selectedID == option.id ? Style.mint : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedID == option.id ? .isSelected : [])
                }
            }
            .padding(7)
        }
        .frame(height: min(CGFloat(options.count) * 46 + 14, 250))
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Style.teal.opacity(0.17), lineWidth: 1))
        .shadow(color: Style.ink.opacity(0.10), radius: 15, y: 6)
    }
}

private struct TodayIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Today")
                .font(Style.heading(49))
                .tracking(-2.8)
                .foregroundStyle(Style.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 3)
        .padding(.bottom, 10)
    }
}

private struct PopulatedTodayContent: View {
    let dueCount: Int
    let newWordCount: Int
    let pendingWordCount: Int
    let learnedToday: Int
    let dailyLimit: Int
    let selectedCategoryCount: Int
    let wordCount: Int
    let collectionCount: Int
    let featuredWord: String
    let onLearn: () -> Void
    let onLearnMore: () -> Void
    let onCategories: () -> Void
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        let goalReached = learnedToday >= dailyLimit
        let hasPendingSession = pendingWordCount > 0
        let available = hasPendingSession ? pendingWordCount : min(newWordCount, max(0, dailyLimit - learnedToday))
        VStack(alignment: .leading, spacing: 0) {
            ReviewCard(mode: dueCount > 0 ? .review : goalReached ? .goal : .learn,
                       count: dueCount > 0 ? dueCount : available,
                       learnedToday: learnedToday, dailyLimit: dailyLimit,
                       featuredWord: featuredWord,
                       buttonTitle: dueCount > 0 ? "Start review" : hasPendingSession ? "Continue learning" : goalReached ? "Learn more anyway" : available > 0 ? "Start learning" : "Choose categories",
                       enabled: dueCount > 0 || hasPendingSession || !goalReached || newWordCount > 0,
                       onStart: dueCount > 0 ? { onNavigate(.review) } : hasPendingSession ? onLearn : goalReached ? onLearnMore : available > 0 ? onLearn : onCategories)

            Button(action: onCategories) {
                HStack(spacing: 17) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Style.purpleInk)
                        .frame(width: 65, height: 65)
                        .background(Style.lavender, in: RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Learning categories").font(Style.heading(19)).foregroundStyle(Style.ink)
                        Text("\(selectedCategoryCount) \(selectedCategoryCount == 1 ? "category" : "categories") selected")
                            .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(Style.ink)
                }
                .padding(.horizontal, 15)
                .frame(height: 91)
                .background(.white, in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            if dueCount > 0 {
                Button(action: hasPendingSession ? onLearn : goalReached ? onLearnMore : onLearn) {
                    HStack(spacing: 16) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Style.teal)
                            .frame(width: 62, height: 62)
                            .background(Color(red: 0.73, green: 0.94, blue: 0.85), in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hasPendingSession ? "Continue learning" : goalReached ? "Today's goal reached" : "Learn new words")
                                .font(Style.heading(19)).foregroundStyle(Style.ink)
                            Text("Learned today: \(learnedToday) of \(dailyLimit)")
                                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").font(.system(size: 22, weight: .semibold)).foregroundStyle(Style.ink)
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 83)
                    .background(Style.mint, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .disabled(!hasPendingSession && (newWordCount == 0 || (!goalReached && available == 0)))
                .opacity(!hasPendingSession && newWordCount == 0 ? 0.55 : 1)
                .padding(.top, 11)
            }

            LibrarySummary(wordCount: wordCount, collectionCount: collectionCount, onNavigate: onNavigate, onSelectTab: onSelectTab)
                .padding(.top, 14)
        }
    }
}

private enum TodayHeroMode { case review, learn, goal }

private struct ReviewCard: View {
    let mode: TodayHeroMode
    let count: Int
    let learnedToday: Int
    let dailyLimit: Int
    let featuredWord: String
    let buttonTitle: String
    let enabled: Bool
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 30).fill(Style.teal)
                    Text(mode == .review ? "READY FOR REVIEW" : mode == .learn ? "READY TO LEARN" : "TODAY'S GOAL REACHED")
                        .font(Style.heading(15)).tracking(0.7)
                        .foregroundStyle(.white)
                        .position(x: 127, y: 32)

                    if mode == .goal {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 36, weight: .heavy))
                                .foregroundStyle(Style.ink)
                                .frame(width: 68, height: 68)
                                .background(Style.yellow, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Learned today:").font(Style.heading(20))
                                Text("\(learnedToday) of \(dailyLimit)").font(Style.heading(29))
                            }
                            .foregroundStyle(.white)
                        }
                        .position(x: 143, y: 126)
                    } else {
                        Text(count.formatted())
                            .font(Style.heading(95))
                            .tracking(-4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .foregroundStyle(Style.yellow)
                            .frame(width: min(geometry.size.width * 0.59, 250), height: 112, alignment: .leading)
                            .position(x: 24 + min(geometry.size.width * 0.59, 250) / 2, y: 113)
                        Text(mode == .review ? "words due today" : "new words available")
                            .font(Style.heading(18))
                            .foregroundStyle(.white)
                            .frame(width: 250, alignment: .leading)
                            .position(x: 149, y: 169)
                    }

                    WordCardIllustration(word: featuredWord)
                        .frame(width: 145, height: 143)
                        .position(x: geometry.size.width - 79, y: 105)
                    Sparkle(color: Style.yellow, length: 14)
                        .frame(width: 28, height: 28)
                        .position(x: geometry.size.width - 150, y: 53)

                    HStack {
                        Text(buttonTitle).font(Style.heading(18))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 23, weight: .heavy))
                    }
                    .foregroundStyle(Style.ink)
                    .padding(.horizontal, 20)
                    .frame(height: 59)
                    .background(Style.yellow, in: RoundedRectangle(cornerRadius: 19))
                    .padding(.horizontal, 24)
                    .position(x: geometry.size.width / 2, y: 219)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 30))
            }
            .frame(height: 275)
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct LearningCategoriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VocabularyStore
    let onDone: () -> Void
    @State private var selected: Set<String>
    @State private var searchText = ""

    init(store: VocabularyStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _selected = State(initialValue: store.selectedLearningCategoryIDs)
    }

    private var counts: [String: (total: Int, new: Int)] {
        var result: [String: (total: Int, new: Int)] = [:]
        for word in store.words {
            let ids = word.collectionIDs.isEmpty ? [LearningCategory.unsortedID] : word.collectionIDs
            for id in Set(ids) {
                var count = result[id, default: (0, 0)]
                count.total += 1
                if word.status == .new { count.new += 1 }
                result[id] = count
            }
        }
        return result
    }

    var body: some View {
        let categoryCounts = counts
        let visibleCollections = store.collections.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
        let showUnsorted = (categoryCounts[LearningCategory.unsortedID]?.total ?? 0) > 0
            && (searchText.isEmpty || "Unsorted".localizedCaseInsensitiveContains(searchText))

        VStack(spacing: 0) {
            HStack {
                BrandLockup()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Style.teal)
                        .frame(width: 43, height: 43)
                        .background(Style.mint, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close learning categories")
            }
            .padding(.horizontal, 23)
            .padding(.top, 25)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Learning categories").foregroundStyle(Style.ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(".").foregroundStyle(Style.coral)
                }
                .font(Style.heading(36))
                .tracking(-1.6)
                Text("Choose where new words come from. Due reviews include learned words from every category.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                CollectionSearchField(placeholder: "Search categories...", text: $searchText)
                    .padding(.top, 20)
                HStack(spacing: 10) {
                    Text("\(selected.count) selected")
                        .font(Style.heading(14))
                        .foregroundStyle(Style.teal)
                        .padding(.horizontal, 12)
                        .frame(height: 31)
                        .background(Style.mint, in: Capsule())
                    Spacer()
                    Button("Select all") {
                        selected = Set(store.collections.map(\.id))
                        if (categoryCounts[LearningCategory.unsortedID]?.total ?? 0) > 0 { selected.insert(LearningCategory.unsortedID) }
                    }
                    Button("Clear all") { selected.removeAll() }
                }
                .font(Style.heading(14))
                .foregroundStyle(Style.teal)
                .buttonStyle(.plain)
                .padding(.top, 17)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 23)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(visibleCollections) { category in
                        let appearance = CollectionExample(saved: category, count: categoryCounts[category.id]?.total ?? 0)
                        categoryRow(id: category.id, title: category.title, icon: appearance.icon,
                                    fill: appearance.fill, ink: appearance.ink,
                                    total: categoryCounts[category.id]?.total ?? 0,
                                    new: categoryCounts[category.id]?.new ?? 0)
                    }
                    if showUnsorted {
                        categoryRow(id: LearningCategory.unsortedID, title: "Unsorted", icon: "tray.full.fill",
                                    fill: Style.mint, ink: Style.teal,
                                    total: categoryCounts[LearningCategory.unsortedID]?.total ?? 0,
                                    new: categoryCounts[LearningCategory.unsortedID]?.new ?? 0)
                    }
                    if visibleCollections.isEmpty && !showUnsorted {
                        Text(searchText.isEmpty ? "Your collections will appear here." : "No matching categories.")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 34)
                    }
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 20)
            }

            Button {
                store.setLearningCategories(selected)
                onDone()
            } label: {
                Text("Done · \(selected.count) selected")
                    .font(Style.heading(18))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(Style.teal, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 23)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Style.background)
        }
        .background(Style.background.ignoresSafeArea())
    }

    private func categoryRow(id: String, title: String, icon: String, fill: Color, ink: Color, total: Int, new: Int) -> some View {
        Button { if !selected.insert(id).inserted { selected.remove(id) } } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(fill)
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(ink)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Style.heading(20))
                        .foregroundStyle(Style.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(new) new · \(total) total")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                }
                Spacer(minLength: 0)
                Image(systemName: selected.contains(id) ? "checkmark" : "circle")
                    .font(.system(size: selected.contains(id) ? 16 : 26, weight: .semibold))
                    .foregroundStyle(selected.contains(id) ? .white : Style.quiet)
                    .frame(width: 31, height: 31)
                    .background(selected.contains(id) ? Style.teal : .clear, in: Circle())
            }
            .padding(.horizontal, 11)
            .frame(height: 82)
            .background(.white, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(new) new words, \(total) total, \(selected.contains(id) ? "selected" : "not selected")")
    }
}

private struct WordCardIllustration: View {
    let word: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Style.yellow)
                .frame(width: 110, height: 123)
                .rotationEffect(.degrees(13))
                .offset(x: 19, y: 10)
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 1, green: 0.65, blue: 0.52))
                .frame(width: 110, height: 123)
                .rotationEffect(.degrees(13))
                .offset(x: 9, y: 3)
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.87, green: 0.81, blue: 0.96))
                .frame(width: 113, height: 123)
                .rotationEffect(.degrees(13))
            VStack(spacing: 9) {
                Text(word)
                    .font(.system(size: 43, weight: .black, design: .rounded))
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(width: 100)
                Text("KWÉYÒL")
                    .font(Style.heading(11))
                    .tracking(2)
                    .opacity(0.6)
            }
            .foregroundStyle(Style.purpleInk)
            .rotationEffect(.degrees(13))
        }
    }
}

private struct Sparkle: View {
    let color: Color
    let length: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Rectangle()
                    .fill(color)
                    .frame(width: 1.4, height: length)
                    .offset(y: -length / 2)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
        }
    }
}

private struct LibrarySummary: View {
    let wordCount: Int
    let collectionCount: Int
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your library")
                .font(Style.heading(32))
                .tracking(-0.7)
                .foregroundStyle(Color(red: 0.16, green: 0.21, blue: 0.30))
                .padding(.bottom, 7)

            HStack(spacing: 12) {
                SummaryTile(number: "\(wordCount)", caption: "Total words", symbol: "book.closed.fill", fill: Color(red: 0.89, green: 0.96, blue: 0.93), symbolFill: Color(red: 0.78, green: 0.91, blue: 0.87), ink: Style.teal, captionInk: Color(red: 0.35, green: 0.43, blue: 0.41))
                    .onTapGesture { onSelectTab(.library) }
                SummaryTile(number: "\(collectionCount)", caption: "Collections", symbol: "square.3.layers.3d", fill: Color(red: 0.94, green: 0.90, blue: 1.0), symbolFill: Color(red: 0.88, green: 0.82, blue: 0.98), ink: Color(red: 0.31, green: 0.23, blue: 0.54), captionInk: Color(red: 0.35, green: 0.29, blue: 0.52))
                    .onTapGesture { onSelectTab(.collections) }
            }

            HStack(spacing: 12) {
                LibraryActionTile(title: "Add new word", symbol: "plus", fill: Color(red: 1, green: 0.60, blue: 0.53), symbolFill: Color(red: 1, green: 0.77, blue: 0.70), ink: Color(red: 0.31, green: 0.20, blue: 0.19))
                    .onTapGesture { onNavigate(.addWord) }
                LibraryActionTile(title: "Import from Excel", symbol: "square.and.arrow.up", fill: Color(red: 0.93, green: 0.89, blue: 0.99), symbolFill: Color(red: 0.96, green: 0.94, blue: 1), ink: Color(red: 0.27, green: 0.20, blue: 0.50))
                    .onTapGesture { onNavigate(.importExcel) }
            }
        }
    }
}

private struct SummaryTile: View {
    let number: String
    let caption: String
    let symbol: String
    let fill: Color
    let symbolFill: Color
    let ink: Color
    let captionInk: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 36, height: 34)
                .background(symbolFill, in: RoundedRectangle(cornerRadius: 13))

            Spacer(minLength: 2)

            Text(number)
                .font(Style.heading(35))
                .tracking(-1.5)
                .foregroundStyle(ink)
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(captionInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 112)
        .background(fill, in: RoundedRectangle(cornerRadius: 21))
        .contentShape(RoundedRectangle(cornerRadius: 21))
    }
}

private struct LibraryActionTile: View {
    let title: String
    let symbol: String
    let fill: Color
    let symbolFill: Color
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .heavy))
                .frame(width: 35, height: 35)
                .background(symbolFill, in: RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title)
                    .font(Style.heading(15))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .bold))
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 88)
        .background(fill, in: RoundedRectangle(cornerRadius: 21))
        .contentShape(RoundedRectangle(cornerRadius: 21))
    }
}

private struct EmptyTodayContent: View {
    let wordCount: Int
    let collectionCount: Int
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmptyIllustration()
                .frame(height: 233)

            Text("Every word starts\nsomewhere.")
                .font(Style.heading(37))
                .tracking(-1.5)
                .lineSpacing(-2)
                .foregroundStyle(Style.ghost)
                .padding(.top, 28)

            Text("Heard a new Kwéyòl word? Save its meaning, pronunciation and an example so you can remember it.")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .lineSpacing(8)
                .foregroundStyle(Style.quiet)
                .padding(.top, 14)

            HStack {
                Text("+ Add your first word")
                    .font(Style.heading(17))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 21)
            .frame(height: 65)
            .background(Style.teal, in: RoundedRectangle(cornerRadius: 18))
            .padding(.top, 25)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture { onNavigate(.addWord) }

            HStack(spacing: 3) {
                Text("Import from Excel")
                Image(systemName: "arrow.up.right")
            }
            .font(Style.heading(16))
            .foregroundStyle(Style.teal)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .contentShape(Rectangle())
            .onTapGesture { onNavigate(.importExcel) }

            LibrarySummary(wordCount: wordCount, collectionCount: collectionCount, onNavigate: onNavigate, onSelectTab: onSelectTab)
                .padding(.top, 55)
        }
    }
}

private struct EmptyIllustration: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 32)
                    .fill(Style.lavender)

                RoundedRectangle(cornerRadius: 27)
                    .fill(Style.yellow)
                    .frame(width: 129, height: 154)
                    .rotationEffect(.degrees(-9))
                    .offset(x: 33, y: 9)

                RoundedRectangle(cornerRadius: 27)
                    .fill(Style.coral)
                    .frame(width: 129, height: 154)
                    .rotationEffect(.degrees(-9))
                    .offset(x: 22, y: 2)

                RoundedRectangle(cornerRadius: 27)
                    .fill(Style.background)
                    .frame(width: 129, height: 154)
                    .overlay {
                        RoundedRectangle(cornerRadius: 27)
                            .stroke(Style.teal, lineWidth: 3.5)
                    }
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 62, weight: .heavy))
                            .foregroundStyle(Style.teal)
                    }
                    .rotationEffect(.degrees(-9))

                Sparkle(color: Style.coral, length: 14)
                    .frame(width: 30, height: 30)
                    .position(x: 67, y: 61)

                Sparkle(color: Style.teal, length: 20)
                    .frame(width: 42, height: 42)
                    .position(x: geometry.size.width - 67, y: 174)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct VocabularyEntry: Identifiable {
    let id: UUID
    let word: String
    let meaning: String
    let collection: String
    let imageColor: Color
    let tagColor: Color
    let tagInk: Color
    let selected: Bool
    let hasAudio: Bool

    var record: WordRecord { WordRecord(id: id, word: word, meaning: meaning) }


}

private struct VocabularyScreen: View {
    @ObservedObject var store: VocabularyStore
    let onNavigate: (ScreenRoute) -> Void
    let onAddContent: () -> Void
    let onSelectTab: (AppTab) -> Void
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var collectionFilter: String? = nil
    @State private var statusFilter = "All"
    @State private var sort = "Alphabetical"
    @State private var activeDropdown: String?
    @State private var showCollectionChooser = false
    @State private var confirmDelete = false

    private var displayed: [WordRecord] {
        let filtered = store.words.filter { word in
            (searchText.isEmpty || word.word.localizedCaseInsensitiveContains(searchText) || word.meaning.localizedCaseInsensitiveContains(searchText)) &&
            (collectionFilter == nil || word.collectionIDs.contains(collectionFilter!)) &&
            (statusFilter == "All" || (statusFilter == "Due" && word.isDue) || (statusFilter == "Learning" && word.status != .new && word.status != .mastered) || (statusFilter == "Recently Reviewed" && word.isRecent))
        }
        var seenHeadwords = Set<String>()
        let grouped = filtered.filter { seenHeadwords.insert(VocabularyHierarchy.spellingKey($0.word)).inserted }
        switch sort {
        case "Date added": return grouped.sorted { $0.createdAt > $1.createdAt }
        case "Last reviewed": return grouped.sorted { ($0.lastReviewed ?? .distantPast) > ($1.lastReviewed ?? .distantPast) }
        default: return grouped.sorted { $0.word.localizedCompare($1.word) == .orderedAscending }
        }
    }

    private func entry(_ word: WordRecord) -> VocabularyEntry {
        VocabularyEntry(id: word.id, word: word.word, meaning: word.meaning,
                        collection: word.collectionIDs.first.map(store.collectionTitle) ?? "Unsorted",
                        imageColor: Style.peach, tagColor: Style.paleYellow, tagInk: Style.teal,
                        selected: selectedIDs.contains(word.id), hasAudio: word.audioFile != nil)
    }

    var body: some View {
        let visibleWords = displayed
        VStack(spacing: 0) {
            AppHeader(onAdd: onAddContent, addAccessibilityLabel: "Add content")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    title

                    if isSelecting {
                        selectionActions
                            .padding(.top, 27)
                    } else {
                        Text("Build your vocabulary, one word at a time.")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                            .padding(.top, 2)

                        searchField
                            .padding(.top, 20)
                        filters
                            .padding(.top, 19)
                        sortRow(wordCount: visibleWords.count)
                            .padding(.top, 13)
                    }

                    LazyVStack(spacing: 10) {
                        ForEach(visibleWords) { word in
                            let entry = entry(word)
                            if isSelecting {
                                Button { if !selectedIDs.insert(word.id).inserted { selectedIDs.remove(word.id) } } label: { VocabularyCard(entry: entry, isSelecting: true) }.buttonStyle(.plain)
                            } else {
                                Button {
                                    onNavigate(.wordDetails(word))
                                } label: {
                                    VocabularyCard(entry: entry, isSelecting: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, isSelecting ? 20 : 12)

                    if !isSelecting && !store.sentences.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("Saved sentences")
                                .font(Style.heading(24))
                                .foregroundStyle(Style.ink)
                            ForEach(store.sentences.filter { searchText.isEmpty || $0.kweyol.localizedCaseInsensitiveContains(searchText) || $0.english.localizedCaseInsensitiveContains(searchText) }.sorted { $0.createdAt > $1.createdAt }) { sentence in
                                Button { onNavigate(.sentenceDetails(sentence.id)) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "text.quote")
                                            .font(.system(size: 23, weight: .bold))
                                            .foregroundStyle(Style.purpleInk)
                                            .frame(width: 55, height: 55)
                                            .background(Style.lavender, in: RoundedRectangle(cornerRadius: 15))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(sentence.kweyol).font(Style.heading(17)).foregroundStyle(Style.ink).lineLimit(1)
                                            Text(sentence.english).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(Style.teal)
                                    }
                                    .padding(12)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Style.ink.opacity(0.08)))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 25)
                    }
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 23)
            }

            BottomNavigation(selected: .library, onSelect: onSelectTab)
        }
        .background(Style.background)
        .confirmationDialog("Delete selected words?", isPresented: $confirmDelete) {
            Button("Delete \(selectedIDs.count) words", role: .destructive) {
                selectedIDs.compactMap(store.word).forEach(store.deleteHeadword)
                selectedIDs.removeAll()
                isSelecting = false
            }
        }
        .confirmationDialog("Add to collection", isPresented: $showCollectionChooser) {
            ForEach(store.collections) { collection in
                Button(collection.title) {
                    for id in selectedIDs {
                        if let headword = store.word(id) {
                            for var sense in store.senses(for: headword) where !sense.collectionIDs.contains(collection.id) {
                                sense.collectionIDs.append(collection.id); store.upsert(sense)
                            }
                        }
                    }
                    selectedIDs.removeAll(); isSelecting = false
                }
            }
        }
    }

    private var title: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Vocabulary")
                    .foregroundStyle(Style.ink)
                Text(".")
                    .foregroundStyle(Style.coral)
            }
            .font(Style.heading(48))
            .tracking(-2.2)
            .minimumScaleFactor(0.8)
            .lineLimit(1)

            Spacer(minLength: 0)

            if isSelecting {
                Button { isSelecting = false } label: {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.ink)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(Color(red: 0.90, green: 0.96, blue: 0.95), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 5)
    }

    private var searchField: some View {
        HStack(spacing: 19) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Style.ink)
            TextField("Search Kwéyòl or English", text: $searchText)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(Style.quiet)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 61)
        .background(.white, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Style.ink.opacity(0.10), lineWidth: 1.5))
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button { activeDropdown = activeDropdown == "collections" ? nil : "collections" } label: {
                    filterPill(collectionFilter.map(store.collectionTitle) ?? "All Collections", width: 145, fill: Style.teal, ink: .white, chevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter by collection")
                .accessibilityValue(collectionFilter.map(store.collectionTitle) ?? "All Collections")
                Button { statusFilter = statusFilter == "Due" ? "All" : "Due" } label: { filterPill("Due", width: 55, fill: Color(red: 1, green: 0.89, blue: 0.85), ink: Color(red: 0.75, green: 0.36, blue: 0.28)) }.buttonStyle(.plain)
                Button { statusFilter = statusFilter == "Learning" ? "All" : "Learning" } label: { filterPill("Learning", width: 78, fill: Color(red: 1, green: 0.92, blue: 0.66), ink: Style.teal) }.buttonStyle(.plain)
                Button { statusFilter = statusFilter == "Recently Reviewed" ? "All" : "Recently Reviewed" } label: { filterPill("Recently Reviewed", width: 131, fill: Color(red: 0.91, green: 0.87, blue: 1), ink: Style.purpleInk) }.buttonStyle(.plain)
            }
            if activeDropdown == "collections" {
                DropdownOptionsCard(
                    options: [DropdownChoice(id: "", title: "All Collections")] + store.collections.map { DropdownChoice(id: $0.id, title: $0.title) },
                    selectedID: collectionFilter ?? ""
                ) { choice in
                    collectionFilter = choice.isEmpty ? nil : choice
                    activeDropdown = nil
                }
                .frame(width: 240)
            }
        }
    }

    private func filterPill(_ label: String, width: CGFloat, fill: Color, ink: Color, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(ink)
        .frame(width: width, height: 46)
        .background(fill, in: RoundedRectangle(cornerRadius: 17))
    }

    private func sortRow(wordCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { activeDropdown = activeDropdown == "sort" ? nil : "sort" } label: {
                    HStack(spacing: 5) {
                        Text("Sort:").foregroundStyle(Style.quiet)
                        Text(sort).foregroundStyle(Style.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Style.ink)
                            .padding(.leading, 6)
                    }
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(.horizontal, 15)
                    .frame(height: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Style.ink.opacity(0.10), lineWidth: 1.4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort words")
                .accessibilityValue(sort)
                Spacer()
                Text(wordCountLabel(wordCount))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.quiet)
                Button { isSelecting = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Style.teal)
                        .frame(width: 47, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select words")
            }
            if activeDropdown == "sort" {
                DropdownOptionsCard(
                    options: ["Alphabetical", "Date added", "Last reviewed"].map { DropdownChoice(id: $0, title: $0) },
                    selectedID: sort
                ) { choice in
                    sort = choice
                    activeDropdown = nil
                }
                .frame(width: 205)
            }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(Style.heading(18))
                .foregroundStyle(Style.ink)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                Text("Add to collection")
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(Style.purpleInk)
            .padding(.horizontal, 12)
            .frame(height: 49)
            .background(Color(red: 0.91, green: 0.87, blue: 1), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle()).onTapGesture { showCollectionChooser = true }
            HStack(spacing: 7) {
                Image(systemName: "trash.fill")
                Text("Delete")
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.90, green: 0.31, blue: 0.27))
            .padding(.horizontal, 12)
            .frame(height: 49)
            .background(Color(red: 1, green: 0.88, blue: 0.85), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle()).onTapGesture { if !selectedIDs.isEmpty { confirmDelete = true } }
        }
        .padding(.horizontal, 16)
        .frame(height: 78)
        .background(Color(red: 0.88, green: 0.95, blue: 0.94), in: RoundedRectangle(cornerRadius: 20))
    }

}

private struct VocabularyCard: View {
    let entry: VocabularyEntry
    let isSelecting: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isSelecting {
                ZStack {
                    Circle()
                        .fill(entry.selected ? Style.teal : .clear)
                    Circle()
                        .stroke(entry.selected ? Style.teal : Style.ink.opacity(0.58), lineWidth: 1.7)
                    if entry.selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
            }

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 17)
                    .fill(entry.imageColor)
                    .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.word)
                        .font(Style.heading(23))
                        .foregroundStyle(Style.ink)
                    Text(entry.meaning)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.36, green: 0.44, blue: 0.54))
                    Text(entry.collection)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.tagInk)
                        .padding(.horizontal, 15)
                        .frame(height: 27)
                        .background(entry.tagColor, in: Capsule())
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if entry.hasAudio { Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Style.teal)
                    .frame(width: 43, height: 43)
                    .background(Color(red: 0.90, green: 0.96, blue: 0.95), in: Circle()) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Style.ink)
                    .padding(.leading, 5)
            }
            .padding(.horizontal, 10)
            .frame(height: 98)
            .background(.white, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.07), lineWidth: 1))
        }
    }
}

private struct CollectionsScreen: View {
    let collections: [CollectionExample]
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void
    let onSave: (CollectionExample) -> Void
    @State private var showNewSheet = false
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                AppHeader(onAdd: { showNewSheet = true }, addAccessibilityLabel: "New collection")

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        CollectionTitle(title: "Collections")
                        Text("Organize your words your way.")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.35, green: 0.45, blue: 0.55))
                            .padding(.top, 1)

                        CollectionSearchField(placeholder: "Search collections...", text: $searchText)
                            .padding(.top, 31)

                        VStack(spacing: 10) {
                            ForEach(collections.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }) { collection in
                                CollectionBrowseCard(collection: collection) {
                                    if collection.id == "all words" {
                                        onSelectTab(.library)
                                    } else {
                                        onNavigate(.collection(collection.id))
                                    }
                                }
                            }
                        }
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                    }
                    .padding(.horizontal, 23)
                }

                BottomNavigation(selected: .collections, onSelect: onSelectTab)
            }
            .background(Style.background)

            if showNewSheet {
                Color.black.opacity(0.48).ignoresSafeArea()
                CollectionEditorSheet(collection: nil, onClose: { showNewSheet = false }, onSave: onSave)
            }
        }
    }

}

private struct CollectionExample: Identifiable {
    let id: String
    let title: String
    let description: String
    let count: Int
    let icon: String
    let fill: Color
    let ink: Color
    let reviewColor: Color?
    init(id: String, title: String, description: String, count: Int, icon: String, fill: Color, ink: Color, reviewColor: Color?) {
        self.id = id; self.title = title; self.description = description; self.count = count
        self.icon = icon; self.fill = fill; self.ink = ink; self.reviewColor = reviewColor
    }

    private static let palette: [(Color, Color)] = [
        (Color(red: 1, green: 0.84, blue: 0.83), Style.coral),
        (Color(red: 1, green: 0.92, blue: 0.67), Color(red: 1, green: 0.55, blue: 0.06)),
        (Color(red: 0.78, green: 0.94, blue: 0.85), Style.teal),
        (Color(red: 0.78, green: 0.90, blue: 1), Color(red: 0.06, green: 0.43, blue: 0.83)),
        (Color(red: 0.90, green: 0.83, blue: 1), Style.purpleInk),
        (Color(red: 1, green: 0.85, blue: 0.94), Color(red: 0.63, green: 0.27, blue: 0.49)),
        (Color(red: 0.76, green: 0.94, blue: 0.86), Style.teal)
    ]
    init(saved: SavedCollection, count: Int) {
        id = saved.id; title = saved.title; description = saved.description; self.count = count; icon = saved.icon
        let pair = Self.palette[max(0, min(saved.colorIndex, Self.palette.count - 1))]
        fill = pair.0; ink = pair.1; reviewColor = nil
    }
    var saved: SavedCollection {
        SavedCollection(id: id, title: title, description: description, icon: icon,
                        colorIndex: Self.palette.firstIndex { $0.0 == fill } ?? 0)
    }

    static func named(_ name: String) -> CollectionExample {
        .init(id: name, title: name, description: "", count: 0, icon: "folder.fill", fill: Style.mint, ink: Style.teal, reviewColor: nil)
    }

}

private struct CollectionTitle: View {
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title).foregroundStyle(Style.ink)
            Text(".").foregroundStyle(Style.coral)
        }
        .font(Style.heading(48))
        .tracking(-2.3)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.top, 5)
    }
}

private struct CollectionBrowseCard: View {
    let collection: CollectionExample
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 17)
                    .fill(collection.fill)
                    .frame(width: 74, height: 74)
                    .overlay {
                        Image(systemName: collection.icon)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(collection.ink)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title)
                    .font(Style.heading(22))
                        .foregroundStyle(Style.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(wordCountLabel(collection.count))
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.38, green: 0.46, blue: 0.56))
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(Style.ink)
                    .frame(width: 24)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Style.ink)
                    .frame(width: 17)
            }
            .padding(.horizontal, 10)
            .frame(height: 91)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Style.ink.opacity(0.05), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

private struct CollectionSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 17) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Style.ink)
            TextField(placeholder, text: $text)
                .font(.system(size: 17, design: .rounded))
                .foregroundStyle(Color(red: 0.59, green: 0.64, blue: 0.70))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 57)
        .background(.white, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Style.ink.opacity(0.08), lineWidth: 1.5))
    }
}

private struct CollectionPalm: View {
    var body: some View {
        ZStack {
            Capsule()
                .fill(Color(red: 0.80, green: 0.55, blue: 0.29))
                .frame(width: 14, height: 145)
                .rotationEffect(.degrees(-24))
                .offset(x: 48, y: 64)
            ForEach(0..<6, id: \.self) { index in
                Ellipse()
                    .fill(index.isMultiple(of: 2) ? Color(red: 0.18, green: 0.61, blue: 0.35) : Color(red: 0.31, green: 0.70, blue: 0.36))
                    .frame(width: 91, height: 30)
                    .offset(x: 45, y: 0)
                    .rotationEffect(.degrees(Double(index) * 52 - 105), anchor: .leading)
            }
        }
    }
}

private struct CollectionFlower: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Ellipse()
                    .fill(color)
                    .frame(width: 19, height: 32)
                    .offset(y: -13)
                    .rotationEffect(.degrees(Double(index) * 72))
            }
            Circle().fill(Style.yellow).frame(width: 14, height: 14)
        }
    }
}

private struct CollectionWord: Identifiable {
    let word: String
    let meaning: String
    let fill: Color
    let essentials: Bool

    var id: String { word }


}

private struct CollectionDetailScreen: View {
    let name: String
    let collection: CollectionExample
    let words: [WordRecord]
    @ObservedObject var store: VocabularyStore
    let onBack: () -> Void
    let onNavigate: (ScreenRoute) -> Void
    let onSave: (CollectionExample) -> Void
    let onSelectTab: (AppTab) -> Void
    let onShowVocabulary: () -> Void
    @State private var showEditor = false
    @State private var showAddWords = false
    @State private var showRemoveWords = false
    @State private var selectedWordIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var sort = "Alphabetical"
    @State private var showSortDropdown = false

    private var displayedWords: [WordRecord] {
        let filtered = words.filter { searchText.isEmpty || $0.word.localizedCaseInsensitiveContains(searchText) || $0.meaning.localizedCaseInsensitiveContains(searchText) }
        var seenHeadwords = Set<String>()
        let grouped = filtered.filter { seenHeadwords.insert(VocabularyHierarchy.spellingKey($0.word)).inserted }
        return sort == "Date added" ? grouped.sorted { $0.createdAt > $1.createdAt } : grouped.sorted { $0.word.localizedCompare($1.word) == .orderedAscending }
    }

    var body: some View {
        let visibleWords = displayedWords
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Collections")
                        }
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(red: 0.15, green: 0.44, blue: 0.86))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { showEditor = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Style.ink)
                            .frame(width: 47, height: 47)
                            .background(Color(red: 1, green: 0.90, blue: 0.87), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit collection")
                }
                .padding(.horizontal, 23)
                .padding(.top, 10)
                .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 18) {
                            RoundedRectangle(cornerRadius: 26)
                                .fill(Color.white.opacity(0.54))
                                .frame(width: 112, height: 112)
                                .overlay {
                                    Image(systemName: collection.icon)
                                        .font(.system(size: 52, weight: .semibold))
                                        .foregroundStyle(collection.ink)
                                }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(collection.title)
                                    .font(Style.heading(37))
                                    .tracking(-1.4)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundStyle(Style.ink)
                                Text(wordCountLabel(collection.count))
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.39, green: 0.47, blue: 0.58))
                            }
                            Spacer(minLength: 0)
                            Button { showEditor = true } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "pencil")
                                    Text("Edit")
                                }
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Style.ink)
                                .padding(.horizontal, 17)
                                .frame(height: 52)
                                .background(Color(red: 0.88, green: 0.97, blue: 0.95), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .frame(height: 145)
                        .background(
                            LinearGradient(colors: [Color(red: 1, green: 0.70, blue: 0.66), Color(red: 1, green: 0.80, blue: 0.70)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 31)
                        )
                        .overlay(alignment: .topTrailing) {
                            CollectionFlower(color: Style.coral)
                                .frame(width: 75, height: 75)
                                .offset(x: 10, y: -40)
                                .allowsHitTesting(false)
                        }

                        HStack(spacing: 10) {
                            Button { onNavigate(.review) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "play.fill")
                                    Text("Review this collection")
                                }
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 61)
                                .background(Style.teal, in: RoundedRectangle(cornerRadius: 19))
                            }
                            .buttonStyle(.plain)
                            .disabled(!words.contains(where: { $0.status != .new }))
                            .opacity(words.contains(where: { $0.status != .new }) ? 1 : 0.55)

                            Button { showAddWords = true } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("Add words")
                                }
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Style.ink)
                                .frame(width: 152, height: 61)
                                .background(Color(red: 0.88, green: 0.96, blue: 0.94), in: RoundedRectangle(cornerRadius: 19))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 13)

                        CollectionSearchField(placeholder: "Search words in this collection...", text: $searchText)
                            .padding(.top, 18)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Button { showSortDropdown.toggle() } label: {
                                    HStack(spacing: 4) {
                                        Text("Sort:").foregroundStyle(Style.quiet)
                                        Text(sort).foregroundStyle(Style.ink)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Style.ink)
                                            .padding(.leading, 5)
                                    }
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 13)
                                    .frame(height: 38)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Style.ink.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sort collection words")
                                .accessibilityValue(sort)
                                Spacer()
                                Text(wordCountLabel(visibleWords.count))
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(Style.quiet)
                                Button { showRemoveWords = true } label: {
                                    Image(systemName: "list.bullet")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(Style.ink)
                                        .frame(width: 45, height: 40)
                                }.buttonStyle(.plain).accessibilityLabel("Select words in collection")
                            }
                            if showSortDropdown {
                                DropdownOptionsCard(
                                    options: ["Alphabetical", "Date added"].map { DropdownChoice(id: $0, title: $0) },
                                    selectedID: sort
                                ) { choice in
                                    sort = choice
                                    showSortDropdown = false
                                }
                                .frame(width: 205)
                            }
                        }
                        .padding(.top, 11)

                        LazyVStack(spacing: 9) {
                            if visibleWords.isEmpty {
                                Text("No words in this collection yet.")
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundStyle(Style.quiet)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 100)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 21))
                            } else {
                                ForEach(visibleWords) { word in
                                    Button {
                                        onNavigate(.wordDetails(word))
                                    } label: {
                                        CollectionDetailCard(word: CollectionWord(word: word.word, meaning: word.meaning, fill: collection.fill, essentials: false), hasAudio: word.audioFile != nil)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Remove from collection") {
                                            var edited = word
                                            edited.collectionIDs.removeAll { $0 == name }
                                            store.upsert(edited)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 11)
                        .padding(.bottom, 25)
                    }
                    .padding(.horizontal, 23)
                }

                BottomNavigation(selected: .collections, onSelect: onSelectTab)
            }
            .background(Style.background)

            if showEditor {
                Color.black.opacity(0.55).ignoresSafeArea()
                CollectionEditorSheet(collection: collection, onClose: { showEditor = false }, onSave: onSave, onDelete: {
                    store.deleteCollection(name); showEditor = false; onBack()
                })
            }
        }
        .sheet(isPresented: $showAddWords) {
            NavigationStack {
                List(store.words.filter { !$0.collectionIDs.contains(name) }) { word in
                    Button {
                        var edited = word
                        if !edited.collectionIDs.contains(name) { edited.collectionIDs.append(name); store.upsert(edited) }
                    } label: { VStack(alignment: .leading) { Text(word.word); Text(word.meaning).foregroundStyle(.secondary) } }
                }
                .navigationTitle("Add words")
                .toolbar { Button("Done") { showAddWords = false } }
            }
        }
        .sheet(isPresented: $showRemoveWords) {
            NavigationStack {
                List(words) { word in
                    Button {
                        if !selectedWordIDs.insert(word.id).inserted { selectedWordIDs.remove(word.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(word.word); Text(word.meaning).foregroundStyle(.secondary) }
                            Spacer()
                            if selectedWordIDs.contains(word.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Style.teal) }
                        }
                    }.foregroundStyle(Style.ink)
                }
                .navigationTitle("Select words")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { showRemoveWords = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Remove") {
                            for id in selectedWordIDs {
                                if var word = store.word(id) { word.collectionIDs.removeAll { $0 == name }; store.upsert(word) }
                            }
                            selectedWordIDs.removeAll(); showRemoveWords = false
                        }.disabled(selectedWordIDs.isEmpty)
                    }
                }
            }
        }
    }
}

private struct CollectionDetailCard: View {
    let word: CollectionWord
    var hasAudio = false

    var body: some View {
        HStack(spacing: 15) {
            RoundedRectangle(cornerRadius: 16)
                .fill(word.fill)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 2) {
                Text(word.word)
                    .font(Style.heading(22))
                    .foregroundStyle(Style.ink)
                Text(word.meaning)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.38, green: 0.46, blue: 0.56))
            }
            Spacer(minLength: 0)
            if hasAudio { Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Style.teal)
                .frame(width: 40, height: 40)
                .background(Color(red: 0.90, green: 0.96, blue: 0.95), in: Circle()) }
            Image(systemName: "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Style.ink)
                .padding(.leading, 5)
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .bold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Style.ink)
                .padding(.leading, 6)
        }
        .padding(.horizontal, 11)
        .frame(height: 88)
        .background(.white, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.07), lineWidth: 1))
    }
}

private struct CollectionIconChoice: Identifiable {
    let symbol: String
    let label: String
    var id: String { symbol }
}

private struct CollectionIconGroup: Identifiable {
    let title: String
    let choices: [CollectionIconChoice]
    var id: String { title }

    init(_ title: String, _ choices: [(String, String)]) {
        self.title = title
        self.choices = choices.map { CollectionIconChoice(symbol: $0.0, label: $0.1) }
    }
}

private enum CollectionIconChoices {
    static let groups: [CollectionIconGroup] = [
        CollectionIconGroup("Everyday", [
            ("folder.fill", "Folder"), ("square.grid.2x2.fill", "Everyday"), ("book.closed.fill", "Books"),
            ("bookmark.fill", "Bookmarks"), ("tag.fill", "Things"), ("star.fill", "Favourites"),
            ("heart.fill", "Love"), ("flag.fill", "Important"), ("bubble.left.fill", "Phrases"),
            ("gift.fill", "Celebrations"), ("cart.fill", "Shopping"), ("house.fill", "Home")
        ]),
        CollectionIconGroup("People, feelings & body", [
            ("person.fill", "People"), ("person.2.fill", "Friends"), ("person.3.fill", "Family"),
            ("figure.child", "Children"), ("face.smiling.fill", "Emotions"), ("brain.head.profile", "Thoughts"),
            ("hand.raised.fill", "Hands"), ("hand.point.up.left.fill", "Actions"), ("eye.fill", "Eyes"),
            ("ear.fill", "Ears"), ("lungs.fill", "Body"), ("cross.case.fill", "Health")
        ]),
        CollectionIconGroup("Clothing & accessories", [
            ("tshirt.fill", "Clothing"), ("shoe.fill", "Shoes"), ("hanger", "Wardrobe"),
            ("eyeglasses", "Glasses"), ("watch.analog", "Accessories"), ("handbag.fill", "Bags"),
            ("crown.fill", "Dress up"), ("scissors", "Style")
        ]),
        CollectionIconGroup("Food & drink", [
            ("fork.knife", "Food"), ("carrot.fill", "Vegetables"), ("cup.and.saucer.fill", "Drinks"),
            ("birthday.cake.fill", "Desserts"), ("wineglass.fill", "Dining"), ("waterbottle.fill", "Water"),
            ("popcorn.fill", "Snacks"), ("takeoutbag.and.cup.and.straw.fill", "Takeaway"),
            ("refrigerator.fill", "Kitchen"), ("flame.fill", "Cooking")
        ]),
        CollectionIconGroup("Colours & descriptions", [
            ("paintpalette.fill", "Colours"), ("paintbrush.fill", "Art"), ("eyedropper", "Shades"),
            ("rainbow", "Rainbow"), ("circle.lefthalf.filled", "Contrast"), ("sparkles", "Descriptions"),
            ("lightbulb.fill", "Ideas"), ("a.circle.fill", "Adjectives")
        ]),
        CollectionIconGroup("Time, days & weather", [
            ("calendar", "Days of the week"), ("clock.fill", "Time"), ("alarm.fill", "Schedule"),
            ("hourglass", "Duration"), ("sunrise.fill", "Morning"), ("sunset.fill", "Evening"),
            ("moon.stars.fill", "Night"), ("sun.max.fill", "Daytime"), ("cloud.fill", "Clouds"),
            ("cloud.rain.fill", "Rain"), ("snowflake", "Cold weather"), ("wind", "Wind")
        ]),
        CollectionIconGroup("Animals & nature", [
            ("pawprint.fill", "Animals"), ("dog.fill", "Dogs"), ("cat.fill", "Cats"),
            ("bird.fill", "Birds"), ("fish.fill", "Fish"), ("ant.fill", "Insects"),
            ("tortoise.fill", "Tortoises"), ("hare.fill", "Hares"), ("leaf.fill", "Nature"),
            ("tree.fill", "Trees"), ("mountain.2.fill", "Mountains"), ("water.waves", "Sea")
        ]),
        CollectionIconGroup("Places & transport", [
            ("mappin.circle.fill", "Places"), ("map.fill", "Maps"), ("building.2.fill", "Buildings"),
            ("globe.americas.fill", "World"), ("airplane", "Travel"), ("car.fill", "Transport"),
            ("bus.fill", "Buses"), ("tram.fill", "Trains"), ("bicycle", "Cycling"),
            ("ferry.fill", "Boats"), ("figure.walk", "Walking"), ("suitcase.fill", "Holidays")
        ]),
        CollectionIconGroup("Learning, work & hobbies", [
            ("graduationcap.fill", "Learning"), ("pencil", "Writing"), ("text.book.closed.fill", "Reading"),
            ("briefcase.fill", "Work"), ("desktopcomputer", "Technology"), ("number.circle.fill", "Numbers"),
            ("music.note", "Music"), ("camera.fill", "Photos"), ("sportscourt.fill", "Sports"),
            ("soccerball", "Football"), ("gamecontroller.fill", "Games"), ("paintbrush.pointed.fill", "Crafts")
        ])
    ]

    static let all = groups.flatMap(\.choices)

    static func label(for symbol: String) -> String {
        all.first(where: { $0.symbol == symbol })?.label ?? "Collection icon"
    }
}

private struct CollectionEditorSheet: View {
    let collection: CollectionExample?
    let onClose: () -> Void
    let onSave: (CollectionExample) -> Void
    var onDelete: (() -> Void)? = nil

    @State private var name: String
    @State private var collectionDescription: String
    @State private var selectedIcon: String
    @State private var selectedColor = 0
    @State private var colorChanged = false
    @State private var showIconPicker = false
    @State private var confirmDelete = false
    private static let colors: [(swatch: Color, fill: Color, ink: Color)] = [
        (Style.coral, Color(red: 1, green: 0.84, blue: 0.83), Color(red: 0.99, green: 0.34, blue: 0.28)),
        (Color(red: 1, green: 0.84, blue: 0.29), Color(red: 1, green: 0.92, blue: 0.67), Color(red: 1, green: 0.55, blue: 0.06)),
        (Color(red: 0.47, green: 0.79, blue: 0.56), Color(red: 0.78, green: 0.94, blue: 0.85), Style.teal),
        (Color(red: 0.41, green: 0.68, blue: 0.99), Color(red: 0.78, green: 0.90, blue: 1), Color(red: 0.06, green: 0.43, blue: 0.83)),
        (Color(red: 0.68, green: 0.56, blue: 0.93), Color(red: 0.90, green: 0.83, blue: 1), Color(red: 0.39, green: 0.29, blue: 0.77)),
        (Color(red: 0.96, green: 0.60, blue: 0.82), Color(red: 1, green: 0.85, blue: 0.94), Color(red: 0.63, green: 0.27, blue: 0.49)),
        (Color(red: 0.61, green: 0.88, blue: 0.83), Color(red: 0.76, green: 0.94, blue: 0.86), Style.teal)
    ]

    init(collection: CollectionExample?, onClose: @escaping () -> Void, onSave: @escaping (CollectionExample) -> Void, onDelete: (() -> Void)? = nil) {
        self.collection = collection
        self.onClose = onClose
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: collection?.title ?? "")
        _collectionDescription = State(initialValue: collection?.description ?? "")
        _selectedIcon = State(initialValue: collection?.icon ?? "folder.fill")
        if let collection {
            _selectedColor = State(initialValue: Self.colors.firstIndex(where: { $0.fill == collection.fill }) ?? 0)
        }
    }

    private var title: String { collection == nil ? "New collection" : "Edit collection" }
    private var iconFill: Color { colorChanged ? Self.colors[selectedColor].fill : collection?.fill ?? Style.mint }
    private var iconInk: Color { colorChanged ? Self.colors[selectedColor].ink : collection?.ink ?? Style.teal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.63, green: 0.66, blue: 0.68))
                .frame(width: 56, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(iconFill)
                    .frame(width: 61, height: 61)
                    .overlay {
                        Image(systemName: selectedIcon)
                            .font(.system(size: 31, weight: .semibold))
                            .foregroundStyle(iconInk)
                    }
                Text(title)
                    .font(Style.heading(25))
                    .foregroundStyle(Style.ink)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Style.ink)
                        .frame(width: 43, height: 43)
                        .background(Color(red: 0.93, green: 0.94, blue: 0.95), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.top, 15)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    editorLabel("Collection name")
                        .padding(.top, 22)
                    TextField("Collection name", text: $name)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .padding(.horizontal, 17)
                        .frame(height: 55)
                        .background(.white, in: RoundedRectangle(cornerRadius: 17))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Style.ink.opacity(0.10), lineWidth: 1.5))
                        .padding(.top, 8)

                    HStack(spacing: 3) {
                        Text("Description").fontWeight(.bold)
                        Text("(optional)").fontWeight(.medium)
                    }
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(Style.ink)
                    .padding(.top, 21)
                    TextField("Describe this collection...", text: $collectionDescription, axis: .vertical)
                        .lineLimit(3...4)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .padding(17)
                        .frame(maxWidth: .infinity, minHeight: 91, alignment: .topLeading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 17))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Style.ink.opacity(0.10), lineWidth: 1.5))
                        .padding(.top, 8)
                    Text("\(collectionDescription.count)/100")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 5)

                    editorLabel("Colour")
                        .padding(.top, 18)
                    HStack(spacing: 14) {
                        ForEach(Self.colors.indices, id: \.self) { index in
                            Button {
                                selectedColor = index
                                colorChanged = true
                            } label: {
                                Circle()
                                    .fill(Self.colors[index].swatch)
                                    .frame(width: 43, height: 43)
                                    .overlay {
                                        if selectedColor == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 19, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        if selectedColor == index {
                                            Circle().stroke(Style.ink.opacity(0.6), lineWidth: 1.7).padding(-4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(index + 1)")
                            .accessibilityAddTraits(selectedColor == index ? .isSelected : [])
                        }
                    }
                    .padding(.top, 16)

                    editorLabel("Icon")
                        .padding(.top, 24)
                    HStack(spacing: 15) {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(iconFill)
                            .frame(width: 64, height: 64)
                            .overlay {
                                Image(systemName: selectedIcon)
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(iconInk)
                            }
                        Text(CollectionIconChoices.label(for: selectedIcon))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Style.ink)
                        Spacer(minLength: 0)
                        Button { showIconPicker = true } label: {
                            Text("Change")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Style.teal)
                                .padding(.horizontal, 21)
                                .frame(height: 44)
                                .background(Color(red: 0.90, green: 0.96, blue: 0.95), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Change collection icon")
                    }
                    .padding(13)
                    .background(.white, in: RoundedRectangle(cornerRadius: 19))
                    .overlay(RoundedRectangle(cornerRadius: 19).stroke(Style.ink.opacity(0.10)))
                    .padding(.top, 10)

                    if collection != nil {
                        Button { confirmDelete = true } label: { HStack(spacing: 10) {
                            Image(systemName: "trash.fill")
                            Text("Delete collection")
                        } }
                        .buttonStyle(.plain)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.94, green: 0.34, blue: 0.29))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(red: 1, green: 0.92, blue: 0.89), in: RoundedRectangle(cornerRadius: 17))
                        .padding(.top, 50)
                        Text("This will not delete the words inside this collection.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
                .padding(.bottom, 20)
            }
            .padding(.top, 4)

            Button(action: save) {
                Text(collection == nil ? "Create collection" : "Save changes")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 67)
                    .background(Style.teal, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
            .padding(.top, 12)
            .padding(.bottom, 17)
        }
        .padding(.horizontal, 23)
        .frame(width: 476, height: 730)
        .background(Style.background, in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
        .background(alignment: .bottom) {
            Style.background
                .frame(height: 65)
                .offset(y: 43)
        }
        .fullScreenCover(isPresented: $showIconPicker) {
            CollectionIconPickerScreen(selectedIcon: $selectedIcon)
        }
        .confirmationDialog("Delete this collection? The words will remain saved.", isPresented: $confirmDelete) {
            Button("Delete collection", role: .destructive) { onDelete?() }
        }
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Style.ink)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        onSave(CollectionExample(
            id: collection?.id ?? UUID().uuidString,
            title: trimmedName,
            description: String(collectionDescription.prefix(100)),
            count: collection?.count ?? 0,
            icon: selectedIcon,
            fill: iconFill,
            ink: iconInk,
            reviewColor: collection?.reviewColor
        ))
        onClose()
    }
}

private struct CollectionIconPickerScreen: View {
    @Binding var selectedIcon: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    private var visibleGroups: [CollectionIconGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CollectionIconChoices.groups }
        return CollectionIconChoices.groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(query) { return group }
            let matches = group.choices.filter { $0.label.localizedCaseInsensitiveContains(query) }
            return matches.isEmpty ? nil : CollectionIconGroup(group.title, matches.map { ($0.symbol, $0.label) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Style.teal)
                        .frame(width: 48, height: 48)
                        .background(Color(red: 0.90, green: 0.96, blue: 0.95), in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to collection editor")

                BrandLockup()
                Spacer()
            }
            .padding(.top, 12)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Choose an icon").foregroundStyle(Style.ink)
                Text(".").foregroundStyle(Style.coral)
            }
            .font(Style.heading(37))
            .tracking(-1.5)
            .padding(.top, 38)

            Text("Pick an icon for your collection.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 7)

            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Style.teal)
                TextField("Search icons or categories", text: $searchText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.ink)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 17)
            .frame(height: 54)
            .background(.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Style.ink.opacity(0.10), lineWidth: 1.5))
            .padding(.top, 22)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(visibleGroups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(Style.heading(18))
                                .foregroundStyle(Style.ink)
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(group.choices) { choice in
                                    Button {
                                        selectedIcon = choice.symbol
                                        dismiss()
                                    } label: {
                                        RoundedRectangle(cornerRadius: 19)
                                            .fill(selectedIcon == choice.symbol ? Style.teal : Color(red: 0.90, green: 0.96, blue: 0.95))
                                            .frame(height: 72)
                                            .overlay {
                                                Image(systemName: choice.symbol)
                                                    .font(.system(size: 30, weight: .semibold))
                                                    .foregroundStyle(selectedIcon == choice.symbol ? .white : Style.teal)
                                            }
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Choose \(choice.label) icon")
                                    .accessibilityAddTraits(selectedIcon == choice.symbol ? .isSelected : [])
                                }
                            }
                        }
                    }
                    if visibleGroups.isEmpty {
                        Text("No matching icons")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.top, 27)
                .padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 23)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Style.background.ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}

private struct ScreenIntro: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(Style.heading(13))
                .tracking(1.2)
                .foregroundStyle(Style.coral)
            Text(title)
                .font(Style.heading(45))
                .tracking(-2)
                .foregroundStyle(Style.ink)
            Text(subtitle)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
        }
        .padding(.top, 15)
        .padding(.bottom, 31)
    }
}

private struct ReviewItem {
    let id: UUID
    let word: String
    let meaning: String
    let pronunciation: String
    let example: String
    let translation: String
    let audioFile: String?
    let partOfSpeech: String
    let homonym: Int
    let sense: Int
    let hasMultipleMeanings: Bool
    init(_ word: WordRecord, hasMultipleMeanings: Bool = false) {
        id = word.id; self.word = word.word; meaning = word.meaning; pronunciation = word.pronunciation
        example = word.example; translation = word.translation; audioFile = word.audioFile
        partOfSpeech = word.partOfSpeech ?? ""; homonym = word.homonym; sense = word.sense
        self.hasMultipleMeanings = hasMultipleMeanings
    }
}

private enum SessionWordModal: Identifiable {
    case edit(UUID), record(UUID)
    var id: String {
        switch self {
        case .edit(let id): "edit-\(id)"
        case .record(let id): "record-\(id)"
        }
    }
}

private struct LearnNewWordsScreen: View {
    let items: [WordRecord]
    @ObservedObject var store: VocabularyStore
    let allowBeyondGoal: Bool
    let onClose: () -> Void
    let onAddContent: () -> Void
    let onSelectTab: (AppTab) -> Void
    @State private var batchIDs: [UUID]
    @State private var phase: LearnSessionPhase = .overview
    @State private var introductionIndex = 0
    @State private var introductionChoices: [UUID: Bool] = [:]
    @State private var postponedIDs = Set<UUID>()
    @State private var practiceQueue: [UUID] = []
    @State private var completedIDs = Set<UUID>()
    @State private var attempts: [UUID: Int] = [:]
    @State private var misses: [UUID: Int] = [:]
    @State private var isRevealed = false
    @State private var cardFlying = false
    @State private var modal: SessionWordModal?

    init(items: [WordRecord], store: VocabularyStore, allowBeyondGoal: Bool,
         progress: LearnSessionProgress?, onClose: @escaping () -> Void,
         onAddContent: @escaping () -> Void, onSelectTab: @escaping (AppTab) -> Void) {
        self.items = items; self.store = store; self.allowBeyondGoal = allowBeyondGoal; self.onClose = onClose
        self.onAddContent = onAddContent; self.onSelectTab = onSelectTab
        _batchIDs = State(initialValue: progress?.batchIDs ?? items.map(\.id))
        _phase = State(initialValue: progress?.phase ?? .overview)
        _introductionIndex = State(initialValue: progress?.introductionIndex ?? 0)
        _introductionChoices = State(initialValue: progress?.introductionChoices ?? [:])
        _postponedIDs = State(initialValue: progress?.postponedIDs ?? [])
        _practiceQueue = State(initialValue: progress?.practiceQueue ?? [])
        _completedIDs = State(initialValue: progress?.completedIDs ?? [])
        _attempts = State(initialValue: progress?.attempts ?? [:])
        _misses = State(initialValue: progress?.misses ?? [:])
        _isRevealed = State(initialValue: progress?.isRevealed ?? false)
    }

    private var currentID: UUID? {
        switch phase {
        case .introduction: batchIDs.indices.contains(introductionIndex) ? batchIDs[introductionIndex] : nil
        case .practice: practiceQueue.first
        case .overview, .complete: nil
        }
    }
    private var current: WordRecord? { currentID.flatMap(store.word) }
    private var nextStackWord: String? {
        let id: UUID?
        switch phase {
        case .introduction:
            id = batchIDs.indices.contains(introductionIndex + 1) ? batchIDs[introductionIndex + 1] : batchIDs.first
        case .practice:
            id = practiceQueue.dropFirst().first ?? practiceQueue.first
        case .overview, .complete:
            id = nil
        }
        return id.flatMap(store.word)?.word
    }
    private var replacement: WordRecord? {
        store.eligibleNewWords.first { !batchIDs.contains($0.id) && !postponedIDs.contains($0.id) }
    }
    private var practiceTotal: Int { introductionChoices.count }
    private var totalAttempts: Int { attempts.values.reduce(0, +) }
    private var wordsWithMisses: Int { misses.values.filter { $0 > 0 }.count }

    var body: some View {
        VStack(spacing: 0) {
            if phase == .complete {
                completion
            } else {
                header
                switch phase {
                case .overview: overview
                case .introduction, .practice:
                    if let current { activeCard(current) }
                case .complete: EmptyView()
                }
            }
        }
        .background(Style.background.ignoresSafeArea())
        .fullScreenCover(item: $modal) { destination in
            switch destination {
            case .edit(let id):
                SessionWordEditor(wordID: id, store: store, onClose: { modal = nil }, onDelete: {
                    modal = nil
                    removeDeletedWord(id)
                })
            case .record(let id):
                if let word = store.word(id) {
                    RecordingScreen(word: word, onBack: { modal = nil }, onSave: { audioFile in
                        if var saved = store.word(id) { saved.audioFile = audioFile; store.upsert(saved) }
                        modal = nil
                    }, store: store)
                }
            }
        }
        .onChange(of: currentID) { _, id in
            if store.preferences.autoplay { store.playAudio(id.flatMap(store.word)?.audioFile) }
        }
    }

    private var header: some View {
        HStack {
            Button(action: closeSession) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Style.ink)
                    .frame(width: 43, height: 43)
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 3) {
                Text("Learn new words").font(Style.heading(19)).foregroundStyle(Style.ink)
                if phase == .introduction || phase == .practice {
                    Text(phase == .introduction ? "Introduction" : "Practice")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                }
            }
            Spacer()
            if phase == .introduction || phase == .practice {
                Menu {
                    if let currentID {
                        Button { modal = .edit(currentID) } label: { Label("Edit word", systemImage: "pencil") }
                        if phase == .introduction {
                            Button { showLater() } label: { Label("Show later", systemImage: "clock") }
                                .disabled(replacement == nil)
                            if replacement == nil { Text("No other new words available") }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Style.ink)
                        .frame(width: 43, height: 43)
                        .background(Style.lavender.opacity(0.65), in: Circle())
                }
            } else { Color.clear.frame(width: 43, height: 43) }
        }
        .padding(.horizontal, 17)
        .padding(.top, 7)
    }

    private var overview: some View {
        VStack(spacing: 0) {
            LearnSessionArtwork()
                .frame(width: 169, height: 150)
                .padding(.top, 96)
            Text("You'll learn \(batchIDs.count) new \(batchIDs.count == 1 ? "word" : "words").")
                .font(Style.heading(30)).foregroundStyle(Style.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 13)
            VStack(alignment: .leading, spacing: 23) {
                Label("First, see each word and decide if you already know it or want to learn it.", systemImage: "checkmark.circle.fill")
                Label("Then, practice every word until you get it right.", systemImage: "checkmark.circle.fill")
            }
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(Style.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .labelStyle(LearnOverviewLabelStyle())
            .padding(.top, 25)
            Spacer()
            sessionButton("Start session") {
                phase = .introduction
                isRevealed = false
                persistProgress()
            }
        }
        .padding(.horizontal, 27)
        .padding(.bottom, 58)
    }

    private func activeCard(_ word: WordRecord) -> some View {
        let total = phase == .introduction ? batchIDs.count : practiceTotal
        let progress = phase == .introduction ? introductionIndex : completedIDs.count
        return VStack(spacing: 0) {
            Text(phase == .introduction ? "\(introductionIndex + 1) of \(total)" : "\(progress) of \(total) learned")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 13)
            GeometryReader { geometry in
                Capsule().fill(Style.ink.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Style.teal)
                            .frame(width: max(8, geometry.size.width * CGFloat(phase == .introduction ? introductionIndex + 1 : progress) / CGFloat(max(1, total))))
                    }
            }
            .frame(height: 7)
            .padding(.horizontal, 35)
            .padding(.top, 9)
            GeometryReader { available in
                let cardHeight = max(390, available.size.height - 55)
                ScrollView(showsIndicators: false) {
                    SwipeCardStack(cardID: word.id, enabled: isRevealed, isFlying: $cardFlying,
                                   nextWord: nextStackWord, cardHeight: cardHeight,
                                   cornerRadius: 30, backColor: Style.lavender,
                                   leftHint: phase == .introduction ? "I already know" : "Got it",
                                   rightHint: phase == .introduction ? "Start learning" : "Keep showing",
                                   onLeft: { decide(left: true) }, onRight: { decide(left: false) }) {
                        LearningSessionCard(word: word, isRevealed: isRevealed,
                                            revealTitle: phase == .introduction ? "Reveal meaning" : "Reveal answer",
                                            minimumHeight: cardHeight,
                                            contentWidth: min(292, max(180, available.size.width - 98)),
                                            onReveal: { isRevealed = true; persistProgress() }, onPlay: { store.playAudio(word.audioFile) },
                                            onRecord: { modal = .record(word.id) }, showHint: store.preferences.showHint,
                                            hasMultipleMeanings: store.senses(for: word).count > 1)
                            .id("\(word.id)-\(isRevealed)")
                    }
                        .padding(.horizontal, 19)
                        .padding(.vertical, 10)
                }
            }
            HStack(spacing: 13) {
                if phase == .introduction {
                    decisionButton("I Already Know This", symbol: "arrow.left", fill: Style.mint, ink: Style.teal) { decide(left: true) }
                    decisionButton("Start Learning", symbol: "arrow.right", fill: Style.teal, ink: .white) { decide(left: false) }
                } else {
                    decisionButton("Got It", symbol: "checkmark", fill: Color(red: 0.84, green: 0.96, blue: 0.80), ink: Style.teal) { decide(left: true) }
                    decisionButton("Keep Showing", symbol: "arrow.clockwise", fill: Style.lavender, ink: Style.purpleInk) { decide(left: false) }
                }
            }
            .disabled(!isRevealed || cardFlying)
            .opacity(isRevealed && !cardFlying ? 1 : 0.55)
            .padding(.horizontal, 19)
            Text("Swipe left or right, or tap a button")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
    }

    private var completion: some View {
        SessionCompletionScreen(
            title: "Learning complete",
            subtitle: "You’ve finished this learn session!",
            headline: "\(completedIDs.count) new \(completedIDs.count == 1 ? "word" : "words") learned!",
            featuredWord: batchIDs.first(where: completedIDs.contains).flatMap(store.word)?.word
                ?? batchIDs.first.flatMap(store.word)?.word ?? "Kwéyòl",
            wordCount: completedIDs.count,
            wordLabel: "learned",
            attemptCount: totalAttempts,
            multipleAttemptCount: wordsWithMisses,
            onDone: closeSession,
            onAddContent: onAddContent,
            onSelectTab: onSelectTab
        )
    }
    private func decisionButton(_ title: String, symbol: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 23, weight: .bold))
                Text(title).font(Style.heading(17)).multilineTextAlignment(.center)
            }
            .foregroundStyle(ink).frame(maxWidth: .infinity).frame(height: 84)
            .background(fill, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
    private func sessionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Style.heading(20)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 65)
                .background(Style.teal, in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }
    private func decide(left: Bool) {
        guard isRevealed, let id = currentID else { return }
        if phase == .introduction {
            introductionChoices[id] = left
            introductionIndex += 1
            isRevealed = false
            if introductionIndex >= batchIDs.count { beginPractice() }
        } else if phase == .practice {
            attempts[id, default: 0] += 1
            if left {
                guard store.introduce(id, alreadyKnown: introductionChoices[id] == true,
                                      misses: misses[id, default: 0], allowBeyondGoal: allowBeyondGoal) else { return }
                completedIDs.insert(id)
                practiceQueue.removeFirst()
            } else {
                misses[id, default: 0] += 1
                practiceQueue.removeFirst()
                practiceQueue.append(id)
            }
            isRevealed = false
            if practiceQueue.isEmpty { phase = .complete }
            else if store.preferences.autoplay { store.playAudio(current?.audioFile) }
        }
        persistProgress()
    }
    private func beginPractice() {
        let ids = batchIDs.filter { introductionChoices[$0] != nil }
        practiceQueue = ids.count > 1 ? Array(ids.dropFirst()) + [ids[0]] : ids
        phase = practiceQueue.isEmpty ? .complete : .practice
        isRevealed = false
    }
    private func showLater() {
        guard phase == .introduction, let id = currentID, let replacement else { return }
        postponedIDs.insert(id)
        batchIDs[introductionIndex] = replacement.id
        isRevealed = false
        persistProgress()
        if store.preferences.autoplay { store.playAudio(replacement.audioFile) }
    }
    private func removeDeletedWord(_ id: UUID) {
        let wasCurrent = currentID == id
        if let index = batchIDs.firstIndex(of: id) {
            batchIDs.remove(at: index)
            if phase == .introduction && index < introductionIndex { introductionIndex -= 1 }
        }
        introductionChoices.removeValue(forKey: id)
        practiceQueue.removeAll { $0 == id }
        if phase == .introduction && introductionIndex >= batchIDs.count { beginPractice() }
        if phase == .practice && practiceQueue.isEmpty { phase = .complete }
        if wasCurrent { isRevealed = false }
        persistProgress()
    }
    private func persistProgress() {
        guard phase == .introduction || phase == .practice else {
            if phase == .complete { store.pendingLearnSession = nil }
            return
        }
        store.pendingLearnSession = LearnSessionProgress(batchIDs: batchIDs, phase: phase,
            introductionIndex: introductionIndex, introductionChoices: introductionChoices,
            postponedIDs: postponedIDs, practiceQueue: practiceQueue, completedIDs: completedIDs,
            attempts: attempts, misses: misses, isRevealed: isRevealed,
            allowBeyondGoal: allowBeyondGoal)
    }
    private func closeSession() {
        persistProgress()
        onClose()
    }
}

private struct LearnOverviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            configuration.icon
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(red: 0.19, green: 0.66, blue: 0.43))
            configuration.title
        }
    }
}

private struct LearnSessionArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Style.yellow)
                .frame(width: 111, height: 105)
                .rotationEffect(.degrees(-9))
                .offset(x: -26, y: 13)
            RoundedRectangle(cornerRadius: 22)
                .fill(Style.coral.opacity(0.55))
                .frame(width: 111, height: 105)
                .rotationEffect(.degrees(10))
                .offset(x: 10, y: 11)
            RoundedRectangle(cornerRadius: 22)
                .fill(Style.lavender)
                .frame(width: 118, height: 112)
                .rotationEffect(.degrees(7))
                .overlay {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(Color(red: 0.48, green: 0.35, blue: 0.83))
                        .rotationEffect(.degrees(7))
                }
            Image(systemName: "sparkle")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Style.yellow)
                .offset(x: 75, y: -43)
        }
        .accessibilityHidden(true)
    }
}

private struct LearnCompletionArtwork: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.70, green: 0.94, blue: 0.82))
                .frame(width: 123, height: 123)
            Image(systemName: "checkmark")
                .font(.system(size: 61, weight: .bold))
                .foregroundStyle(Style.teal)
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill([Style.yellow, Style.coral, Style.teal][index % 3])
                    .frame(width: 8, height: 27)
                    .offset(y: -79)
                    .rotationEffect(.degrees(Double(index) * 51 - 152))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SwipeCardStack<Content: View>: View {
    let cardID: UUID
    let enabled: Bool
    @Binding var isFlying: Bool
    let nextWord: String?
    let cardHeight: CGFloat?
    let cornerRadius: CGFloat
    let backColor: Color
    let leftHint: String
    let rightHint: String
    let onLeft: () -> Void
    let onRight: () -> Void
    @ViewBuilder let content: Content
    @State private var displacement: CGFloat = 0
    @State private var transitionToken = 0

    private var progress: CGFloat { min(1, abs(displacement) / 170) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backColor.opacity(0.86))
                .overlay {
                    if let nextWord {
                        Text(nextWord)
                            .font(Style.heading(48))
                            .foregroundStyle(Style.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 25)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: cardHeight)
                .scaleEffect(0.975 + 0.025 * progress)
                .offset(y: 16 * (1 - progress))
                .opacity(0.78 + 0.22 * progress)
                .accessibilityHidden(true)

            content
                .offset(x: displacement, y: -min(12, abs(displacement) * 0.05))
                .rotationEffect(.degrees(Double(displacement / 23)))
                .shadow(color: Style.ink.opacity(progress * 0.16), radius: 13, y: 6)
                .overlay(alignment: .top) {
                    if enabled && abs(displacement) > 35 && !isFlying {
                        Text(displacement < 0 ? leftHint : rightHint)
                            .font(Style.heading(15))
                            .foregroundStyle(Style.teal)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 8)
                            .background(.white, in: Capsule())
                            .padding(.top, 10)
                    }
                }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard enabled, !isFlying,
                      abs(value.translation.width) > abs(value.translation.height) * 1.15 else { return }
                displacement = value.translation.width
            }
            .onEnded { value in
                guard enabled, !isFlying else { return }
                let horizontal = value.translation.width
                guard abs(horizontal) > 80,
                      abs(horizontal) > abs(value.translation.height) * 1.15 else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { displacement = 0 }
                    return
                }
                isFlying = true
                transitionToken += 1
                let token = transitionToken
                withAnimation(.easeOut(duration: 0.24)) {
                    displacement = horizontal < 0 ? -650 : 650
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    guard token == transitionToken else { return }
                    if horizontal < 0 { onLeft() } else { onRight() }
                    withTransaction(Transaction(animation: nil)) { displacement = 0 }
                    isFlying = false
                }
            })
        .onChange(of: cardID) { _, _ in
            withTransaction(Transaction(animation: nil)) { displacement = 0 }
        }
        .onDisappear {
            transitionToken += 1
            isFlying = false
        }
    }
}

private struct LearningSessionCard: View {
    let word: WordRecord
    let isRevealed: Bool
    let revealTitle: String
    let minimumHeight: CGFloat
    let contentWidth: CGFloat
    let onReveal: () -> Void
    let onPlay: () -> Void
    let onRecord: () -> Void
    let showHint: Bool
    let hasMultipleMeanings: Bool

    var body: some View {
        Group {
            if isRevealed {
                VStack(spacing: 16) {
                    ReviewAnswerContent(item: ReviewItem(word, hasMultipleMeanings: hasMultipleMeanings), onPlay: onPlay, showHint: showHint,
                                        wordWidth: contentWidth, wordSize: 60, speakerSize: 66,
                                        exampleMinHeight: word.example.count + word.translation.count >= 70 ? 205 : 170)
                    if word.audioFile == nil { audioRecordButton }
                }
                .padding(17)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minimumHeight, alignment: .top)
            } else {
                VStack(spacing: 0) {
                    Text(word.word)
                        .font(Style.heading(66)).foregroundStyle(Style.ink)
                        .lineLimit(2).minimumScaleFactor(0.4)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 13)
                        .padding(.top, 30)
                    if hasMultipleMeanings {
                        Text((word.partOfSpeech ?? "").isEmpty ? (word.legacyUnmapped == true ? "Earlier saved meaning" : "Meaning \(word.sense) · Entry \(word.homonym)") : word.partOfSpeech ?? "")
                            .font(Style.heading(17)).foregroundStyle(Style.purpleInk)
                            .padding(.top, 7)
                        if !word.example.isEmpty {
                            Text(word.example)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Style.quiet)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 20)
                                .padding(.top, 8)
                        }
                    }
                    if word.audioFile != nil {
                        Button(action: onPlay) { ReviewSpeaker(size: 76) }.buttonStyle(.plain)
                            .padding(.top, 18)
                    } else { audioRecordButton.padding(.top, 18) }
                    Spacer(minLength: 48)
                    Button(action: onReveal) {
                        Label(revealTitle, systemImage: "eye")
                            .font(Style.heading(19)).foregroundStyle(Style.teal)
                            .frame(maxWidth: .infinity).frame(height: 62)
                            .background(.white, in: Capsule())
                            .shadow(color: Style.ink.opacity(0.13), radius: 9, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .frame(height: minimumHeight)
            }
        }
        .background(LinearGradient(colors: [Color(red: 0.94, green: 0.93, blue: 1), Color(red: 0.91, green: 0.89, blue: 0.99)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30))
    }

    private var audioRecordButton: some View {
        Button(action: onRecord) {
            Image(systemName: "mic.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Style.teal)
                .frame(width: 96, height: 96)
                .background(.white, in: Circle())
                .shadow(color: Style.teal.opacity(0.10), radius: 12, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add audio")
    }
}

private struct SessionWordEditor: View {
    let wordID: UUID
    @ObservedObject var store: VocabularyStore
    let onClose: () -> Void
    let onDelete: () -> Void
    @State private var showRecorder = false

    var body: some View {
        Group {
            if let word = store.word(wordID) {
                EditWordScreen(word: word,
                               collections: store.collections.map { CollectionExample(saved: $0, count: store.collectionWords($0.id).count) },
                               onBack: onClose, onRecord: { showRecorder = true },
                               onSave: { store.upsert($0); onClose() },
                               onAddMeaning: { _ in }, allowsAddingMeanings: false,
                               onDelete: { store.delete(wordID); onDelete() }, store: store)
                    .id(store.word(wordID)?.audioFile ?? "no-audio")
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            if let word = store.word(wordID) {
                RecordingScreen(word: word, onBack: { showRecorder = false }, onSave: { audioFile in
                    if var saved = store.word(wordID) { saved.audioFile = audioFile; store.upsert(saved) }
                    showRecorder = false
                }, store: store)
            }
        }
    }
}

private struct ReviewScreen: View {
    let items: [WordRecord]
    @ObservedObject var store: VocabularyStore
    let onClose: () -> Void
    let onComplete: () -> Void
    @State private var queue: [UUID]
    @State private var completedCount = 0
    @State private var totalCount: Int
    @State private var isRevealed = false
    @State private var showsSuccess = false
    @State private var cardFlying = false
    @State private var attemptsByID: [UUID: Int] = [:]
    @State private var missesByID: [UUID: Int] = [:]
    @State private var modal: SessionWordModal?

    init(items: [WordRecord], store: VocabularyStore, onClose: @escaping () -> Void, onComplete: @escaping () -> Void) {
        self.items = items; self.store = store; self.onClose = onClose; self.onComplete = onComplete
        _queue = State(initialValue: items.map(\.id))
        _totalCount = State(initialValue: items.count)
    }

    private var item: ReviewItem {
        let word = store.word(queue.first ?? UUID()) ?? items[0]
        return ReviewItem(word, hasMultipleMeanings: store.senses(for: word).count > 1)
    }
    private var nextStackWord: String? {
        let id = queue.dropFirst().first ?? queue.first
        return id.flatMap(store.word)?.word
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Spacer()
                Text("No words due for review")
                    .font(Style.heading(28))
                Button("Back to Today", action: onClose)
                    .font(Style.heading(18)).foregroundStyle(Style.teal)
                Spacer()
            } else {
            ZStack {
                Text("Review")
                    .font(Style.heading(24))
                    .foregroundStyle(Style.ink)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(Style.teal)
                            .frame(width: 49, height: 49)
                            .background(Color(red: 0.88, green: 0.96, blue: 0.94), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close review")
                    Spacer()
                    Menu {
                        if let id = queue.first {
                            Button { modal = .edit(id) } label: { Label("Edit word", systemImage: "pencil") }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Style.ink)
                            .frame(width: 49, height: 49)
                            .background(Style.lavender.opacity(0.7), in: Circle())
                    }
                }
            }
            .padding(.horizontal, 23)
            .padding(.top, 9)
            .overlay(alignment: .topTrailing) {
                if completedCount == 0 {
                    CollectionFlower(color: Style.coral)
                        .frame(width: 91, height: 91)
                        .offset(x: 39, y: -19)
                        .allowsHitTesting(false)
                } else if isRevealed {
                    CollectionFlower(color: Style.yellow)
                        .frame(width: 85, height: 85)
                        .offset(x: 40, y: -18)
                        .allowsHitTesting(false)
                } else {
                    CollectionPalm()
                        .frame(width: 126, height: 128)
                        .scaleEffect(x: -0.65, y: 0.65)
                        .offset(x: 25, y: 13)
                        .allowsHitTesting(false)
                }
            }

            Capsule()
                .fill(Color(red: 0.87, green: 0.91, blue: 0.92))
                .frame(width: 245, height: 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Style.teal).frame(width: 245 * CGFloat(completedCount) / CGFloat(max(1, totalCount)), height: 10)
                }
                .padding(.top, 17)

            Text("\(completedCount) of \(totalCount) reviewed")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.38, green: 0.47, blue: 0.57))
                .padding(.top, 10)

            SwipeCardStack(cardID: item.id, enabled: isRevealed, isFlying: $cardFlying,
                           nextWord: nextStackWord, cardHeight: nil, cornerRadius: 40,
                           backColor: Style.lavender, leftHint: "Got It", rightHint: "Missed It",
                           onLeft: { rate(.gotIt) }, onRight: { rate(.missedIt) }) {
                ReviewPromptCard(item: item, isRevealed: isRevealed, isYellow: completedCount == 0,
                                 onPlay: { store.playAudio(item.audioFile) }, showHint: store.preferences.showHint)
                    .id(item.id)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 23)
                .padding(.top, 20)

            if isRevealed {
                HStack(spacing: 12) {
                    ReviewOutcomeButton(title: "Got It", symbol: "checkmark", fill: Color(red: 0.84, green: 0.96, blue: 0.80), ink: Style.teal) { rate(.gotIt) }
                    ReviewOutcomeButton(title: "Missed It", symbol: "arrow.clockwise", fill: Color(red: 1, green: 0.89, blue: 0.86), ink: Color(red: 0.72, green: 0.25, blue: 0.20)) { rate(.missedIt) }
                }
                .disabled(cardFlying)
                .padding(.horizontal, 23)
                .padding(.top, 19)
                Text("Swipe left for Got It · right for Missed It")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.quiet)
                    .padding(.bottom, 15)
            } else {
                Button { isRevealed = true } label: {
                    Text("Show answer")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                        .background(Style.teal, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)
                .disabled(cardFlying)
                .padding(.horizontal, 23)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }
            }
        }
        .background(Style.background)
        .onAppear { if !items.isEmpty && store.preferences.autoplay { store.playAudio(item.audioFile) } }
        .fullScreenCover(item: $modal) { destination in
            if case .edit(let id) = destination {
                SessionWordEditor(wordID: id, store: store, onClose: { modal = nil }, onDelete: {
                    modal = nil
                    removeDeletedWord(id)
                })
            }
        }
        .overlay(alignment: .bottom) {
            if showsSuccess {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.67)
                        .ignoresSafeArea()
                    ReviewSuccessSheet(nextReview: store.word(item.id)?.nextReview) {
                        showsSuccess = false
                        advance()
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func rate(_ rating: RecallRating) {
        let id = item.id
        attemptsByID[id, default: 0] += 1
        store.lastSession.wordsWithMultipleAttempts = attemptsByID.values.filter { $0 > 1 }.count
        if rating == .missedIt { missesByID[id, default: 0] += 1 }
        store.rate(id, rating, sessionAttempts: attemptsByID[id, default: 0], sessionMisses: missesByID[id, default: 0])
        if rating == .gotIt { showsSuccess = true }
        else { advance(completed: false) }
    }
    private func advance(completed: Bool = true) {
        guard !queue.isEmpty else { onComplete(); return }
        let id = queue.removeFirst()
        if completed {
            completedCount += 1
            store.lastSession.completedWords = completedCount
        }
        else { queue.append(id) }
        if queue.isEmpty {
            onComplete()
            return
        }
        isRevealed = false
        if store.preferences.autoplay { store.playAudio(item.audioFile) }
    }
    private func removeDeletedWord(_ id: UUID) {
        let wasCurrent = queue.first == id
        queue.removeAll { $0 == id }
        totalCount = max(completedCount, totalCount - 1)
        if queue.isEmpty { onComplete() }
        else if wasCurrent {
            isRevealed = false
            if store.preferences.autoplay { store.playAudio(item.audioFile) }
        }
    }
}

private struct ReviewOutcomeButton: View {
    let title: String
    let symbol: String
    let fill: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 25, weight: .bold))
                Text(title).font(Style.heading(19))
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .frame(height: 105)
            .background(fill, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Style.ink.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct ReviewCompleteScreen: View {
    let result: SessionResult
    let onSession: () -> Void
    let onHome: () -> Void
    let onAddContent: () -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        SessionCompletionScreen(
            title: "Review complete",
            subtitle: "You’ve finished this review session!",
            headline: "\(result.completedWords) \(result.completedWords == 1 ? "word" : "words") reviewed!",
            featuredWord: result.featuredWord.isEmpty ? "Kwéyòl" : result.featuredWord,
            wordCount: result.completedWords,
            wordLabel: "reviewed",
            attemptCount: result.ratings.count,
            multipleAttemptCount: result.wordsWithMultipleAttempts,
            onDone: onHome,
            onAddContent: onAddContent,
            onSelectTab: onSelectTab,
            onCard: onSession
        )
    }
}

private struct SessionCompletionScreen: View {
    let title: String
    let subtitle: String
    let headline: String
    let featuredWord: String
    let wordCount: Int
    let wordLabel: String
    let attemptCount: Int
    let multipleAttemptCount: Int
    let onDone: () -> Void
    let onAddContent: () -> Void
    let onSelectTab: (AppTab) -> Void
    var onCard: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(onAdd: onAddContent, addAccessibilityLabel: "Add content", bottomPadding: 0)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(title).foregroundStyle(Style.ink)
                        Text(".").foregroundStyle(Style.coral)
                    }
                    .font(Style.heading(43))
                    .tracking(-1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 23)

                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                        .padding(.top, 7)

                    summaryCard
                        .padding(.top, 28)

                    VStack(spacing: 11) {
                        statRow("\(wordCount) \(wordCount == 1 ? "word" : "words") \(wordLabel)",
                                symbol: "book.closed.fill", tint: Style.teal,
                                iconFill: Color(red: 0.77, green: 0.92, blue: 0.87),
                                fill: Color(red: 0.89, green: 0.97, blue: 0.93))
                        statRow("\(attemptCount) total practice \(attemptCount == 1 ? "attempt" : "attempts")",
                                symbol: "arrow.triangle.2.circlepath", tint: Style.purpleInk,
                                iconFill: Color(red: 0.87, green: 0.82, blue: 0.99),
                                fill: Color(red: 0.94, green: 0.91, blue: 1))
                        statRow("\(multipleAttemptCount) \(multipleAttemptCount == 1 ? "word" : "words") needed multiple attempts",
                                symbol: "chart.bar.fill", tint: Color(red: 0.79, green: 0.45, blue: 0.06),
                                iconFill: Color(red: 1, green: 0.90, blue: 0.71),
                                fill: Color(red: 1, green: 0.96, blue: 0.85))
                    }
                    .padding(.top, 22)
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 20)
            }

            Button(action: onDone) {
                Text("Done")
                    .font(Style.heading(20))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 61)
                    .background(Style.teal, in: RoundedRectangle(cornerRadius: 19))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 23)
            .padding(.top, 9)
            .padding(.bottom, 18)

            BottomNavigation(selected: .today, onSelect: onSelectTab)
        }
        .background(Style.background)
    }

    @ViewBuilder private var summaryCard: some View {
        if let onCard {
            Button(action: onCard) { cardArtwork }
                .buttonStyle(.plain)
                .accessibilityLabel("\(headline) View your session")
        } else {
            cardArtwork
        }
    }

    private var cardArtwork: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Style.yellow).frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Style.ink)
            }
            .frame(width: 74)

            Text(headline)
                .font(Style.heading(25))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.62)
                .frame(maxWidth: .infinity, alignment: .leading)

            WordCardIllustration(word: featuredWord)
                .scaleEffect(0.82)
                .frame(width: 107, height: 125)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity)
        .frame(height: 174)
        .background(Style.teal, in: RoundedRectangle(cornerRadius: 29))
        .overlay(alignment: .topTrailing) {
            Sparkle(color: Style.yellow, length: 24)
                .frame(width: 35, height: 35)
                .offset(x: -117, y: 21)
                .allowsHitTesting(false)
        }
    }

    private func statRow(_ title: String, symbol: String, tint: Color, iconFill: Color, fill: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(iconFill, in: RoundedRectangle(cornerRadius: 17))
            Text(title)
                .font(Style.heading(17))
                .foregroundStyle(Style.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 21))
    }
}

private struct ReviewSessionScreen: View {
    let result: SessionResult
    let dueCount: Int
    let onBack: () -> Void
    let onReviewAgain: () -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReviewSummaryHeader(onBack: onBack, accent: Style.coral)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ReviewSummaryTitle(title: "Your session", subtitle: "Here’s a closer look at today’s review.")

                    HStack(spacing: 16) {
                        ReviewSummaryIcon(name: "calendar", tint: Color(red: 0.45, green: 0.31, blue: 0.86))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(wordCountLabel(result.completedWords)) reviewed")
                                .font(Style.heading(17))
                                .foregroundStyle(Style.ink)
                            Text("\(result.ratings.count) review \(result.ratings.count == 1 ? "attempt" : "attempts")")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Style.quiet)
                            Text("from \(result.collectionCount) collections")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.45, green: 0.54, blue: 0.62))
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(result.date.formatted(date: .abbreviated, time: .omitted))
                            Text(result.date.formatted(date: .omitted, time: .shortened))
                        }
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.58, green: 0.61, blue: 0.66))
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 83)
                    .background(Color(red: 0.95, green: 0.94, blue: 1), in: RoundedRectangle(cornerRadius: 22))
                    .padding(.top, 23)

                    Text("Results")
                .font(Style.heading(21))
                        .foregroundStyle(Style.ink)
                        .padding(.top, 20)
                        .padding(.bottom, 10)

                    VStack(spacing: 6) {
                        ReviewResultRow(name: "Got It", count: result.count(.gotIt), totalAttempts: result.ratings.count, mood: .smile, color: Color(red: 0.10, green: 0.73, blue: 0.52))
                        ReviewResultRow(name: "Missed It", count: result.count(.missedIt), totalAttempts: result.ratings.count, mood: .sad, color: Color(red: 1, green: 0.39, blue: 0.32))
                    }

                    Text("What’s next?")
                .font(Style.heading(21))
                        .foregroundStyle(Style.ink)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                    Button(action: onReviewAgain) {
                        ReviewNextCard(icon: "calendar", title: wordCountLabel(dueCount), subtitle: "still due for review", tint: Color(red: 1, green: 0.67, blue: 0.03), background: Color(red: 1, green: 0.96, blue: 0.85), showsChevron: true)
                    }
                    .buttonStyle(.plain)

                    ReviewNextCard(icon: "clock", title: "Next review", subtitle: "Based on your recall, words\nwill appear when due.", tint: Color(red: 0.44, green: 0.30, blue: 0.86), background: Color(red: 0.94, green: 0.91, blue: 1), showsChevron: false)
                        .padding(.top, 11)
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 24)
            }

            ReviewSummaryFooter(onReviewAgain: onReviewAgain, onHome: onHome)
        }
        .background(Style.background)
    }
}

private struct ReviewSummaryHeader: View {
    let onBack: (() -> Void)?
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Style.teal)
                        .frame(width: 48, height: 48)
                        .background(Color(red: 0.88, green: 0.97, blue: 0.96), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to review complete")
            }
            BrandLockup()
            Spacer()
        }
        .frame(height: 69)
        .padding(.horizontal, 23)
        .overlay(alignment: .topTrailing) {
            ReviewLeaves(color: accent)
                .frame(width: 105, height: 105)
                .rotationEffect(.degrees(115))
                .offset(x: onBack == nil ? 98 : 66, y: onBack == nil ? -42 : -27)
                .allowsHitTesting(false)
        }
    }
}

private struct ReviewSummaryTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .foregroundStyle(Style.ink)
                Text(".")
                    .foregroundStyle(Style.coral)
            }
            .font(Style.heading(43))
            .tracking(-1.8)
            .lineLimit(1)
            .minimumScaleFactor(0.78)

            Text(subtitle)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.39, green: 0.45, blue: 0.49))
        }
        .padding(.top, 11)
    }
}

private struct ReviewCompletionArt: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.87, green: 0.97, blue: 0.92))
                .frame(width: 139, height: 139)
            ReviewLeaves(color: Color(red: 0.10, green: 0.67, blue: 0.61))
                .frame(width: 135, height: 136)
                .rotationEffect(.degrees(-39))
                .offset(x: -63, y: 28)
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(red: 1, green: 0.88, blue: 0.45))
                .frame(width: 102, height: 102)
                .rotationEffect(.degrees(-10))
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 59, weight: .bold))
                        .foregroundStyle(Color(red: 0.10, green: 0.72, blue: 0.53))
                }
                .offset(x: 10, y: 5)
            Capsule()
                .fill(Style.coral)
                .frame(width: 7, height: 31)
                .offset(x: 16, y: -77)
            Capsule()
                .fill(Color(red: 1, green: 0.74, blue: 0.34))
                .frame(width: 7, height: 23)
                .rotationEffect(.degrees(48))
                .offset(x: 49, y: -63)
        }
        .accessibilityHidden(true)
    }
}

private enum ReviewMood { case sad, smile }

private struct ReviewRatingFace: View {
    let color: Color
    let mood: ReviewMood

    var body: some View {
        GeometryReader { geometry in
            let s = geometry.size.width
            ZStack {
                Circle().fill(color)
                Circle().fill(.white).frame(width: s * 0.105, height: s * 0.105).offset(x: -s * 0.17, y: -s * 0.11)
                Circle().fill(.white).frame(width: s * 0.105, height: s * 0.105).offset(x: s * 0.17, y: -s * 0.11)
                Path { path in
                    let endY: CGFloat
                    let middleY: CGFloat
                    switch mood {
                    case .sad: endY = 0.74; middleY = 0.40
                    case .smile: endY = 0.57; middleY = 0.80
                    }
                    path.move(to: CGPoint(x: s * 0.29, y: s * endY))
                    path.addQuadCurve(to: CGPoint(x: s * 0.71, y: s * endY), control: CGPoint(x: s * 0.50, y: s * middleY))
                }
                .stroke(.white, style: StrokeStyle(lineWidth: s * 0.075, lineCap: .round))
            }
        }
    }
}

private struct ReviewRatingTile: View {
    let name: String
    let count: Int
    let color: Color
    let background: Color
    let mood: ReviewMood

    var body: some View {
        VStack(spacing: 7) {
            ReviewRatingFace(color: color, mood: mood)
                .frame(width: 38, height: 38)
            Text("\(count)")
                .font(Style.heading(33))
                .foregroundStyle(name == "Missed It" ? Color(red: 0.67, green: 0.24, blue: 0.17) : Style.teal)
            Text(name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 145)
        .background(background, in: RoundedRectangle(cornerRadius: 21))
    }
}

private struct ReviewResultRow: View {
    let name: String
    let count: Int
    let totalAttempts: Int
    let mood: ReviewMood
    let color: Color

    var body: some View {
        HStack(spacing: 13) {
            ReviewRatingFace(color: color, mood: mood)
                .frame(width: 31, height: 31)
            Text(name)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 92, alignment: .leading)
            Text("\(count)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Style.ink)
                .frame(width: 24, alignment: .trailing)
            GeometryReader { geometry in
                Capsule()
                    .fill(Color(red: 0.94, green: 0.94, blue: 0.93))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color.opacity(0.78))
                            .frame(width: geometry.size.width * CGFloat(count) / CGFloat(max(1, totalAttempts)))
                    }
            }
            .frame(height: 20)
        }
        .frame(height: 40)
    }
}

private struct ReviewSummaryIcon: View {
    let name: String
    let tint: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 54, height: 54)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ReviewNextCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let background: Color
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 15) {
            ReviewSummaryIcon(name: icon, tint: tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.heading(18))
                    .foregroundStyle(Style.ink)
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.46, green: 0.55, blue: 0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Style.ink)
            }
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, minHeight: showsChevron ? 83 : 91, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct ReviewSummaryFooter: View {
    let onReviewAgain: () -> Void
    let onHome: () -> Void

    var body: some View {
        VStack(spacing: 11) {
            Button(action: onReviewAgain) {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "play.fill")
                        .font(.system(size: 20))
                    Text("Review again")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 69)
                .background(Style.teal, in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)

            Button(action: onHome) {
                HStack(spacing: 17) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(Style.teal)
                    Text("Back to Home")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.ink)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 69)
                .background(Color(red: 0.88, green: 0.97, blue: 0.96), in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 23)
        .padding(.top, 9)
        .padding(.bottom, 18)
        .background(Style.background)
    }
}

private struct SettingsScreen: View {
    @ObservedObject var store: VocabularyStore
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void
    @State private var confirmReset = false
    @State private var showClearWords = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeader()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ReviewSummaryTitle(title: "Settings", subtitle: "Make the app work the way you learn.")
                        .padding(.bottom, 20)

                    SettingsSectionTitle(title: "Review")
                    VStack(spacing: 0) {
                        Button { store.preferences.autoplay.toggle() } label: { SettingsRow(icon: "speaker.wave.2.fill", tint: Style.coral, tile: Color(red: 1, green: 0.89, blue: 0.88), title: "Auto-play pronunciation", subtitle: "Automatically play recorded audio\nwhen showing a new word.", trailing: .enabled(store.preferences.autoplay)) }.buttonStyle(.plain)
                        SettingsDivider()
                        Button { store.preferences.showHint.toggle() } label: { SettingsRow(icon: "text.alignleft", tint: Color(red: 0.44, green: 0.28, blue: 0.91), tile: Color(red: 0.91, green: 0.87, blue: 1), title: "Show pronunciation hint", subtitle: "Show your pronunciation hint\nafter revealing the answer.", trailing: .enabled(store.preferences.showHint)) }.buttonStyle(.plain)
                        SettingsDivider()
                        Button { onNavigate(.reviewSettings) } label: {
                            SettingsRow(icon: "square.on.square.fill", tint: Color(red: 1, green: 0.69, blue: 0.02), tile: Color(red: 1, green: 0.95, blue: 0.80), title: "Standard session size", subtitle: "Set how many words to include\nin a typical review session.", trailing: .detail("\(store.preferences.sessionSize) words"))
                        }
                        .buttonStyle(.plain)
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))

                    SettingsSectionTitle(title: "Data")
                        .padding(.top, 24)
                    VStack(spacing: 0) {
                        Button { onNavigate(.importExcel) } label: {
                            SettingsRow(icon: "icloud.and.arrow.up.fill", tint: Color(red: 0.04, green: 0.61, blue: 0.51), tile: Color(red: 0.84, green: 0.98, blue: 0.94), title: "Import words", subtitle: "Add words from an Excel spreadsheet.", trailing: .chevron)
                        }
                        .buttonStyle(.plain)
                        SettingsDivider()
                        ShareLink(item: store.exportBackup()) { SettingsRow(icon: "icloud.fill", tint: Color(red: 0.42, green: 0.28, blue: 0.91), tile: Color(red: 0.91, green: 0.87, blue: 1), title: "Export / Backup", subtitle: "Save a copy of your vocabulary and\nreview progress.", trailing: .chevron) }.buttonStyle(.plain)
                        SettingsDivider()
                        Button { showClearWords = true } label: {
                            SettingsRow(icon: "trash.fill", tint: Style.coral, tile: Style.peach,
                                        title: "Clear all words", subtitle: "Delete vocabulary and choose whether\nto clear collections too.", trailing: .chevron)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))

                    SettingsSectionTitle(title: "Learning")
                        .padding(.top, 21)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            SettingsIcon(symbol: "graduationcap.fill", tint: Style.teal, tile: Style.mint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("New words per day").font(Style.heading(18)).foregroundStyle(Style.ink)
                                Text("Choose how many new words to start learning each day.")
                                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                            }
                        }
                        HStack(spacing: 9) {
                            ForEach([5, 10, 20], id: \.self) { value in
                                Button { store.preferences.newWordsPerDay = value } label: {
                                    SettingsSizeOption(value: value, selected: store.preferences.newWordsPerDay == value)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))
                    .padding(.bottom, 12)
                    Button { confirmReset = true } label: { SettingsRow(icon: "arrow.clockwise", tint: Color(red: 1, green: 0.67, blue: 0.03), tile: Color(red: 1, green: 0.94, blue: 0.77), title: "Reset review progress", subtitle: "Clear all review history. This won’t delete\nyour words or collections.", trailing: .chevron) }.buttonStyle(.plain)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 24)
            }

            BottomNavigation(selected: .settings, onSelect: onSelectTab)
        }
        .background {
            Style.background.overlay(alignment: .topTrailing) {
                SettingsPetals(color: Style.yellow)
                    .frame(width: 140, height: 140)
                    .offset(x: 58, y: 10)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog("Reset all review progress?", isPresented: $confirmReset) {
            Button("Reset progress", role: .destructive) { store.resetProgress() }
        }
        .sheet(isPresented: $showClearWords) {
            ClearVocabularySheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
    }
}

private struct ClearVocabularySheet: View {
    @ObservedObject var store: VocabularyStore
    @Environment(\.dismiss) private var dismiss
    @State private var includeCollections = false
    @State private var confirmClear = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clear saved words")
                    .font(Style.heading(25)).foregroundStyle(Style.ink)
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(Style.heading(15)).foregroundStyle(Style.teal)
            }
            .padding(.top, 15)
            Text("This will delete \(store.displayedWords.count.formatted()) words and all their meanings, review progress, and word recordings. Saved sentences will remain.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $includeCollections) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Also clear collections")
                        .font(Style.heading(17)).foregroundStyle(Style.ink)
                    Text(includeCollections ? "All \(store.collections.count) collections will be deleted." : "Empty collections will stay in your library.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                }
            }
            .tint(Style.coral)
            .padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.coral)
            }
            Spacer(minLength: 0)
            Button { confirmClear = true } label: {
                Text("Continue")
                    .font(Style.heading(17)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Style.coral, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(23)
        .background(Style.background.ignoresSafeArea())
        .alert("Clear all saved words?", isPresented: $confirmClear) {
            Button(includeCollections ? "Clear words and collections" : "Clear words", role: .destructive) {
                do {
                    try store.clearVocabulary(includeCollections: includeCollections)
                    dismiss()
                } catch {
                    errorMessage = "The data could not be cleared: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(includeCollections
                 ? "All words, meanings, and collections will be deleted. Saved sentences will remain without collection assignments. This cannot be undone."
                 : "All words and meanings will be deleted. Your empty collections and saved sentences will remain. This cannot be undone.")
        }
    }
}

private struct ReviewSettingsScreen: View {
    let selectedTab: AppTab
    @ObservedObject var store: VocabularyStore
    let onBack: () -> Void
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(isBack: true, onLeading: onBack)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ReviewSummaryTitle(title: "Review settings", subtitle: "Adjust how your review sessions work.")
                        .padding(.bottom, 22)

                    VStack(alignment: .leading, spacing: 19) {
                        HStack(alignment: .top, spacing: 16) {
                            SettingsIcon(symbol: "square.on.square.fill", tint: Color(red: 1, green: 0.69, blue: 0.02), tile: Color(red: 1, green: 0.95, blue: 0.80))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Standard session size")
                                    .font(Style.heading(18))
                                    .foregroundStyle(Style.ink)
                                Text("Choose how many words to include\nin a typical review session.")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.45, green: 0.53, blue: 0.62))
                            }
                        }
                        HStack(spacing: 9) {
                            ForEach([10, 20, 30, 50], id: \.self) { value in
                                Button { store.preferences.sessionSize = value } label: { SettingsSizeOption(value: value, selected: store.preferences.sessionSize == value) }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))

                    Button { store.setReviewNotificationsEnabled(!store.preferences.reviewNotificationsEnabled) } label: {
                        SettingsRow(icon: "bell.badge.fill", tint: Style.teal, tile: Style.mint,
                                    title: "Review notifications", subtitle: "Remind me when words are due for review.",
                                    trailing: .enabled(store.preferences.reviewNotificationsEnabled))
                    }
                    .buttonStyle(.plain)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))
                    .padding(.top, 18)

                    VStack(spacing: 0) {
                        Button { store.preferences.autoplay.toggle() } label: { SettingsRow(icon: "speaker.wave.2.fill", tint: Style.coral, tile: Color(red: 1, green: 0.89, blue: 0.88), title: "Auto-play pronunciation", subtitle: "Automatically play recorded audio\nwhen showing a new word.", trailing: .enabled(store.preferences.autoplay)) }.buttonStyle(.plain)
                        HStack(alignment: .top, spacing: 15) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 23))
                                .foregroundStyle(Style.ink)
                            Text("Only plays your recorded audio.\nText-to-speech is never used.")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.46, green: 0.54, blue: 0.64))
                            Spacer()
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.91, green: 0.96, blue: 0.98), in: RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))
                    .padding(.top, 18)

                    VStack(spacing: 0) {
                        Button { store.preferences.showHint.toggle() } label: { SettingsRow(icon: "text.alignleft", tint: Color(red: 0.44, green: 0.28, blue: 0.91), tile: Color(red: 0.91, green: 0.87, blue: 1), title: "Show pronunciation hint", subtitle: "Show your pronunciation hint\nafter revealing the answer.", trailing: .enabled(store.preferences.showHint)) }.buttonStyle(.plain)

                        VStack(spacing: 0) {
                            Button { store.preferences.showHint = true } label: { SettingsRadioChoice(title: "Show automatically", subtitle: "Show the hint as soon as you reveal the answer.", selected: store.preferences.showHint) }.buttonStyle(.plain)
                            SettingsDivider()
                            Button { store.preferences.showHint = false } label: { SettingsRadioChoice(title: "Show with a tap", subtitle: "Keep the hint hidden until you tap to show it.", selected: !store.preferences.showHint) }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 15)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Style.ink.opacity(0.09)))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Style.ink.opacity(0.07)))
                    .padding(.top, 18)
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 28)
            }

            BottomNavigation(selected: selectedTab, onSelect: onSelectTab)
        }
        .background {
            Style.background.overlay(alignment: .topTrailing) {
                SettingsPetals(color: Style.coral)
                    .frame(width: 140, height: 140)
                    .offset(x: 58, y: 10)
                    .allowsHitTesting(false)
            }
        }
        .alert("Review notifications unavailable", isPresented: Binding(get: { store.notificationError != nil }, set: { if !$0 { store.notificationError = nil } })) {
            Button("OK", role: .cancel) { store.notificationError = nil }
        } message: { Text(store.notificationError ?? "") }
    }
}

private struct SettingsHeader: View {
    let isBack: Bool
    let onLeading: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isBack {
                Button(action: onLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.05, green: 0.39, blue: 0.65))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to settings")
            }
            BrandLockup()
            Spacer()
        }
        .frame(height: 69)
        .padding(.horizontal, 23)
    }
}

private struct SettingsPetals: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Ellipse()
                    .fill(color.opacity(index.isMultiple(of: 2) ? 0.92 : 0.78))
                    .frame(width: 31, height: 76)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(index) * 72 + 16))
            }
            Circle()
                .fill(Style.background)
                .frame(width: 12, height: 12)
        }
        .accessibilityHidden(true)
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Style.heading(21))
            .foregroundStyle(Style.ink)
            .padding(.bottom, 8)
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    let tile: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 27, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 60, height: 60)
            .background(tile, in: RoundedRectangle(cornerRadius: 18))
    }
}

private enum SettingsTrailing {
    case enabled(Bool)
    case detail(String)
    case chevron
}

private struct SettingsRow: View {
    let icon: String
    let tint: Color
    let tile: Color
    let title: String
    let subtitle: String
    let trailing: SettingsTrailing

    var body: some View {
        HStack(spacing: 16) {
            SettingsIcon(symbol: icon, tint: tint, tile: tile)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Style.heading(17))
                    .foregroundStyle(Style.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.46, green: 0.54, blue: 0.63))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            switch trailing {
            case .enabled(let enabled):
                SettingsSwitch(enabled: enabled)
            case .detail(let detail):
                HStack(spacing: 10) {
                    Text(detail)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Style.ink)
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Style.ink)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 97)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SettingsSwitch: View {
    let enabled: Bool
    var body: some View {
        Capsule()
            .fill(enabled ? Color(red: 0.04, green: 0.54, blue: 0.54) : Color.gray.opacity(0.45))
            .frame(width: 50, height: 32)
            .overlay(alignment: enabled ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .padding(enabled ? .trailing : .leading, 3)
            }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Style.ink.opacity(0.09))
            .frame(height: 1)
            .padding(.horizontal, 15)
    }
}

private struct SettingsSizeOption: View {
    let value: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(Style.heading(19))
                .foregroundStyle(Style.ink)
            Text("words")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(selected ? Style.teal : Color(red: 0.45, green: 0.53, blue: 0.62))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .background(selected ? Color(red: 0.90, green: 0.98, blue: 0.97) : Color(red: 0.97, green: 0.97, blue: 0.97), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? Color(red: 0.20, green: 0.65, blue: 0.64) : .clear, lineWidth: 1.5))
    }
}

private struct SettingsRadioChoice: View {
    let title: String
    let subtitle: String
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Circle()
                .stroke(selected ? Color(red: 0.07, green: 0.60, blue: 0.59) : Color(red: 0.29, green: 0.42, blue: 0.53), lineWidth: 1.5)
                .frame(width: 29, height: 29)
                .overlay {
                    if selected {
                        Circle()
                            .fill(Color(red: 0.07, green: 0.60, blue: 0.59))
                            .frame(width: 19, height: 19)
                            .overlay(Circle().fill(.white).frame(width: 5, height: 5))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Style.heading(16))
                    .foregroundStyle(Style.ink)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.47, green: 0.55, blue: 0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 71)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReviewSuccessSheet: View {
    let nextReview: Date?
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(red: 0.85, green: 0.85, blue: 0.82))
                .frame(width: 65, height: 6)
                .padding(.top, 16)

            ZStack {
                ReviewLeaves(color: Color(red: 0.30, green: 0.74, blue: 0.68))
                    .frame(width: 130, height: 125)
                    .rotationEffect(.degrees(-65))
                    .offset(x: -171, y: 48)
                ReviewLeaves(color: Color(red: 1.00, green: 0.78, blue: 0.28))
                    .frame(width: 88, height: 105)
                    .rotationEffect(.degrees(62))
                    .offset(x: 125, y: 29)
                ReviewSuccessSprinkles()

                RoundedRectangle(cornerRadius: 27)
                    .fill(Color(red: 1.00, green: 0.89, blue: 0.45))
                    .frame(width: 119, height: 119)
                    .rotationEffect(.degrees(-8))
                    .shadow(color: Color(red: 0.90, green: 0.70, blue: 0.30).opacity(0.22), radius: 10, y: 8)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 67, weight: .bold))
                            .foregroundStyle(Color(red: 0.12, green: 0.70, blue: 0.53))
                            .rotationEffect(.degrees(-8))
                    }
            }
            .frame(height: 165)
            .padding(.top, 10)

            Text("Great job!")
                .font(Style.heading(42))
                .tracking(-1.6)
                .foregroundStyle(Style.ink)
                .padding(.top, 2)

            Text("You’ll see this word again on")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.46, green: 0.55, blue: 0.64))
                .padding(.top, 9)

            Text(nextReview?.formatted(date: .abbreviated, time: .omitted) ?? "Soon")
                .font(Style.heading(28))
                .foregroundStyle(Style.teal)
                .frame(width: 166, height: 49)
                .background(Color(red: 0.87, green: 0.97, blue: 0.92), in: Capsule())
                .padding(.top, 8)

            HStack(spacing: 16) {
                ReviewSuccessStat(icon: "calendar", title: "Last reviewed", value: "Today", date: Date().formatted(date: .abbreviated, time: .omitted))
                ReviewSuccessStat(icon: "clock", title: "Next review", value: nextReview?.formatted(date: .abbreviated, time: .omitted) ?? "Soon", date: nextReview?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .padding(.top, 21)

            Button(action: onNext) {
                HStack(spacing: 17) {
                    Text("Next word")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 74)
                .background(Style.teal, in: RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain)
            .padding(.top, 23)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Style.background, in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
        .background(alignment: .bottom) {
            Style.background.frame(height: 80).offset(y: 62)
        }
    }
}

private struct ReviewSuccessStat: View {
    let icon: String
    let title: String
    let value: String
    let date: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Color(red: 0.44, green: 0.34, blue: 0.85))
                .frame(width: 47, height: 47)
                .background(Color(red: 0.90, green: 0.85, blue: 1), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.31, green: 0.43, blue: 0.52))
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Style.ink)
                Text(date)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.48, green: 0.56, blue: 0.63))
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 91)
        .background(Color(red: 0.91, green: 0.97, blue: 0.96), in: RoundedRectangle(cornerRadius: 21))
    }
}

private struct ReviewSuccessSprinkles: View {
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill([Style.coral, Color(red: 0.71, green: 0.85, blue: 0.99), Color(red: 0.35, green: 0.75, blue: 0.72)][index])
                    .frame(width: 13, height: 32)
                    .rotationEffect(.degrees(Double(index * 37) - 43))
                    .offset(x: CGFloat(index * 28) - 110, y: CGFloat(index * 17) - 8)
            }
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill([Color(red: 0.76, green: 0.67, blue: 0.98), Color(red: 1.00, green: 0.67, blue: 0.44), Color(red: 1.00, green: 0.83, blue: 0.39)][index])
                    .frame(width: 13, height: 33)
                    .rotationEffect(.degrees(Double(index * 36) + 20))
                    .offset(x: CGFloat(index * 26) + 85, y: CGFloat(index * 17) - 23)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ReviewPromptCard: View {
    let item: ReviewItem
    let isRevealed: Bool
    let isYellow: Bool
    let onPlay: () -> Void
    let showHint: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 40)
                    .fill(
                        LinearGradient(
                            colors: isYellow && !isRevealed ? [Color(red: 1, green: 0.96, blue: 0.78), Color(red: 1, green: 0.94, blue: 0.72)] : [Color(red: 0.95, green: 0.91, blue: 1), Color(red: 0.91, green: 0.87, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if !isRevealed {
                    ReviewCardDecorations(isYellow: isYellow)
                    VStack(spacing: 0) {
                        Text(item.word)
                            .font(Style.heading(isYellow ? 124 : 113))
                            .tracking(-5)
                            .minimumScaleFactor(0.1)
                            .lineLimit(1)
                            .foregroundStyle(Style.ink)
                            .frame(width: max(1, geometry.size.width - 48))
                        if item.hasMultipleMeanings {
                            Text(item.partOfSpeech.isEmpty ? (item.homonym == 0 ? "Earlier saved meaning" : "Meaning \(item.sense) · Entry \(item.homonym)") : item.partOfSpeech)
                                .font(Style.heading(18)).foregroundStyle(Style.purpleInk)
                                .padding(.top, 8)
                            if !item.example.isEmpty {
                                Text(item.example)
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundStyle(Style.quiet)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                                    .padding(.top, 8)
                            }
                        }
                        if isYellow {
                            Capsule()
                                .fill(Color(red: 1, green: 0.82, blue: 0.32))
                                .frame(width: 150, height: 12)
                                .rotationEffect(.degrees(-5))
                                .padding(.top, 15)
                        }
                        if item.audioFile != nil {
                            Button(action: onPlay) { ReviewSpeaker(size: isYellow ? 76 : 99) }.buttonStyle(.plain)
                                .padding(.top, isYellow ? 12 : 25)
                        }
                    }
                    .offset(y: isYellow ? 3 : 17)
                } else {
                    ScrollView(showsIndicators: false) {
                        ReviewAnswerContent(item: item, onPlay: onPlay, showHint: showHint, wordWidth: max(1, geometry.size.width - 56))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 25)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 40))
        }
    }
}

private struct ReviewCardDecorations: View {
    let isYellow: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isYellow {
                    CollectionFlower(color: Color(red: 1, green: 0.56, blue: 0.32))
                        .frame(width: 97, height: 97)
                        .position(x: 76, y: 79)
                    ReviewLeaves(color: Color(red: 0.30, green: 0.66, blue: 0.47))
                        .frame(width: 130, height: 125)
                        .position(x: 48, y: geometry.size.height - 45)
                    ReviewLeaves(color: Color(red: 1, green: 0.73, blue: 0.36))
                        .frame(width: 130, height: 130)
                        .rotationEffect(.degrees(160))
                        .position(x: geometry.size.width - 32, y: geometry.size.height - 44)
                } else {
                    Ellipse()
                        .fill(Color(red: 0.84, green: 0.77, blue: 0.99).opacity(0.6))
                        .frame(width: 420, height: 135)
                        .rotationEffect(.degrees(-13))
                        .position(x: 79, y: 53)
                    ReviewLeaves(color: Color(red: 0.27, green: 0.65, blue: 0.71))
                        .frame(width: 165, height: 150)
                        .position(x: 44, y: geometry.size.height - 60)
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(Color(red: 0.53, green: 0.38, blue: 0.84))
                            .frame(width: 16, height: 40)
                            .rotationEffect(.degrees(Double(index) * 31 + 16))
                            .position(x: geometry.size.width - 68 + CGFloat(index * 18), y: 70 + CGFloat(index * 16))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ReviewLeaves: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Ellipse()
                    .fill(color.opacity(index == 1 ? 0.9 : 1))
                    .frame(width: 39, height: 112)
                    .offset(y: -28)
                    .rotationEffect(.degrees(Double(index - 1) * 51))
            }
        }
    }
}

private struct ReviewSpeaker: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Style.teal)
            .frame(width: size, height: size)
            .background(Color(red: 0.97, green: 1, blue: 0.99), in: Circle())
            .shadow(color: Style.teal.opacity(0.10), radius: 12, y: 7)
    }
}

private struct ReviewAnswerContent: View {
    let item: ReviewItem
    let onPlay: () -> Void
    let showHint: Bool
    let wordWidth: CGFloat
    var wordSize: CGFloat = 75
    var speakerSize: CGFloat = 77
    var exampleMinHeight: CGFloat = 0
    @State private var hintRevealed = false

    var body: some View {
        VStack(spacing: 7) {
            Text(item.word)
                .font(Style.heading(wordSize))
                .tracking(-3)
                .foregroundStyle(Style.ink)
                .minimumScaleFactor(0.1)
                .lineLimit(1)
                .frame(width: wordWidth)
                .padding(.top, 3)
            if item.audioFile != nil { Button(action: onPlay) { ReviewSpeaker(size: speakerSize) }.buttonStyle(.plain)
                .padding(.top, 4)
                .padding(.bottom, 12) }

            ReviewAnswerRow(icon: "book.closed.fill", iconColor: Style.coral, title: "English meaning", value: item.meaning)
            if !item.partOfSpeech.isEmpty {
                ReviewAnswerRow(icon: "text.book.closed.fill", iconColor: Style.teal, title: "Part of speech", value: item.partOfSpeech)
            }
            if !item.pronunciation.isEmpty {
                Button { hintRevealed = true } label: {
                    ReviewAnswerRow(icon: "headphones", iconColor: Color(red: 0.46, green: 0.33, blue: 0.82), title: "Pronunciation hint", value: showHint || hintRevealed ? item.pronunciation : "Tap to show")
                }.buttonStyle(.plain)
            }

            if !item.example.isEmpty || !item.translation.isEmpty { HStack(alignment: .top, spacing: 15) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 29))
                    .foregroundStyle(Style.coral)
                    .frame(width: 45)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Example sentence (Kwéyòl)")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.58))
                    Text(item.example)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.ink)
                    Text("English translation")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.58))
                        .padding(.top, 8)
                    Text(item.translation)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.58))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 19)
            .frame(minHeight: exampleMinHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.91), in: RoundedRectangle(cornerRadius: 23)) }

        }
    }
}

private struct ReviewAnswerRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 45)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.39, green: 0.49, blue: 0.58))
                Text(value)
                    .font(.system(size: value.count > 45 ? 17 : 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Style.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(minHeight: 88)
        .background(.white.opacity(0.91), in: RoundedRectangle(cornerRadius: 23))
    }
}

private enum RecordingPhase {
    case ready, recording, preview
}

private struct RecordingScreen: View {
    let word: WordRecord
    let onBack: () -> Void
    let onSave: (String) -> Void
    @ObservedObject var store: VocabularyStore
    @State private var phase: RecordingPhase = .ready
    @State private var recorder: AVAudioRecorder?
    @State private var pendingFile: String?
    @State private var duration = 0
    @State private var timer: Timer?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: cancel) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Style.teal)
                        .frame(width: 48, height: 48)
                        .background(Color(red: 0.88, green: 0.97, blue: 0.96), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                BrandLockup()
                Spacer()
            }
            .frame(height: 70)

            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: -10) {
                    Text("Record")
                        .foregroundStyle(Style.ink)
                    HStack(spacing: 0) {
                        Text("pronunciation").foregroundStyle(Style.ink)
                        Text(".").foregroundStyle(Style.coral)
                    }
                }
                .font(Style.heading(45))
                .tracking(-1.9)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

                Text(subtitle)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.48, green: 0.56, blue: 0.65))
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)

            wordCard
                .padding(.top, 26)

            Spacer(minLength: 30)

            stageContent
                .frame(height: 285)

            Spacer(minLength: 30)

            Button(action: { if phase == .preview, let pendingFile { onSave(pendingFile) } else { cancel() } }) {
                HStack(spacing: 15) {
                    if phase == .preview {
                        Image(systemName: "checkmark")
                            .font(.system(size: 23, weight: .semibold))
                    }
                    Text(phase == .preview ? "Save recording" : "Cancel")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                }
                .foregroundStyle(phase == .preview ? .white : phase == .recording ? Style.coral : Style.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .background(phase == .preview ? Style.teal : phase == .recording ? Color(red: 1, green: 0.89, blue: 0.88) : Color(red: 0.88, green: 0.97, blue: 0.96), in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 25)
        }
        .padding(.horizontal, 23)
        .background {
            Style.background.overlay(alignment: .topTrailing) {
                SettingsPetals(color: Style.yellow)
                    .frame(width: 140, height: 140)
                    .offset(x: 58, y: 10)
                    .allowsHitTesting(false)
            }
        }
        .alert("Recording unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var subtitle: String {
        switch phase {
        case .ready: "Ask a fluent speaker to say the word."
        case .recording: "Speak clearly at a natural pace."
        case .preview: "Listen to your recording and save it."
        }
    }

    private var wordCard: some View {
        HStack(spacing: 21) {
            RoundedRectangle(cornerRadius: 17)
                .fill(Color(red: 1, green: 0.82, blue: 0.82))
                .frame(width: 87, height: 87)
            VStack(alignment: .leading, spacing: 2) {
                Text(word.word)
                    .font(Style.heading(25))
                    .foregroundStyle(Style.ink)
                Text(word.meaning)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.51, blue: 0.61))
                if let collectionID = word.collectionIDs.first,
                   let collection = store.collections.first(where: { $0.id == collectionID }) {
                    Text(collection.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.coral)
                        .padding(.horizontal, 16)
                        .frame(height: 29)
                        .background(Color(red: 1, green: 0.89, blue: 0.91), in: Capsule())
                        .padding(.top, 5)
                }
            }
            Spacer()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Style.ink.opacity(0.07)))
    }

    @ViewBuilder
    private var stageContent: some View {
        switch phase {
        case .ready:
            VStack(spacing: 0) {
                Button(action: startRecording) { 
                    ZStack {
                        Circle().fill(Style.coral.opacity(0.14)).frame(width: 193, height: 193)
                        Circle().fill(Color(red: 1, green: 0.38, blue: 0.31)).frame(width: 160, height: 160)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 62, weight: .medium))
                            .foregroundStyle(.white)
                        RecordingSparks().offset(x: 95, y: -72)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tap to record")
                Text("Tap to record")
                    .font(Style.heading(21))
                    .foregroundStyle(Style.ink)
                    .padding(.top, 8)
                Text("Record a clear pronunciation\nof the word.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.48, green: 0.56, blue: 0.65))
                    .multilineTextAlignment(.center)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity)

        case .recording:
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RecordingWaveform(color: Style.coral)
                    Button(action: stopRecording) {
                        ZStack {
                            Circle().fill(Style.coral.opacity(0.08)).frame(width: 205, height: 205)
                            Circle().fill(Style.coral.opacity(0.17)).frame(width: 173, height: 173)
                            Circle().fill(Color(red: 1, green: 0.38, blue: 0.31)).frame(width: 135, height: 135)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")
                    RecordingWaveform(color: Style.coral)
                }
                Text(String(format: "%d:%02d", duration / 60, duration % 60))
                    .font(Style.heading(27))
                    .foregroundStyle(Style.ink)
                    .padding(.top, 4)
                Text("Recording...")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.48, green: 0.56, blue: 0.65))
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

        case .preview:
            VStack(spacing: 41) {
                HStack(spacing: 18) {
                    Button { store.playAudio(pendingFile) } label: { Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 77, height: 77)
                        .background(Style.teal, in: Circle()) }.buttonStyle(.plain)
                    AudioWaveform(color: Color(red: 0.65, green: 0.48, blue: 0.94))
                        .frame(maxWidth: .infinity)
                        .scaleEffect(1.4)
                    Text(String(format: "%d:%02d", duration / 60, duration % 60))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.31, green: 0.27, blue: 0.60))
                }
                .padding(.horizontal, 25)
                .frame(height: 126)
                .background(Color(red: 0.94, green: 0.92, blue: 1), in: RoundedRectangle(cornerRadius: 22))

                HStack(spacing: 13) {
                    Button(action: startRecording) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise")
                            Text("Record again")
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                        .background(Color(red: 0.88, green: 0.97, blue: 0.96), in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                    Button { discard(); phase = .ready } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Style.coral)
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                        .background(Color(red: 1, green: 0.89, blue: 0.88), in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func startRecording() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { errorMessage = "Allow microphone access in Settings to record pronunciation."; return }
                discard()
                let file = "audio-\(UUID().uuidString).m4a"
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try AVAudioSession.sharedInstance().setActive(true)
                    let recorder = try AVAudioRecorder(url: store.audioURL(file), settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ])
                    guard recorder.record() else { throw NSError(domain: "Palapata", code: 1) }
                    self.recorder = recorder
                    pendingFile = file
                    duration = 0
                    phase = .recording
                    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in duration += 1 }
                } catch { errorMessage = "Could not start recording: \(error.localizedDescription)" }
            }
        }
    }
    private func stopRecording() {
        recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        guard let pendingFile,
              let recording = try? AVAudioPlayer(contentsOf: store.audioURL(pendingFile)),
              recording.duration > 0 else {
            discard()
            phase = .ready
            errorMessage = "The recording was empty. Please try again."
            return
        }
        phase = .preview
    }
    private func discard() {
        recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        if let pendingFile { try? FileManager.default.removeItem(at: store.audioURL(pendingFile)) }
        pendingFile = nil
    }
    private func cancel() { discard(); onBack() }
}

private struct RecordingWaveform: View {
    let color: Color
    private let heights: [CGFloat] = [15, 28, 42, 59, 36, 22]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.82))
                    .frame(width: 4, height: heights[index])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecordingSparks: View {
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Style.coral.opacity(0.45))
                    .frame(width: 15, height: 40)
                    .offset(y: -32)
                    .rotationEffect(.degrees(Double(index) * 48 - 27))
            }
        }
        .accessibilityHidden(true)
    }
}

private enum ExcelImportField: String, CaseIterable {
    case kweyol = "Kwéyòl"
    case homonym = "Homonym"
    case partOfSpeech = "Part of Speech"
    case sense = "Sense"
    case english = "English"
    case pronunciation = "Pronunciation Hint"
    case exampleKweyol = "Example Kwéyòl"
    case exampleEnglish = "Example English"
    case categories = "Collections"
    case ignore = "Ignore"

    static func suggested(for header: String) -> Self {
        let name = ExcelImportLogic.key(header)
            .folding(options: [.diacriticInsensitive], locale: ExcelImportLogic.locale)
            .filter { $0.isLetter || $0.isNumber }
        if name == "homonym" || name == "homonymnumber" || name == "entry" { return .homonym }
        if name == "sense" || name == "sensenumber" || name == "meaningnumber" { return .sense }
        if name == "partofspeech" || name == "pos" || name == "wordclass" { return .partOfSpeech }
        if name.contains("pronunciation") || name.contains("phonetic") { return .pronunciation }
        if name.contains("exampleenglish") || name.contains("exampletranslation") || name == "translation" || name == "englishsentence" || (name.contains("example") && name.contains("english")) { return .exampleEnglish }
        if name.contains("examplekweyol") || name.contains("examplecreole") || name.contains("creolesentence") || name.contains("kweyolsentence") || name == "examplesentence" || (name.contains("example") && name.contains("sentence")) { return .exampleKweyol }
        if name.contains("categor") || name.contains("collection") { return .categories }
        if name.contains("kweyol") || name.contains("creoleword") || name == "creole" || name == "word" || name == "phrase" { return .kweyol }
        if name == "english" || name.contains("meaning") || name == "definition" { return .english }
        return .ignore
    }
}

private enum ExcelDuplicateAction: String, CaseIterable {
    case skip = "Skip"
    case update = "Update Existing"
    case importDuplicate = "Import as Duplicate"
}

private enum ExcelBulkDuplicateMode: String, CaseIterable {
    case addNewAndUpdateExisting = "Add New + Update Existing"
    case updateAllExisting = "Update All Existing"
    case skipAllExisting = "Skip All Existing"
    case importAllAsDuplicates = "Import All as Duplicates"

    var duplicateAction: ExcelDuplicateAction {
        switch self {
        case .addNewAndUpdateExisting, .updateAllExisting: .update
        case .skipAllExisting: .skip
        case .importAllAsDuplicates: .importDuplicate
        }
    }
}

private enum ExcelImportStep { case choose, mapping, preview, result }

private enum ExcelImportLogic {
    static let locale = Locale(identifier: "en_US_POSIX")
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: locale)
            .lowercased(with: locale)
    }
    static func categories(_ cell: String) -> [String] {
        var seen = Set<String>()
        return cell.split(separator: ";", omittingEmptySubsequences: false).compactMap { part in
            let name = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(key(name)).inserted else { return nil }
            return name
        }
    }
}

private struct ExcelCategoryPreview: Identifiable {
    let name: String
    let matchedExisting: Bool
    var id: String { ExcelImportLogic.key(name) }
}

private struct ExcelRowPreview: Identifiable {
    let rowNumber: Int
    let word: String
    let homonym: Int
    let sense: Int
    let partOfSpeech: String
    let structured: Bool
    let meaning: String
    let pronunciation: String
    let example: String
    let translation: String
    let categories: [ExcelCategoryPreview]
    let duplicate: Bool
    let error: String?
    var id: Int { rowNumber }
}

private struct ExcelImportResult {
    var created = 0
    var updated = 0
    var headwordsCreated = 0
    var entriesCreated = 0
    var additionalSensesCreated = 0
    var duplicatesCreated = 0
    var categoriesCreated = 0
    var assignmentsAdded = 0
    var duplicatesSkipped = 0
    var failures: [String] = []
}

private struct ExcelImportSummary {
    var rows = 0
    var uniqueHeadwords = 0
    var newHeadwords = 0
    var newEntries = 0
    var additionalSenses = 0
    var existing = 0
    var new = 0
    var invalid = 0
    var created = 0
    var updated = 0
    var duplicatesCreated = 0
    var skipped = 0
    var assignmentsAdded = 0
    var categoriesCreated = 0
    var existingCategoriesMatched = 0
    var totalActions: Int { created + updated }
}

private enum ExcelImportEngine {
    static func action(for row: Int, overrides: [Int: ExcelDuplicateAction], bulkMode: ExcelBulkDuplicateMode) -> ExcelDuplicateAction {
        overrides[row] ?? bulkMode.duplicateAction
    }

    static func summarize(rows: [ExcelRowPreview], overrides: [Int: ExcelDuplicateAction], bulkMode: ExcelBulkDuplicateMode,
                          existingWords: [WordRecord], existingCollections: [SavedCollection]) -> ExcelImportSummary {
        var summary = ExcelImportSummary()
        summary.rows = rows.count
        summary.uniqueHeadwords = Set(rows.filter { $0.error == nil }.map { ExcelImportLogic.key($0.word) }).count
        var senseCategories: [String: Set<String>] = [:]
        let namesByID = Dictionary(uniqueKeysWithValues: existingCollections.map { ($0.id, ExcelImportLogic.key($0.title)) })
        var headwordKeys = Set<String>()
        var entryKeys = Set<String>()
        for word in existingWords {
            let spelling = ExcelImportLogic.key(word.word)
            let key = VocabularyHierarchy.senseKey(word.word, homonym: word.homonym, sense: word.sense)
            headwordKeys.insert(spelling)
            entryKeys.insert("\(spelling)|\(word.homonym)")
            senseCategories[key] = Set(word.collectionIDs.compactMap { namesByID[$0] })
        }
        let originalCategories = Set(existingCollections.map { ExcelImportLogic.key($0.title) })
        var availableCategories = originalCategories
        var matchedCategories = Set<String>()
        for row in rows {
            guard row.error == nil else { summary.invalid += 1; continue }
            let spelling = ExcelImportLogic.key(row.word)
            let entryKey = "\(spelling)|\(row.homonym)"
            let key = VocabularyHierarchy.senseKey(row.word, homonym: row.homonym, sense: row.sense)
            let exists = row.duplicate && senseCategories[key] != nil
            if exists { summary.existing += 1 } else { summary.new += 1 }
            let action = action(for: row.rowNumber, overrides: overrides, bulkMode: bulkMode)
            if exists && action == .skip { summary.skipped += 1; continue }
            let categoryKeys = Set(row.categories.map { ExcelImportLogic.key($0.name) })
            for categoryKey in categoryKeys {
                if originalCategories.contains(categoryKey) { matchedCategories.insert(categoryKey) }
                if availableCategories.insert(categoryKey).inserted { summary.categoriesCreated += 1 }
            }
            if exists && action == .update {
                let old = senseCategories[key] ?? []
                summary.assignmentsAdded += categoryKeys.subtracting(old).count
                senseCategories[key] = old.union(categoryKeys)
                summary.updated += 1
            } else {
                summary.assignmentsAdded += categoryKeys.count
                summary.created += 1
                if exists { summary.duplicatesCreated += 1 }
                else {
                    if !headwordKeys.contains(spelling) { summary.newHeadwords += 1 }
                    else { summary.additionalSenses += 1 }
                    if !entryKeys.contains(entryKey) { summary.newEntries += 1 }
                    headwordKeys.insert(spelling)
                    entryKeys.insert(entryKey)
                    senseCategories[key] = categoryKeys
                }
            }
        }
        summary.existingCategoriesMatched = matchedCategories.count
        return summary
    }

    static func apply(rows: [ExcelRowPreview], actions: [Int: ExcelDuplicateAction], bulkMode: ExcelBulkDuplicateMode, replacements: [Int: Set<ExcelImportField>],
                      existingWords: [WordRecord], existingHeadwords: [VocabularyHeadword], existingEntries: [LexicalEntry],
                      existingCollections: [SavedCollection]) -> (words: [WordRecord], headwords: [VocabularyHeadword], entries: [LexicalEntry], collections: [SavedCollection], result: ExcelImportResult) {
        var words = existingWords
        var headwords = existingHeadwords
        var entries = existingEntries
        var collections = existingCollections
        var senseIndex: [String: Int] = [:]
        for (index, word) in words.enumerated() {
            let key = VocabularyHierarchy.senseKey(word.word, homonym: word.homonym, sense: word.sense)
            if senseIndex[key] == nil { senseIndex[key] = index }
        }
        var headwordIndex: [String: Int] = [:]
        for index in headwords.indices {
            let key = ExcelImportLogic.key(headwords[index].spelling)
            if headwordIndex[key] == nil { headwordIndex[key] = index }
        }
        var entryIndex: [String: Int] = [:]
        for index in entries.indices {
            entryIndex["\(entries[index].headwordID)|\(entries[index].homonymNumber)"] = index
        }
        var categoryIDs: [String: String] = [:]
        var categoryKeysByID: [String: String] = [:]
        for collection in collections {
            let key = ExcelImportLogic.key(collection.title)
            if categoryIDs[key] == nil { categoryIDs[key] = collection.id }
            categoryKeysByID[collection.id] = key
        }
        var result = ExcelImportResult()
        var pronunciationOverwrites = Set<UUID>()
        for row in rows {
            if let error = row.error {
                result.failures.append("Row \(row.rowNumber): \(error)")
                continue
            }
            let spellingKey = ExcelImportLogic.key(row.word)
            let key = VocabularyHierarchy.senseKey(row.word, homonym: row.homonym, sense: row.sense)
            var existingIndex = senseIndex[key]
            let action = action(for: row.rowNumber, overrides: actions, bulkMode: bulkMode)
            if row.duplicate && existingIndex != nil && action == .skip {
                result.duplicatesSkipped += 1
                continue
            }
            var assignedIDs: [String] = []
            for category in row.categories {
                let categoryKey = ExcelImportLogic.key(category.name)
                if let id = categoryIDs[categoryKey] {
                    if !assignedIDs.contains(id) { assignedIDs.append(id) }
                } else {
                    let saved = SavedCollection(title: category.name, description: "", icon: "folder.fill", colorIndex: 2)
                    collections.append(saved)
                    categoryIDs[categoryKey] = saved.id
                    categoryKeysByID[saved.id] = categoryKey
                    assignedIDs.append(saved.id)
                    result.categoriesCreated += 1
                }
            }
            let headwordExisted = headwordIndex[spellingKey] != nil
            let headIndex: Int
            if let existing = headwordIndex[spellingKey] { headIndex = existing }
            else {
                headwords.append(VocabularyHeadword(spelling: row.word, pronunciation: row.pronunciation))
                headIndex = headwords.count - 1
                headwordIndex[spellingKey] = headIndex
                result.headwordsCreated += 1
            }
            let selected = replacements[row.rowNumber, default: []]
            if !row.pronunciation.isEmpty &&
                (headwords[headIndex].pronunciation.isEmpty || selected.contains(.pronunciation)) {
                headwords[headIndex].pronunciation = row.pronunciation
                if selected.contains(.pronunciation) { pronunciationOverwrites.insert(headwords[headIndex].id) }
            }
            let headID = headwords[headIndex].id
            let entryKey = "\(headID)|\(row.homonym)"
            let lexicalIndex: Int
            if let existing = entryIndex[entryKey] { lexicalIndex = existing }
            else {
                entries.append(LexicalEntry(headwordID: headID, homonymNumber: row.homonym))
                lexicalIndex = entries.count - 1
                entryIndex[entryKey] = lexicalIndex
                result.entriesCreated += 1
            }
            if row.structured && !row.duplicate, let priorIndex = existingIndex,
               words[priorIndex].legacyUnmapped == true,
               !VocabularyHierarchy.safelyMatchesLegacy(words[priorIndex].meaning, row.meaning) {
                let legacyEntryKey = "\(headID)|0"
                let legacyEntryIndex: Int
                if let existing = entryIndex[legacyEntryKey] { legacyEntryIndex = existing }
                else {
                    entries.append(LexicalEntry(headwordID: headID, homonymNumber: 0))
                    legacyEntryIndex = entries.count - 1
                    entryIndex[legacyEntryKey] = legacyEntryIndex
                }
                var legacySense = 0
                while senseIndex[VocabularyHierarchy.senseKey(row.word, homonym: 0, sense: legacySense)] != nil { legacySense += 1 }
                words[priorIndex].homonymNumber = 0
                words[priorIndex].senseNumber = legacySense
                words[priorIndex].lexicalEntryID = entries[legacyEntryIndex].id
                senseIndex.removeValue(forKey: key)
                senseIndex[VocabularyHierarchy.senseKey(row.word, homonym: 0, sense: legacySense)] = priorIndex
                existingIndex = nil
            }
            if let existingIndex, action == .update {
                var word = words[existingIndex]
                if row.structured { word.legacyUnmapped = false }
                if row.structured || word.meaning.isEmpty || selected.contains(.english) { word.meaning = row.meaning }
                if !row.partOfSpeech.isEmpty { word.partOfSpeech = row.partOfSpeech }
                if !row.example.isEmpty && (row.structured || word.example.isEmpty || selected.contains(.exampleKweyol)) { word.example = row.example }
                if !row.translation.isEmpty && (row.structured || word.translation.isEmpty || selected.contains(.exampleEnglish)) { word.translation = row.translation }
                var seenIDs = Set<String>()
                word.collectionIDs = word.collectionIDs.filter { seenIDs.insert($0).inserted }
                var seenCategoryKeys = Set(word.collectionIDs.compactMap { categoryKeysByID[$0] })
                for id in assignedIDs where seenCategoryKeys.insert(categoryKeysByID[id] ?? id).inserted {
                    word.collectionIDs.append(id)
                    result.assignmentsAdded += 1
                }
                words[existingIndex] = word
                result.updated += 1
            } else {
                var senseNumber = row.sense
                if existingIndex != nil {
                    while senseIndex[VocabularyHierarchy.senseKey(row.word, homonym: row.homonym, sense: senseNumber)] != nil { senseNumber += 1 }
                }
                var word = WordRecord(word: headwords[headIndex].spelling, meaning: row.meaning)
                word.headwordID = headID
                word.lexicalEntryID = entries[lexicalIndex].id
                word.homonymNumber = row.homonym
                word.senseNumber = senseNumber
                word.partOfSpeech = row.partOfSpeech
                word.pronunciation = headwords[headIndex].pronunciation
                word.audioFile = headwords[headIndex].audioFile
                word.example = row.example
                word.translation = row.translation
                word.collectionIDs = assignedIDs
                words.append(word)
                let createdKey = VocabularyHierarchy.senseKey(row.word, homonym: row.homonym, sense: senseNumber)
                senseIndex[createdKey] = words.count - 1
                result.created += 1
                if existingIndex != nil { result.duplicatesCreated += 1 }
                else if headwordExisted { result.additionalSensesCreated += 1 }
                result.assignmentsAdded += assignedIDs.count
            }
        }
        let headwordsByID = Dictionary(uniqueKeysWithValues: headwords.map { ($0.id, $0) })
        for index in words.indices {
            if let headID = words[index].headwordID, let headword = headwordsByID[headID] {
                words[index].word = headword.spelling
                if words[index].pronunciation.isEmpty || pronunciationOverwrites.contains(headID) {
                    words[index].pronunciation = headword.pronunciation
                }
                if words[index].audioFile == nil { words[index].audioFile = headword.audioFile }
            }
        }
        return (words, headwords, entries, collections, result)
    }
}

private struct DestinationScreen: View {
    let route: ScreenRoute
    let selectedTab: AppTab
    @ObservedObject var store: VocabularyStore
    let onBack: () -> Void
    let onNavigate: (ScreenRoute) -> Void
    let onSelectTab: (AppTab) -> Void
    @State private var showFilePicker = false
    @State private var rows: [[String]] = []
    @State private var headerIndex = 0
    @State private var importStep: ExcelImportStep = .choose
    @State private var mapping: [Int: ExcelImportField] = [:]
    @State private var activeMappingColumn: Int?
    @State private var previewRows: [ExcelRowPreview] = []
    @State private var showsBulkDuplicateOptions = false
    @State private var activeDuplicateRow: Int?
    @State private var bulkDuplicateMode: ExcelBulkDuplicateMode = .addNewAndUpdateExisting
    @State private var duplicateActions: [Int: ExcelDuplicateAction] = [:]
    @State private var replacementFields: [Int: Set<ExcelImportField>] = [:]
    @State private var importResult: ExcelImportResult?
    @State private var report = ""

    private var columnCount: Int { rows.dropFirst(headerIndex).map(\.count).max() ?? 0 }
    private var headers: [String] {
        (0..<columnCount).map { index in
            let title = rows.indices.contains(headerIndex) && rows[headerIndex].indices.contains(index)
                ? rows[headerIndex][index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return title.isEmpty ? "Column \(index + 1)" : title
        }
    }
    private var dataRows: [(number: Int, cells: [String])] {
        Array(rows.dropFirst(headerIndex + 1).enumerated()).compactMap { offset, row in
            row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? nil : (offset + headerIndex + 2, row)
        }
    }
    private func detectedHeaderIndex(in loaded: [[String]]) -> Int? {
        let populated = loaded.indices.filter { index in
            loaded[index].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
        }
        return populated.prefix(10).first { index in
            let fields = Set(loaded[index].map(ExcelImportField.suggested(for:)))
            return fields.contains(.kweyol) && fields.contains(.english)
        } ?? populated.first
    }
    private var mappingValid: Bool { mapping.values.contains(.kweyol) && mapping.values.contains(.english) }
    private func cell(_ row: [String], _ field: ExcelImportField) -> String {
        guard let index = mapping.first(where: { $0.value == field })?.key, row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func positiveIndex(_ raw: String) -> Int {
        if raw.isEmpty { return 1 }
        if let whole = Int(raw) { return whole }
        if let number = Double(raw), let whole = Int(exactly: number) { return whole }
        return 0
    }
    private func makePreviewRows() -> [ExcelRowPreview] {
        var existingNames: [String: String] = [:]
        for collection in store.collections {
            let key = ExcelImportLogic.key(collection.title)
            if existingNames[key] == nil { existingNames[key] = collection.title }
        }
        let existingSenses = Dictionary(store.words.map {
            (VocabularyHierarchy.senseKey($0.word, homonym: $0.homonym, sense: $0.sense), $0)
        }, uniquingKeysWith: { first, _ in first })
        var seenFileSenses = Set<String>()
        let structured = mapping.values.contains(.homonym) || mapping.values.contains(.sense)
        return dataRows.map { item in
            let word = cell(item.cells, .kweyol), meaning = cell(item.cells, .english)
            let rawHomonym = cell(item.cells, .homonym), rawSense = cell(item.cells, .sense)
            let homonym = positiveIndex(rawHomonym)
            let sense = positiveIndex(rawSense)
            let error = word.isEmpty ? "Missing Kwéyòl word or phrase" :
                        meaning.isEmpty ? "Missing English meaning" :
                        homonym < 1 ? "Homonym must be a positive number" :
                        sense < 1 ? "Sense must be a positive number" : nil
            let key = VocabularyHierarchy.senseKey(word, homonym: homonym, sense: sense)
            let existing = existingSenses[key]
            let safelyMatchingExisting = existing.map {
                !structured || $0.legacyUnmapped != true || VocabularyHierarchy.safelyMatchesLegacy($0.meaning, meaning)
            } ?? false
            let duplicate = error == nil && (safelyMatchingExisting || seenFileSenses.contains(key))
            let names = ExcelImportLogic.categories(cell(item.cells, .categories))
            let categories = names.map { name -> ExcelCategoryPreview in
                let key = ExcelImportLogic.key(name)
                if let existing = existingNames[key] { return ExcelCategoryPreview(name: existing, matchedExisting: true) }
                return ExcelCategoryPreview(name: name, matchedExisting: false)
            }
            if error == nil { seenFileSenses.insert(key) }
            return ExcelRowPreview(rowNumber: item.number, word: word, homonym: homonym, sense: sense,
                                   partOfSpeech: cell(item.cells, .partOfSpeech), structured: structured, meaning: meaning,
                                   pronunciation: cell(item.cells, .pronunciation),
                                   example: cell(item.cells, .exampleKweyol),
                                   translation: cell(item.cells, .exampleEnglish),
                                   categories: categories, duplicate: duplicate, error: error)
        }
    }
    private func assign(_ field: ExcelImportField, to column: Int) {
        if field != .ignore { mapping = mapping.filter { $0.key == column || $0.value != field } }
        mapping[column] = field
        activeMappingColumn = nil
        previewRows = []
        duplicateActions = [:]
        replacementFields = [:]
        showsBulkDuplicateOptions = false
        activeDuplicateRow = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: backFromImport) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(Style.heading(17))
                    .foregroundStyle(Style.teal)
                }
                .buttonStyle(.plain)
                Spacer()
                FlowerLogo().frame(width: 41, height: 41)
            }
            .padding(.horizontal, 23)
            .padding(.top, 15)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch route {
                    case .addWord, .addSentence, .editSentence, .extractSentence, .sentenceDetails:
                        EmptyView()

                    case .importExcel:
                        ScreenIntro(eyebrow: "GROW YOUR VOCABULARY", title: "Import words", subtitle: "Bring your word list from Excel.")
                        switch importStep {
                        case .choose: chooseFileContent
                        case .mapping: mappingContent
                        case .preview: previewContent
                        case .result: resultContent
                        }
                        if !report.isEmpty { Text(report).font(.system(size: 14, design: .rounded)).foregroundStyle(Style.ink).padding(.top, 14) }

                    case .learnNewWords, .review, .reviewStale, .reviewComplete, .reviewSession, .reviewSettings, .recordPronunciation:
                        EmptyView()

                    case .collection:
                        EmptyView()
                    case .wordDetails, .editWord:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 30)
            }

            if route == .importExcel {
                BottomNavigation(selected: selectedTab, onSelect: onSelectTab)
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard url.pathExtension.lowercased() == "xlsx" else {
                        report = "Choose an .xlsx Excel spreadsheet. Other file types are not supported."
                        return
                    }
                    let loaded = try SpreadsheetReader.read(url)
                    guard let detectedHeaderIndex = detectedHeaderIndex(in: loaded) else {
                        report = "The first worksheet needs a header row with at least two labeled columns. Map one to Kwéyòl and one to English."
                        return
                    }
                    rows = loaded
                    headerIndex = detectedHeaderIndex
                    mapping = [:]
                    for index in headers.indices {
                        let suggestion = ExcelImportField.suggested(for: headers[index])
                        if suggestion != .ignore && !mapping.values.contains(suggestion) { mapping[index] = suggestion }
                    }
                    duplicateActions = [:]
                    replacementFields = [:]
                    previewRows = []
                    bulkDuplicateMode = .addNewAndUpdateExisting
                    importResult = nil
                    activeMappingColumn = nil
                    showsBulkDuplicateOptions = false
                    activeDuplicateRow = nil
                    importStep = .mapping
                    report = dataRows.isEmpty ? "No vocabulary rows were found below the header." : ""
                } catch { report = error.localizedDescription }
            case .failure(let error): report = error.localizedDescription
            }
        }
    }

    private var chooseFileContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 58, weight: .medium))
                    .foregroundStyle(Style.purpleInk)
                    .frame(width: 120, height: 120)
                    .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 30))
                Text("Your words, all together.")
                    .font(Style.heading(27))
                    .foregroundStyle(Style.purpleInk)
                Text("An Excel sheet can keep your words, meanings, and examples together.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Style.quiet)
            }
            .frame(maxWidth: .infinity)
            .padding(30)
            .frame(height: 330)
            .background(Style.lavender, in: RoundedRectangle(cornerRadius: 30))
            importButton("Choose .xlsx spreadsheet", enabled: true) { showFilePicker = true }
        }
    }

    private var mappingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Map spreadsheet columns")
                .font(Style.heading(22)).foregroundStyle(Style.ink)
            Text("Choose what each spreadsheet column means. Kwéyòl and English are required.")
                .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
            Text("Use Homonym and Sense numbers for separate meanings. In Collections, separate names with semicolons, for example Food; Nouns; Top 1,000.")
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
            ForEach(headers.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(headers[index]).font(Style.heading(16)).foregroundStyle(Style.ink)
                    Button { activeMappingColumn = activeMappingColumn == index ? nil : index } label: {
                        HStack {
                            Text(mapping[index, default: .ignore].rawValue)
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Style.teal)
                        .padding(.horizontal, 13).frame(height: 42)
                        .background(Style.mint, in: RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain)
                    if activeMappingColumn == index {
                        DropdownOptionsCard(options: ExcelImportField.allCases.map { DropdownChoice(id: $0.rawValue, title: $0.rawValue) },
                                            selectedID: mapping[index, default: .ignore].rawValue) { choice in
                            if let field = ExcelImportField(rawValue: choice) { assign(field, to: index) }
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 13))
            }
            if !mappingValid {
                Text("Map one column to Kwéyòl and one to English to continue.")
                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.coral)
            }
            importButton("Preview \(dataRows.count) Rows", enabled: mappingValid && !dataRows.isEmpty) {
                report = ""
                previewRows = makePreviewRows()
                showsBulkDuplicateOptions = false
                activeDuplicateRow = nil
                importStep = .preview
            }
        }
        .padding(.top, 22)
    }

    private var previewContent: some View {
        let displayed = previewRows
        let summary = ExcelImportEngine.summarize(rows: displayed, overrides: duplicateActions, bulkMode: bulkDuplicateMode,
                                                  existingWords: store.words, existingCollections: store.collections)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Review before importing")
                .font(Style.heading(22)).foregroundStyle(Style.ink)
            VStack(alignment: .leading, spacing: 6) {
                summaryLine("Sense rows found", count: summary.rows)
                summaryLine("Unique headwords in file", count: summary.uniqueHeadwords)
                summaryLine("Existing senses", count: summary.existing)
                summaryLine("New senses", count: summary.new)
                summaryLine("Invalid rows", count: summary.invalid)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.lavender, in: RoundedRectangle(cornerRadius: 17))
            if summary.existing > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For existing senses")
                        .font(Style.heading(16)).foregroundStyle(Style.ink)
                    Button {
                        showsBulkDuplicateOptions.toggle()
                        activeDuplicateRow = nil
                    } label: {
                        HStack {
                            Text(bulkDuplicateMode.rawValue)
                            Spacer()
                            Image(systemName: showsBulkDuplicateOptions ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Style.teal).padding(13)
                        .background(Style.mint, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("For existing words")
                    .accessibilityValue(bulkDuplicateMode.rawValue)
                    if showsBulkDuplicateOptions {
                        DropdownOptionsCard(
                            options: ExcelBulkDuplicateMode.allCases.map { DropdownChoice(id: $0.rawValue, title: $0.rawValue) },
                            selectedID: bulkDuplicateMode.rawValue
                        ) { choice in
                            if let mode = ExcelBulkDuplicateMode(rawValue: choice) {
                                bulkDuplicateMode = mode
                                duplicateActions = [:]
                            }
                            showsBulkDuplicateOptions = false
                        }
                    }
                    Text("This sets the action for every matching sense. You can still change individual rows below.")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 6) {
                summaryLine("New headwords to add", count: summary.newHeadwords)
                summaryLine("New lexical entries", count: summary.newEntries)
                summaryLine("Additional senses", count: summary.additionalSenses)
                summaryLine("New senses to add", count: summary.created - summary.duplicatesCreated)
                summaryLine("Existing senses to update", count: summary.updated)
                summaryLine("Duplicates to create", count: summary.duplicatesCreated)
                summaryLine("Existing senses to skip", count: summary.skipped)
                summaryLine("Category relationships to add", count: summary.assignmentsAdded)
                summaryLine("New categories to create", count: summary.categoriesCreated)
                summaryLine("Existing categories matched", count: summary.existingCategoriesMatched)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.mint, in: RoundedRectangle(cornerRadius: 17))
            Text("Matching senses keep their audio and learning progress. Structured Homonym/Sense imports update meaning, part of speech, and examples. Pronunciation hints change only when blank or selected. Collections are appended.")
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
            LazyVStack(spacing: 10) {
                ForEach(displayed) { row in previewCard(row) }
            }
            importButton(summary.updated > 0 ? "Import & Update \(summary.totalActions.formatted()) Senses" : "Import \(summary.totalActions.formatted()) Senses",
                         enabled: summary.totalActions > 0, action: importRows)
        }
        .padding(.top, 22)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import complete")
                .font(Style.heading(27)).foregroundStyle(Style.ink)
            if let result = importResult {
                VStack(alignment: .leading, spacing: 7) {
                    summaryLine("Senses imported", count: result.created)
                    summaryLine("Existing senses updated", count: result.updated)
                    summaryLine("Headwords created", count: result.headwordsCreated)
                    summaryLine("Lexical entries created", count: result.entriesCreated)
                    summaryLine("Additional senses created", count: result.additionalSensesCreated)
                    summaryLine("Duplicates created", count: result.duplicatesCreated)
                    summaryLine("Categories created", count: result.categoriesCreated)
                    summaryLine("Category assignments added", count: result.assignmentsAdded)
                    summaryLine("Duplicates skipped", count: result.duplicatesSkipped)
                    summaryLine("Rows not imported", count: result.failures.count)
                }
                .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(Style.mint, in: RoundedRectangle(cornerRadius: 18))
                if !result.failures.isEmpty {
                    Text("Rows needing attention").font(Style.heading(19)).foregroundStyle(Style.ink)
                    ForEach(result.failures, id: \.self) { failure in
                        Text(failure).font(.system(size: 14, design: .rounded)).foregroundStyle(Style.coral)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            importButton("View Library", enabled: true) { onSelectTab(.library) }
            Button("Import another spreadsheet") {
                rows = []
                mapping = [:]
                previewRows = []
                bulkDuplicateMode = .addNewAndUpdateExisting
                duplicateActions = [:]
                replacementFields = [:]
                importResult = nil
                report = ""
                importStep = .choose
                showsBulkDuplicateOptions = false
                activeDuplicateRow = nil
                showFilePicker = true
            }
            .font(Style.heading(15)).foregroundStyle(Style.teal)
            .frame(maxWidth: .infinity).padding(.top, 6)
        }
        .padding(.top, 22)
    }

    private func previewCard(_ row: ExcelRowPreview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text("Row \(row.rowNumber) · \(row.word.isEmpty ? "Missing Kwéyòl" : row.word) · Entry \(row.homonym) · Meaning \(row.sense) → \(row.meaning.isEmpty ? "Missing English" : row.meaning)")
                    .font(Style.heading(16)).foregroundStyle(Style.ink)
                Spacer(minLength: 5)
            }
            Text(row.error ?? (row.duplicate ? "Existing · \(ExcelImportEngine.action(for: row.rowNumber, overrides: duplicateActions, bulkMode: bulkDuplicateMode).rawValue)" : "Ready"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(row.error != nil ? Style.coral : row.duplicate ? Style.purpleInk : Style.teal)
            if !row.pronunciation.isEmpty { Text("Pronunciation: \(row.pronunciation)").font(.system(size: 13, design: .rounded)).foregroundStyle(Style.quiet) }
            if !row.partOfSpeech.isEmpty { Text("Part of speech: \(row.partOfSpeech)").font(.system(size: 13, design: .rounded)).foregroundStyle(Style.quiet) }
            if !row.example.isEmpty { Text("Example: \(row.example)").font(.system(size: 13, design: .rounded)).foregroundStyle(Style.quiet) }
            if !row.translation.isEmpty { Text("Example English: \(row.translation)").font(.system(size: 13, design: .rounded)).foregroundStyle(Style.quiet) }
            ForEach(row.categories) { category in
                Text("\(category.matchedExisting ? "Matched existing category" : "New category if imported"): \(category.name)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(category.matchedExisting ? Style.teal : Style.purpleInk)
            }
            if row.duplicate && row.error == nil {
                Button {
                    activeDuplicateRow = activeDuplicateRow == row.rowNumber ? nil : row.rowNumber
                    showsBulkDuplicateOptions = false
                } label: {
                    HStack {
                        Text(ExcelImportEngine.action(for: row.rowNumber, overrides: duplicateActions, bulkMode: bulkDuplicateMode).rawValue)
                        Spacer()
                        Image(systemName: activeDuplicateRow == row.rowNumber ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Style.teal).padding(11)
                    .background(Style.mint, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Action for row \(row.rowNumber)")
                .accessibilityValue(ExcelImportEngine.action(for: row.rowNumber, overrides: duplicateActions, bulkMode: bulkDuplicateMode).rawValue)
                if activeDuplicateRow == row.rowNumber {
                    DropdownOptionsCard(
                        options: ExcelDuplicateAction.allCases.map { DropdownChoice(id: $0.rawValue, title: $0.rawValue) },
                        selectedID: ExcelImportEngine.action(for: row.rowNumber, overrides: duplicateActions, bulkMode: bulkDuplicateMode).rawValue
                    ) { choice in
                        if let action = ExcelDuplicateAction(rawValue: choice) { duplicateActions[row.rowNumber] = action }
                        activeDuplicateRow = nil
                    }
                }
                if ExcelImportEngine.action(for: row.rowNumber, overrides: duplicateActions, bulkMode: bulkDuplicateMode) == .update {
                    Text("Blank existing fields fill automatically. Select fields to replace their current text:")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    ForEach(importedTextFields(in: row), id: \.self) { field in
                        Button {
                            var selected = replacementFields[row.rowNumber, default: []]
                            if !selected.insert(field).inserted { selected.remove(field) }
                            replacementFields[row.rowNumber] = selected
                        } label: {
                            Label(field.rawValue, systemImage: replacementFields[row.rowNumber, default: []].contains(field) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Style.teal)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func importedTextFields(in row: ExcelRowPreview) -> [ExcelImportField] {
        let values: [(ExcelImportField, String)] = [(.english, row.meaning), (.pronunciation, row.pronunciation), (.exampleKweyol, row.example), (.exampleEnglish, row.translation)]
        return values.compactMap { $0.1.isEmpty ? nil : $0.0 }
    }
    private func summaryLine(_ title: String, count: Int) -> some View {
        HStack { Text(title); Spacer(); Text(count.formatted()) }
            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Style.ink)
    }
    private func importButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Style.heading(17)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(Style.teal, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .padding(.top, 12)
    }

    private func importRows() {
        let planned = ExcelImportEngine.apply(rows: previewRows, actions: duplicateActions, bulkMode: bulkDuplicateMode, replacements: replacementFields,
                                              existingWords: store.words, existingHeadwords: store.headwords,
                                              existingEntries: store.lexicalEntries, existingCollections: store.collections)
        do {
            try store.commitImport(words: planned.words, headwords: planned.headwords,
                                   lexicalEntries: planned.entries, collections: planned.collections)
            importResult = planned.result
            report = ""
            importStep = .result
        } catch {
            report = "The import could not be saved: \(error.localizedDescription). No changes were made."
        }
    }

    private func backFromImport() {
        guard route == .importExcel else { onBack(); return }
        switch importStep {
        case .choose: onBack()
        case .mapping: importStep = .choose
        case .preview: importStep = .mapping
        case .result: onSelectTab(.library)
        }
    }
}

private struct WordDetailsScreen: View {
    let word: WordRecord
    let onBack: () -> Void
    let onEdit: () -> Void
    let onEditSense: (WordRecord) -> Void
    let onCollection: () -> Void
    @ObservedObject var store: VocabularyStore
    let onDelete: () -> Void
    @State private var confirmDelete = false
    private var senses: [WordRecord] { store.senses(for: word) }
    private var homonyms: [Int] { Array(Set(senses.map(\.homonym))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            WordScreenHeader(trailing: .edit, onBack: onBack, onEdit: onEdit)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 26)
                            .fill(Style.teal)

                        Circle()
                            .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.3, dash: [5, 5]))
                            .frame(width: 170, height: 170)
                            .offset(x: 278, y: -88)

                        Sparkle(color: Style.yellow, length: 13)
                            .frame(width: 27, height: 27)
                            .offset(x: 357, y: 45)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("YOUR WORD")
                                .font(Style.heading(12))
                                .tracking(1.4)
                                .foregroundStyle(Color.white.opacity(0.77))
                            Text(word.word)
                                .font(Style.heading(72))
                                .tracking(-3)
                                .foregroundStyle(.white)
                                .minimumScaleFactor(0.65)
                                .lineLimit(1)
                                .padding(.top, 8)
                            Text(senses.count > 1 ? "\(senses.count) meanings" : word.meaning)
                                .font(Style.heading(20))
                                .foregroundStyle(.white)
                                .padding(.top, -3)
                            Spacer()
                            HStack(alignment: .bottom) {
                                Text("SAVED FROM REAL LIFE")
                                    .font(Style.heading(11))
                                    .tracking(0.5)
                                    .foregroundStyle(.white.opacity(0.66))
                                Spacer()
                                if word.audioFile != nil { Button { store.playAudio(word.audioFile) } label: { HStack(spacing: 7) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("Hear it")
                                        .font(Style.heading(13))
                                }
                                .foregroundStyle(Style.teal)
                                .padding(.horizontal, 13)
                                .frame(height: 42)
                                .background(Style.yellow, in: RoundedRectangle(cornerRadius: 13)) }.buttonStyle(.plain) }
                            }
                        }
                        .padding(23)
                    }
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                    WordSectionHeading(title: "Pronunciation")
                        .padding(.top, 18)

                    if word.audioFile != nil { Button { store.playAudio(word.audioFile) } label: { HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Style.teal, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recorded pronunciation")
                                .font(Style.heading(15))
                                .foregroundStyle(Style.purpleInk)
                            Text("Tap to play")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Style.purpleInk.opacity(0.65))
                        }
                        Spacer(minLength: 4)
                        AudioWaveform(color: AddWordStyle.lilacInk)
                            .frame(width: 64, height: 30)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 82)
                    .background(AddWordStyle.lilac, in: RoundedRectangle(cornerRadius: 17))
                    .padding(.top, 10) }.buttonStyle(.plain) }

                    HStack(spacing: 8) {
                        Text("Personal hint")
                            .font(Style.heading(13))
                            .foregroundStyle(Style.teal)
                        Text(word.pronunciation.isEmpty ? "· Not added yet" : "· \(word.pronunciation)")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                    }
                    .padding(.top, 9)

                    WordSectionHeading(title: senses.count == 1 ? "Meaning" : "Meanings")
                        .padding(.top, 18)
                    ForEach(homonyms, id: \.self) { homonym in
                        if homonyms.count > 1 {
                            Text(homonym == 0 ? "Earlier saved meaning" : "Separate entry \(homonym)")
                                .font(Style.heading(15)).foregroundStyle(Style.purpleInk)
                                .padding(.top, 17)
                        }
                        ForEach(senses.filter { $0.homonym == homonym }) { sense in
                            SenseDetailCard(sense: sense, store: store, onEdit: { onEditSense(sense) })
                                .padding(.top, 10)
                        }
                    }
                }
                .padding(.horizontal, 23)
                .padding(.top, 8)
                .padding(.bottom, 27)
            }

            WordActionFooter(primaryTitle: "Edit word", onPrimary: onEdit, onDelete: { confirmDelete = true }, note: "Made of words worth remembering.")
        }
        .background(Style.background)
        .confirmationDialog("Delete this word and all its meanings?", isPresented: $confirmDelete) {
            Button("Delete word and meanings", role: .destructive, action: onDelete)
        }
    }
}

private struct SenseDetailCard: View {
    let sense: WordRecord
    @ObservedObject var store: VocabularyStore
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(sense.legacyUnmapped == true ? "Earlier saved meaning" : "Meaning \(sense.sense)")
                    .font(Style.heading(15)).foregroundStyle(Style.teal)
                Spacer()
                Button("Edit", action: onEdit)
                    .font(Style.heading(13)).foregroundStyle(Style.purpleInk)
                    .buttonStyle(.plain)
            }
            Text(sense.meaning)
                .font(Style.heading(24)).foregroundStyle(Style.ink)
            if let part = sense.partOfSpeech, !part.isEmpty {
                Text(part)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Style.purpleInk)
            }
            if !sense.example.isEmpty || !sense.translation.isEmpty {
                Rectangle().fill(AddWordStyle.border).frame(height: 1)
                DetailPlaceholder(label: "KWÉYÒL EXAMPLE", text: sense.example.isEmpty ? "No example added yet" : sense.example)
                if !sense.translation.isEmpty {
                    DetailPlaceholder(label: "ENGLISH TRANSLATION", text: sense.translation)
                }
            }
            ForEach(sense.additionalExamples ?? []) { example in
                Rectangle().fill(AddWordStyle.border).frame(height: 1)
                DetailPlaceholder(label: "KWÉYÒL EXAMPLE", text: example.kweyol)
                DetailPlaceholder(label: "ENGLISH TRANSLATION", text: example.english)
            }
            if !sense.collectionIDs.isEmpty {
                Text(sense.collectionIDs.map(store.collectionTitle).joined(separator: " · "))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Style.teal)
            }
            HStack {
                Text(sense.status == .new ? "New" : sense.isDue ? "Due" : "Learning")
                Spacer()
                if sense.status != .new, let next = sense.nextReview {
                    Text("Next review \(next.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Style.quiet)
            .contextMenu {
                Button("Reset this meaning's review progress", role: .destructive) { store.resetProgress(sense.id) }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AddWordStyle.cardBorder, lineWidth: 1))
    }
}

private struct WordScreenHeader: View {
    enum Trailing {
        case edit, cancel
    }

    let trailing: Trailing
    let onBack: () -> Void
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Style.teal)
                    .frame(width: 48, height: 48)
                    .background(AddWordStyle.mint, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            BrandLockup()
            Spacer()
            if trailing == .edit {
                Button(action: { onEdit?() }) {
                    HStack(spacing: 3) {
                        Text("Edit")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(Style.heading(13))
                    .foregroundStyle(Color(red: 0.60, green: 0.35, blue: 0.27))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Style.peach, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button("Cancel", action: onBack)
                    .font(Style.heading(14))
                    .foregroundStyle(Style.teal)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 23)
        .frame(height: 59)
        .background(Style.background)
    }
}

private struct WordSectionHeading: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(Style.heading(16))
                .foregroundStyle(Style.ink)
            Spacer()
            Sparkle(color: Style.coral, length: 8)
                .frame(width: 18, height: 18)
        }
    }
}

private struct DetailPlaceholder: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Style.heading(11))
                .tracking(1)
                .foregroundStyle(Style.quiet)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
        }
    }
}

private struct ReviewHistoryTile: View {
    let label: String
    let value: String
    let fill: Color
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Style.heading(11))
                .tracking(0.6)
                .opacity(0.68)
            Text(value)
                .font(Style.heading(17))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 66)
        .background(fill, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct AudioWaveform: View {
    let color: Color

    private let heights: [CGFloat] = [13, 23, 17, 29, 19, 26, 12, 20, 15]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: 3, height: heights[index])
            }
        }
    }
}

private struct WordActionFooter: View {
    let primaryTitle: String
    let onPrimary: (() -> Void)?
    let onDelete: (() -> Void)?
    let note: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 15) {
                Button("Delete word") { onDelete?() }
                    .font(Style.heading(14))
                    .foregroundStyle(Style.coral)
                    .buttonStyle(.plain)

                Button(action: { onPrimary?() }) {
                    HStack {
                        Text(primaryTitle)
                            .font(Style.heading(17))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 19, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 19)
                    .frame(height: 60)
                    .background(Style.teal, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }

            Text(note)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
        }
        .padding(.horizontal, 23)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background {
            Style.background
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(Style.ink.opacity(0.06)).frame(height: 1)
                }
        }
    }
}

private struct EditWordScreen: View {
    let word: WordRecord
    let collections: [CollectionExample]
    let onBack: () -> Void
    let onRecord: () -> Void
    let onSave: (WordRecord) -> Void
    let onAddMeaning: (Bool) -> Void
    let allowsAddingMeanings: Bool
    let onDelete: () -> Void
    @ObservedObject var store: VocabularyStore
    @State private var edited: WordRecord
    @State private var showCollectionPicker = false
    @State private var confirmDelete = false

    init(word: WordRecord, collections: [CollectionExample], onBack: @escaping () -> Void, onRecord: @escaping () -> Void, onSave: @escaping (WordRecord) -> Void,
         onAddMeaning: @escaping (Bool) -> Void, allowsAddingMeanings: Bool = true,
         onDelete: @escaping () -> Void, store: VocabularyStore) {
        self.word = word; self.collections = collections; self.onBack = onBack; self.onRecord = onRecord; self.onSave = onSave
        self.onAddMeaning = onAddMeaning; self.allowsAddingMeanings = allowsAddingMeanings
        self.onDelete = onDelete; self.store = store
        _edited = State(initialValue: word)
    }

    var body: some View {
        VStack(spacing: 0) {
            WordScreenHeader(trailing: .cancel, onBack: onBack)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("*")
                            Text("MAKE IT YOURS")
                                .tracking(1.1)
                        }
                        .font(Style.heading(12))
                        .foregroundStyle(Style.coral)

                        HStack(spacing: 0) {
                            Text("Edit word").foregroundStyle(Style.ink)
                            Text(".").foregroundStyle(Style.coral)
                        }
                        .font(Style.heading(37))
                        .tracking(-1.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topTrailing) {
                        SmallABCCard()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    EditEssentialsSection(word: $edited)
                    EditPronunciationSection(word: $edited, onRecord: { store.upsert(edited); onRecord() }, onPlay: { store.playAudio(edited.audioFile) })
                    EditExampleSection(word: $edited)
                    EditCollectionsSection(collections: collections, selected: edited.collectionIDs, onChoose: { showCollectionPicker = true })
                    if allowsAddingMeanings { VStack(alignment: .leading, spacing: 12) {
                        Button("Add another meaning") { onAddMeaning(false) }
                            .font(Style.heading(17)).foregroundStyle(Style.teal)
                        Button("Add separate unrelated meaning") { onAddMeaning(true) }
                            .font(Style.heading(16)).foregroundStyle(Style.purpleInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22)) }
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 24)
            }

            WordActionFooter(primaryTitle: "Save changes", onPrimary: {
                guard !edited.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !edited.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                onSave(edited)
            }, onDelete: { confirmDelete = true }, note: "Change anything. Keep the memory.")
        }
        .background(Style.background)
        .sheet(isPresented: $showCollectionPicker) {
            AddWordCollectionPickerSheet(collections: collections, selectedIDs: Binding(get: { Set(edited.collectionIDs) }, set: { edited.collectionIDs = Array($0) }), onSaveCollection: { collection in
                let saved = collection.saved
                if let index = store.collections.firstIndex(where: { $0.id == saved.id }) { store.collections[index] = saved }
                else { store.collections.append(saved) }
            })
        }
        .confirmationDialog("Delete this word?", isPresented: $confirmDelete) {
            Button("Delete word", role: .destructive, action: onDelete)
        }
    }
}

private struct SmallABCCard: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(AddWordStyle.lilac)
                .frame(width: 57, height: 66)
                .rotationEffect(.degrees(10))
                .offset(x: 6, y: 5)
            RoundedRectangle(cornerRadius: 12)
                .fill(Style.yellow)
                .frame(width: 57, height: 66)
                .overlay {
                    Text("abc")
                        .font(Style.heading(20))
                        .foregroundStyle(Style.teal)
                }
                .rotationEffect(.degrees(10))
        }
        .frame(width: 74, height: 75)
    }
}

private struct EditEssentialsSection: View {
    @Binding var word: WordRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CompactSectionHeader(number: "01", title: "The essentials", fill: Style.yellow, ink: Color(red: 0.48, green: 0.42, blue: 0.16))
            CompactField(label: "Kwéyòl word or phrase", value: $word.word, required: true)
            CompactField(label: "English meaning", value: $word.meaning, required: true)
            CompactField(label: "Part of speech", value: Binding(
                get: { word.partOfSpeech ?? "" }, set: { word.partOfSpeech = $0 }))
        }
        .padding(17)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(AddWordStyle.cardBorder, lineWidth: 1))
    }
}

private struct EditPronunciationSection: View {
    @Binding var word: WordRecord
    let onRecord: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CompactSectionHeader(number: "02", title: "Pronunciation", fill: Color(red: 0.83, green: 0.76, blue: 0.95), ink: Style.purpleInk, optional: true)
            CompactField(label: "Personal pronunciation hint", value: $word.pronunciation, placeholder: true, tint: Color(red: 0.80, green: 0.74, blue: 0.92), fill: Color(red: 0.984, green: 0.972, blue: 1))

            if word.audioFile != nil { Text("SAVED AUDIO")
                .font(Style.heading(11))
                .tracking(0.6)
                .foregroundStyle(AddWordStyle.lilacInk)
                .padding(.top, 2) }

            if word.audioFile != nil { Button(action: onPlay) { HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Style.teal, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker recording")
                        .font(Style.heading(13))
                    Text("Tap to play")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                }
                .foregroundStyle(Style.purpleInk)
                Spacer()
                AudioWaveform(color: AddWordStyle.lilacInk)
                    .frame(width: 48, height: 26)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 13)) }.buttonStyle(.plain) }

            HStack(spacing: 8) {
                Button(action: onRecord) {
                    SmallActionPill(title: word.audioFile == nil ? "Record" : "Replace", symbol: "arrow.clockwise", fill: .white, ink: AddWordStyle.lilacInk)
                }
                .buttonStyle(.plain)
                Button { word.audioFile = nil } label: { SmallActionPill(title: "Delete audio", symbol: "trash", fill: Style.peach, ink: Color(red: 0.68, green: 0.35, blue: 0.29)) }.buttonStyle(.plain)
            }
        }
        .padding(17)
        .background(AddWordStyle.lilac, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct EditExampleSection: View {
    @Binding var word: WordRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            CompactSectionHeader(number: "03", title: "Example sentence", fill: Style.peach, ink: Color(red: 0.68, green: 0.39, blue: 0.31), optional: true)
            CompactField(label: "Kwéyòl example sentence", value: $word.example, placeholder: true, tall: true)
            CompactField(label: "English translation", value: $word.translation, placeholder: true, tall: true)
        }
        .padding(17)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(AddWordStyle.cardBorder, lineWidth: 1))
    }
}

private struct EditCollectionsSection: View {
    let collections: [CollectionExample]
    let selected: [String]
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompactSectionHeader(number: "04", title: "Collections", fill: Color(red: 0.78, green: 0.91, blue: 0.86), ink: Style.teal, optional: true)

            ForEach(collections) { collection in
                Button(action: onChoose) { EditCollectionChip(title: collection.title, selected: selected.contains(collection.id)) }.buttonStyle(.plain)
            }

            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .black))
                Text("Create new collection")
                    .font(Style.heading(13))
            }
            .foregroundStyle(Style.teal)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onChoose)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.mint, in: RoundedRectangle(cornerRadius: 22))
    }
}

private struct CompactSectionHeader: View {
    let number: String
    let title: String
    let fill: Color
    let ink: Color
    var optional = false

    var body: some View {
        HStack(spacing: 9) {
            Text(number)
                .font(Style.heading(13))
                .foregroundStyle(ink)
                .frame(width: 30, height: 30)
                .background(fill, in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(Style.heading(16))
                .foregroundStyle(Style.ink)
            Spacer()
            if optional {
                Text("OPTIONAL")
                    .font(Style.heading(10))
                    .tracking(0.8)
                    .foregroundStyle(Style.quiet)
            }
        }
    }
}

private struct CompactField: View {
    let label: String
    @Binding var value: String
    var required = false
    var placeholder = false
    var tall = false
    var tint: Color = AddWordStyle.border
    var fill: Color = AddWordStyle.field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(Style.ink)
                if required {
                    Text("*").foregroundStyle(Style.coral)
                }
            }
            .font(Style.heading(12))

            TextField(placeholder ? label : "", text: $value, axis: tall ? .vertical : .horizontal)
                .font(.system(size: 14, weight: placeholder ? .medium : .bold, design: .rounded))
                .foregroundStyle(placeholder ? Style.quiet : Style.ink)
                .autocorrectionDisabled(label.contains("Kwéyòl"))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tall ? .topLeading : .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, tall ? 13 : 0)
                .background(fill, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(tint, lineWidth: 1.4))
                .frame(height: tall ? 54 : 43)
        }
    }
}

private struct EditCollectionChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
            }
            Text(title)
                .font(Style.heading(12))
        }
        .foregroundStyle(selected ? .white : Color(red: 0.35, green: 0.47, blue: 0.41))
        .padding(.horizontal, 11)
        .frame(height: 31)
        .background(selected ? Style.teal : .white, in: Capsule())
    }
}

private struct SmallActionPill: View {
    let title: String
    let symbol: String
    let fill: Color
    let ink: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .font(Style.heading(11))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(fill, in: Capsule())
    }
}

private enum AddWordStyle {
    static let field = Color(red: 0.991, green: 0.985, blue: 0.970)
    static let border = Color(red: 0.906, green: 0.899, blue: 0.873)
    static let cardBorder = Color(red: 0.940, green: 0.925, blue: 0.902)
    static let lilac = Color(red: 0.888, green: 0.844, blue: 0.974)
    static let lilacInk = Color(red: 0.54, green: 0.46, blue: 0.72)
    static let mint = Color(red: 0.901, green: 0.944, blue: 0.914)
    static let muted = Color(red: 0.39, green: 0.46, blue: 0.43)
}

private struct AddWordScreen: View {
    @Binding var word: WordRecord
    let collections: [CollectionExample]
    let onBack: () -> Void
    let onRecord: () -> Void
    let onSaveCollection: (CollectionExample) -> Void
    let onSave: ([WordRecord]) -> Void
    @ObservedObject var store: VocabularyStore
    @State private var showCollectionPicker = false
    @State private var additionalSenses: [WordRecord] = []
    @State private var selectedCollectionSenseIndex: Int? = nil

    private var selectedCollectionIDs: Binding<Set<String>> {
        Binding(get: {
            if let index = selectedCollectionSenseIndex, additionalSenses.indices.contains(index) {
                return Set(additionalSenses[index].collectionIDs)
            }
            return Set(word.collectionIDs)
        }, set: { ids in
            if let index = selectedCollectionSenseIndex, additionalSenses.indices.contains(index) {
                additionalSenses[index].collectionIDs = Array(ids)
            } else { word.collectionIDs = Array(ids) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            AddWordHeader(onBack: onBack)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    AddWordIntroduction()
                        .padding(.bottom, 1)
                    EssentialsSection(word: $word)
                    PronunciationSection(word: $word, onRecord: onRecord, onPlay: { store.playAudio(word.audioFile) }, onDelete: { store.removeAudio(word.audioFile); word.audioFile = nil })
                    ExampleSection(word: $word)
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(additionalSenses.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(additionalSenses[index].homonym == 1 ? "Meaning \(additionalSenses[index].sense)" : "Separate entry \(additionalSenses[index].homonym)")
                                        .font(Style.heading(17)).foregroundStyle(Style.ink)
                                    Spacer()
                                    Button("Remove") { additionalSenses.remove(at: index) }
                                        .font(Style.heading(13)).foregroundStyle(Style.coral)
                                }
                                CompactField(label: "English meaning", value: $additionalSenses[index].meaning, required: true)
                                CompactField(label: "Part of speech", value: Binding(
                                    get: { additionalSenses[index].partOfSpeech ?? "" },
                                    set: { additionalSenses[index].partOfSpeech = $0 }))
                                CompactField(label: "Kwéyòl example sentence", value: $additionalSenses[index].example, placeholder: true, tall: true)
                                CompactField(label: "English translation", value: $additionalSenses[index].translation, placeholder: true, tall: true)
                                Button("Collections · \(additionalSenses[index].collectionIDs.count) selected") {
                                    selectedCollectionSenseIndex = index
                                    showCollectionPicker = true
                                }
                                .font(Style.heading(14)).foregroundStyle(Style.teal)
                            }
                            .padding(17)
                            .background(.white, in: RoundedRectangle(cornerRadius: 22))
                        }
                        Button("Add another meaning") { addMeaning(separate: false) }
                            .font(Style.heading(16)).foregroundStyle(Style.teal)
                        Button("Add separate unrelated meaning") { addMeaning(separate: true) }
                            .font(Style.heading(15)).foregroundStyle(Style.purpleInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    WordCollectionsSection(selectedCount: word.collectionIDs.count) {
                        selectedCollectionSenseIndex = nil
                        showCollectionPicker = true
                    }

                    HStack(spacing: 7) {
                        Sparkle(color: AddWordStyle.muted, length: 8)
                            .frame(width: 17, height: 17)
                        Text("Every word is worth keeping.")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AddWordStyle.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 19)
                }
                .padding(.horizontal, 23)
                .padding(.top, 5)
            }

            AddWordFooter(onSave: { onSave(additionalSenses) }, enabled:
                !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !word.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                additionalSenses.allSatisfy { !$0.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        .background(Style.background)
        .sheet(isPresented: $showCollectionPicker) {
            AddWordCollectionPickerSheet(collections: collections, selectedIDs: selectedCollectionIDs, onSaveCollection: onSaveCollection)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
    }
    private func addMeaning(separate: Bool) {
        var sense = WordRecord(word: word.word, meaning: "")
        let homonym = separate ? (additionalSenses.map(\.homonym).max() ?? 1) + 1 : 1
        sense.homonymNumber = homonym
        sense.senseNumber = separate ? 1 : (additionalSenses.filter { $0.homonym == 1 }.map(\.sense).max() ?? 1) + 1
        additionalSenses.append(sense)
    }
}

private struct AddWordHeader: View {
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Style.teal)
                    .frame(width: 48, height: 48)
                    .background(AddWordStyle.mint, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            BrandLockup()
            Spacer()
            Text("NEW")
                .font(Style.heading(12))
                .tracking(0.9)
                .foregroundStyle(Color(red: 0.56, green: 0.33, blue: 0.27))
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(Style.peach, in: Capsule())
        }
        .padding(.horizontal, 23)
        .frame(height: 59)
        .background(Style.background)
    }
}

private struct AddWordIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("*")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                Text("YOUR WORD LIBRARY")
                    .font(Style.heading(13))
                    .tracking(1.15)
            }
            .foregroundStyle(Style.coral)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Add a word")
                    .foregroundStyle(Style.ghost)
                Text(".")
                    .foregroundStyle(Style.coral)
            }
            .font(Style.heading(43))
            .tracking(-1.7)

            Text("Hear something new? Save it here.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(AddWordStyle.lilac)
                    .frame(width: 66, height: 83)
                    .rotationEffect(.degrees(12))
                    .offset(x: 7, y: 7)
                RoundedRectangle(cornerRadius: 17)
                    .fill(Style.yellow)
                    .frame(width: 66, height: 83)
                    .overlay {
                        Text("abc")
                            .font(Style.heading(24))
                            .foregroundStyle(Style.teal)
                    }
                    .rotationEffect(.degrees(12))
                Sparkle(color: Style.coral, length: 9)
                    .frame(width: 18, height: 18)
                    .offset(x: 40, y: -39)
            }
            .frame(width: 91, height: 92)
            .padding(.top, 5)
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

private struct EssentialsSection: View {
    @Binding var word: WordRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionBadge(number: "01", fill: Style.yellow, ink: Color(red: 0.48, green: 0.42, blue: 0.16))
                Text("The essentials")
                    .font(Style.heading(18))
                    .foregroundStyle(Style.ghost)
                Spacer()
                Text("2 REQUIRED")
                    .font(Style.heading(11))
                    .tracking(0.7)
                    .foregroundStyle(Color(red: 0.73, green: 0.42, blue: 0.31))
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background(Color(red: 1.0, green: 0.947, blue: 0.902), in: Capsule())
            }
            .padding(.bottom, 21)

            FormLabel(title: "Kwéyòl word or phrase", required: true)
            MockInput(hint: "e.g. woj", height: 60, text: $word.word)
                .padding(.top, 9)

            FormLabel(title: "English meaning", required: true)
                .padding(.top, 20)
            MockInput(hint: "e.g. red", height: 60, text: $word.meaning)
                .padding(.top, 9)
            FormLabel(title: "Part of speech")
                .padding(.top, 20)
            MockInput(hint: "e.g. Verb", height: 60, text: Binding(
                get: { word.partOfSpeech ?? "" }, set: { word.partOfSpeech = $0 }))
                .padding(.top, 9)
        }
        .padding(21)
        .background(.white, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(AddWordStyle.cardBorder, lineWidth: 1))
    }
}

private struct PronunciationSection: View {
    @Binding var word: WordRecord
    let onRecord: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionBadge(number: "02", fill: Color(red: 0.86, green: 0.80, blue: 0.96), ink: AddWordStyle.lilacInk)
                Text("OPTIONAL")
                    .font(Style.heading(12))
                    .tracking(1.0)
                    .foregroundStyle(AddWordStyle.lilacInk)
                Spacer()
            }

            HStack(spacing: 9) {
                Text("Make it sound right")
                    .font(Style.heading(24))
                    .foregroundStyle(Style.purpleInk)
                Sparkle(color: Style.coral, length: 10)
                    .frame(width: 20, height: 20)
            }
            .padding(.top, 10)

            Text("Save how the word actually sounds.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(AddWordStyle.lilacInk.opacity(0.82))
                .padding(.top, 5)

            FormLabel(title: "Pronunciation hint")
                .padding(.top, 21)
            MockInput(hint: "e.g. muh-jay", height: 59, tint: Color(red: 0.80, green: 0.74, blue: 0.92), fill: Color(red: 0.982, green: 0.969, blue: 1.0), text: $word.pronunciation)
                .padding(.top, 10)

            HStack(spacing: 12) {
                Image(systemName: "mic")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Style.coral)
                    .frame(width: 51, height: 51)
                    .background(Style.peach, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text(word.audioFile == nil ? "Record pronunciation" : "Replace pronunciation")
                        .font(Style.heading(15))
                        .foregroundStyle(Style.ghost)
                    Text("Ask a fluent speaker to say it")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Style.quiet)
                }
                Spacer(minLength: 0)
                Text("● Rec")
                    .font(Style.heading(14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .background(Style.coral, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .padding(.top, 16)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture(perform: onRecord)
            if word.audioFile != nil {
                Button("Play recording", action: onPlay)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Style.teal)
                    .padding(.top, 8)
                Button("Delete recording", action: onDelete)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Style.coral)
            }
        }
        .padding(22)
        .background(AddWordStyle.lilac, in: RoundedRectangle(cornerRadius: 25))
        .overlay(alignment: .topTrailing) {
            Circle()
                .strokeBorder(AddWordStyle.lilacInk.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 145, height: 145)
                .offset(x: 72, y: -75)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 25))
    }
}

private struct ExampleSection: View {
    @Binding var word: WordRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionBadge(number: "03", fill: Color(red: 0.86, green: 0.80, blue: 0.96), ink: Style.purpleInk)
                Text("Use it in a sentence")
                    .font(Style.heading(18))
                    .foregroundStyle(Style.ghost)
                Spacer()
                Text("OPTIONAL")
                    .font(Style.heading(11))
                    .tracking(0.9)
                    .foregroundStyle(Style.quiet)
            }

            Text("Give this word a little context.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 16)

            FormLabel(title: "Kwéyòl example sentence")
                .padding(.top, 22)
            MockInput(hint: "Type your example here...", height: 89, multiline: true, text: $word.example)
                .padding(.top, 10)

            FormLabel(title: "English translation")
                .padding(.top, 18)
            MockInput(hint: "What does the sentence mean?", height: 89, multiline: true, text: $word.translation)
                .padding(.top, 10)
        }
        .padding(22)
        .background(.white, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(AddWordStyle.cardBorder, lineWidth: 1))
    }
}

private struct WordCollectionsSection: View {
    let selectedCount: Int
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SectionBadge(number: "04", fill: Color(red: 0.79, green: 0.91, blue: 0.86), ink: Style.teal)
                Text("Add to collections")
                    .font(Style.heading(18))
                    .foregroundStyle(Style.teal)
                Spacer()
                Text("OPTIONAL")
                    .font(Style.heading(11))
                    .tracking(0.9)
                    .foregroundStyle(Style.quiet)
            }

            Text("Put this word in as many collections as you like.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 17)

            Button(action: onChoose) {
                HStack(spacing: 16) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Style.teal)
                        .frame(width: 55, height: 55)
                        .background(Color(red: 0.92, green: 0.97, blue: 0.94), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose collections")
                            .font(Style.heading(19))
                            .foregroundStyle(Style.ink)
                        Text("\(selectedCount) selected")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Style.quiet)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Style.ink)
                }
                .padding(.horizontal, 17)
                .frame(height: 77)
                .background(.white, in: RoundedRectangle(cornerRadius: 21))
                .contentShape(RoundedRectangle(cornerRadius: 21))
            }
            .buttonStyle(.plain)
            .padding(.top, 19)
        }
        .padding(22)
        .background(AddWordStyle.mint, in: RoundedRectangle(cornerRadius: 25))
    }
}

private struct AddWordCollectionOption: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tile: Color
    let ink: Color

    static func options(from collections: [CollectionExample]) -> [AddWordCollectionOption] {
        collections.map { collection in
            AddWordCollectionOption(id: collection.id, title: collection.title, icon: collection.icon, tile: collection.fill, ink: collection.ink)
        }
    }
}

private struct AddWordCollectionPickerSheet: View {
    let collections: [CollectionExample]
    @Binding var selectedIDs: Set<String>
    let onSaveCollection: (CollectionExample) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showCreateCollection = false

    private var visibleOptions: [AddWordCollectionOption] {
        let options = AddWordCollectionOption.options(from: collections)
        guard !searchText.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Collections")
                .font(Style.heading(28))
                .foregroundStyle(Style.ink)
                .padding(.top, 31)
            Text("Select one or more collections.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Style.quiet)
                .padding(.top, 4)

            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Style.quiet)
                TextField("Search collections...", text: $searchText)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .tint(Style.teal)
            }
            .padding(.horizontal, 18)
            .frame(height: 53)
            .background(Color(red: 0.96, green: 0.96, blue: 0.95), in: Capsule())
            .padding(.top, 21)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(visibleOptions) { option in
                        Button {
                            if selectedIDs.contains(option.id) {
                                selectedIDs.remove(option.id)
                            } else {
                                selectedIDs.insert(option.id)
                            }
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: option.icon)
                                    .font(.system(size: 23, weight: .semibold))
                                    .foregroundStyle(option.ink)
                                    .frame(width: 48, height: 48)
                                    .background(option.tile, in: RoundedRectangle(cornerRadius: 14))
                                Text(option.title)
                                    .font(Style.heading(18))
                                    .foregroundStyle(Style.teal)
                                Spacer()
                                Image(systemName: selectedIDs.contains(option.id) ? "checkmark" : "circle")
                                    .font(.system(size: selectedIDs.contains(option.id) ? 17 : 27, weight: .medium))
                                    .foregroundStyle(selectedIDs.contains(option.id) ? .white : Color(red: 0.58, green: 0.65, blue: 0.68))
                                    .frame(width: 32, height: 32)
                                    .background(selectedIDs.contains(option.id) ? Style.teal : .clear, in: Circle())
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 68)
                            .background(.white, in: RoundedRectangle(cornerRadius: 19))
                            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Style.ink.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.title), \(selectedIDs.contains(option.id) ? "selected" : "not selected")")
                    }

                    Button { showCreateCollection = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .bold))
                            Text("Create new collection")
                                .font(Style.heading(16))
                            Spacer()
                        }
                        .foregroundStyle(Style.teal)
                        .padding(.horizontal, 17)
                        .frame(height: 59)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 19))
                        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Style.teal.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 9)
                }
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            Button { dismiss() } label: {
                Text("Done")
                    .font(Style.heading(20))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(Style.teal, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 9)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.background.ignoresSafeArea())
        .sheet(isPresented: $showCreateCollection) {
            GeometryReader { geometry in
                let scale = geometry.size.width / 476
                ZStack(alignment: .bottom) {
                    Style.background.ignoresSafeArea()
                    CollectionEditorSheet(collection: nil, onClose: { showCreateCollection = false }) { collection in
                        onSaveCollection(collection)
                        selectedIDs.insert(collection.id)
                    }
                    .scaleEffect(scale, anchor: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                }
            }
            .presentationDetents([.height(650)])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(30)
        }
    }
}

private struct AddWordFooter: View {
    let onSave: () -> Void
    let enabled: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Style.teal)
                    .frame(width: 19, height: 19)
                    .background(Color(red: 0.79, green: 0.91, blue: 0.86), in: Circle())
                Text("Only the word and meaning are required")
                    .font(Style.heading(13))
                    .foregroundStyle(Color(red: 0.49, green: 0.59, blue: 0.53))
            }

            Button(action: onSave) { HStack {
                Text("Save word")
                    .font(Style.heading(19))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 22, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 21)
            .frame(height: 64)
            .background(Style.teal, in: RoundedRectangle(cornerRadius: 17)) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
        .padding(.horizontal, 23)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity)
        .background {
            Style.background
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(Style.ink.opacity(0.06)).frame(height: 1)
                }
        }
    }
}

private struct SectionBadge: View {
    let number: String
    let fill: Color
    let ink: Color

    var body: some View {
        Text(number)
            .font(Style.heading(15))
            .foregroundStyle(ink)
            .frame(width: 35, height: 35)
            .background(fill, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct FormLabel: View {
    let title: String
    var required = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(Style.ink)
            if required {
                Text("*")
                    .foregroundStyle(Style.coral)
            }
        }
        .font(Style.heading(15))
    }
}

private struct MockInput: View {
    let hint: String
    let height: CGFloat
    var tint: Color = AddWordStyle.border
    var fill: Color = AddWordStyle.field
    var multiline = false
    @Binding var text: String

    var body: some View {
        TextField(hint, text: $text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 3...5 : 1...1)
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(Color(red: 0.43, green: 0.47, blue: 0.45))
            .autocorrectionDisabled(hint == "e.g. woj" || hint == "Type your example here...")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: multiline ? .topLeading : .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, multiline ? 17 : 0)
            .background(fill, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint, lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
                if multiline {
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Style.ink.opacity(0.7))
                        .padding(8)
                }
            }
            .frame(height: height)
    }
}

private struct AddWordChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Style.heading(14))
            .foregroundStyle(Color(red: 0.35, green: 0.47, blue: 0.41))
            .padding(.horizontal, 17)
            .frame(height: 42)
            .background(.white, in: Capsule())
    }
}

private struct BottomNavigation: View {
    let selected: AppTab
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack {
            navigationItem("house", title: "Today", tab: .today)
            navigationItem("list.bullet.rectangle", title: "Library", tab: .library)
            navigationItem("square.grid.2x2", title: "Collections", tab: .collections)
            navigationItem("gearshape", title: "Settings", tab: .settings)
        }
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
        .background {
            Style.background
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(Style.ink.opacity(0.08)).frame(height: 1)
                }
        }
    }

    private func navigationItem(_ symbol: String, title: String, tab: AppTab) -> some View {
        Button {
            onSelect(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .frame(height: 27)
                Text(title)
                    .font(Style.heading(13))
            }
            .foregroundStyle(selected == tab ? Style.teal : Color(red: 0.37, green: 0.44, blue: 0.43))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

struct TodayScreen_Previews: PreviewProvider {
    static var previews: some View {
        TodayScreen()
    }
}

// MARK: - Sentence capture and extraction

private struct AddContentTypeSheet: View {
    let onWord: () -> Void
    let onSentence: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Text("What would you like to add?")
                .font(Style.heading(23))
                .foregroundStyle(Style.ink)
                .padding(.top, 31)
            option("Word or Phrase", subtitle: "Save an individual vocabulary item", symbol: "text.book.closed.fill", tint: Style.teal, tile: Style.paleYellow, action: onWord)
            option("Sentence", subtitle: "Save a complete Kwéyòl sentence", symbol: "text.quote", tint: Style.purpleInk, tile: Style.lavender, action: onSentence)
            Button("Cancel", action: onCancel)
                .font(Style.heading(16))
                .foregroundStyle(Style.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 51)
                .background(Style.mint, in: RoundedRectangle(cornerRadius: 15))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Style.background)
    }

    private func option(_ title: String, subtitle: String, symbol: String, tint: Color, tile: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tile, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Style.heading(17)).foregroundStyle(Style.ink)
                    Text(subtitle).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Style.teal)
            }
            .padding(13)
            .background(.white, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Style.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

private struct ExtractSelection: Identifiable, Equatable {
    let id = UUID()
    var indices: [Int]
    func title(_ tokens: [String]) -> String { indices.map { tokens[$0] }.joined(separator: " ") }
}

private struct SentenceFlowScreen: View {
    private enum Step { case editor, extract, wizard, duplicate }
    let collections: [CollectionExample]
    @ObservedObject var store: VocabularyStore
    let onClose: () -> Void
    let onDone: () -> Void
    let onOpenWord: (WordRecord) -> Void
    let onSaveCollection: (CollectionExample) -> Void

    @State private var sentence: SentenceRecord
    @State private var step: Step
    @State private var selections: [ExtractSelection] = []
    @State private var drafts: [WordRecord] = []
    @State private var wizardIndex = 0
    @State private var duplicateWord: WordRecord?
    @State private var selectedDuplicateSenseID: UUID?
    @State private var selectedTokenIndices: Set<Int> = []
    @State private var isGrouping = false
    @State private var showCollections = false
    @State private var recordingTarget: String?

    init(existing: SentenceRecord?, startAtExtract: Bool, collections: [CollectionExample], store: VocabularyStore, onClose: @escaping () -> Void, onDone: @escaping () -> Void, onOpenWord: @escaping (WordRecord) -> Void, onSaveCollection: @escaping (CollectionExample) -> Void) {
        self.collections = collections
        self.store = store
        self.onClose = onClose
        self.onDone = onDone
        self.onOpenWord = onOpenWord
        self.onSaveCollection = onSaveCollection
        _sentence = State(initialValue: existing ?? SentenceRecord(kweyol: "", english: ""))
        _step = State(initialValue: startAtExtract ? .extract : .editor)
    }

    private var tokens: [String] {
        sentence.kweyol.split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private var visibleTokenIndices: [Int] {
        guard !isGrouping else { return Array(tokens.indices) }
        return tokens.indices.filter { index in
            !selections.contains { $0.indices.count > 1 && $0.indices.contains(index) && $0.indices.first != index }
        }
    }
    private func savedSelection(startingAt index: Int) -> ExtractSelection? {
        selections.first { $0.indices.first == index }
    }
    private var selectedCollectionIDs: Binding<Set<String>> {
        Binding(get: { step == .wizard && drafts.indices.contains(wizardIndex) ? Set(drafts[wizardIndex].collectionIDs) : Set(sentence.collectionIDs) }, set: { ids in
            if step == .wizard && drafts.indices.contains(wizardIndex) { drafts[wizardIndex].collectionIDs = Array(ids) }
            else { sentence.collectionIDs = Array(ids) }
        })
    }
    private var editorValid: Bool { !sentence.kweyol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sentence.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var groupingValid: Bool {
        let indices = selectedTokenIndices.sorted()
        guard indices.count >= 2, let first = indices.first, let last = indices.last else { return false }
        return indices == Array(first...last)
    }

    var body: some View {
        VStack(spacing: 0) {
            SentenceFlowHeader(onBack: back, onCancel: close)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .editor: editorContent
                    case .extract: extractContent
                    case .wizard: wizardContent
                    case .duplicate: duplicateContent
                    }
                }
                .padding(.horizontal, 23)
                .padding(.top, 17)
                .padding(.bottom, 30)
            }
            if step != .duplicate { footer }
        }
        .background(Style.background)
        .onChange(of: sentence.kweyol) { _, _ in
            cleanupDraftAudio()
            selections.removeAll()
            selectedTokenIndices.removeAll()
            isGrouping = false
            drafts.removeAll()
            wizardIndex = 0
        }
        .sheet(isPresented: $showCollections) {
            AddWordCollectionPickerSheet(collections: collections, selectedIDs: selectedCollectionIDs, onSaveCollection: onSaveCollection)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
        .fullScreenCover(isPresented: Binding(get: { recordingTarget != nil }, set: { if !$0 { recordingTarget = nil } })) {
            GeometryReader { geometry in
                let scale = geometry.size.width / 476
                RecordingScreen(word: recordingWord, onBack: { recordingTarget = nil }, onSave: { filename in
                    if recordingTarget == "sentence" {
                        if sentence.audioFile != store.sentence(sentence.id)?.audioFile { store.removeAudio(sentence.audioFile) }
                        sentence.audioFile = filename
                    }
                    else if drafts.indices.contains(wizardIndex) { store.removeAudio(drafts[wizardIndex].audioFile); drafts[wizardIndex].audioFile = filename }
                    recordingTarget = nil
                }, store: store)
                .frame(width: 476, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .background(Style.background.ignoresSafeArea())
        }
    }

    private var recordingWord: WordRecord {
        if recordingTarget == "sentence" { return WordRecord(word: sentence.kweyol, meaning: sentence.english) }
        return drafts.indices.contains(wizardIndex) ? drafts[wizardIndex] : WordRecord(word: "", meaning: "")
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            flowTitle(kicker: "SAVE A COMPLETE THOUGHT", title: "Add Sentence", subtitle: "Capture a sentence just as you heard it.")
            VStack(alignment: .leading, spacing: 15) {
                FlowField(title: "Kwéyòl sentence", required: true, placeholder: "Type the sentence in Kwéyòl", text: $sentence.kweyol)
                FlowField(title: "English translation", required: true, placeholder: "What does the sentence mean?", text: $sentence.english)
                FlowField(title: "Pronunciation hint", required: false, placeholder: "How does the full sentence sound?", text: $sentence.pronunciation)
            }
            .padding(17)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Style.ink.opacity(0.08)))
            recordingButton(sentence.audioFile, target: "sentence", title: "Record sentence pronunciation")
            Text("A little more detail")
                .font(Style.heading(19))
                .foregroundStyle(Style.ink)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 16) {
                FlowField(title: "Notes", required: false, placeholder: "Where did you hear this? Any context?", text: $sentence.notes, multiline: true)
                collectionButton(count: sentence.collectionIDs.count)
            }
            .padding(17)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Style.ink.opacity(0.08)))
        }
    }

    private var extractContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            flowTitle(kicker: "FROM SENTENCE TO VOCABULARY", title: "Extract words\n& phrases", subtitle: "You decide what becomes vocabulary.")
            VStack(alignment: .leading, spacing: 7) {
                Text("ORIGINAL KWÉYÒL SENTENCE")
                    .font(Style.heading(12)).tracking(1.2).foregroundStyle(Style.teal)
                Text(sentence.kweyol).font(Style.heading(19)).foregroundStyle(Style.ink)
                Text(sentence.english).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.08)))
            Text("TAP WORDS TO SELECT")
                .font(Style.heading(12)).tracking(1.2).foregroundStyle(Style.teal)
                .padding(.top, 4)
            FlowWrap(spacing: 8) {
                ForEach(visibleTokenIndices, id: \.self) { index in
                    let saved = savedSelection(startingAt: index)
                    let selected = selections.contains(where: { $0.indices.contains(index) }) || selectedTokenIndices.contains(index)
                    Button { toggleToken(index) } label: {
                        Text(isGrouping ? tokens[index] : saved?.title(tokens) ?? tokens[index])
                            .font(Style.heading(16))
                            .foregroundStyle(selected ? Style.teal : Style.quiet)
                            .padding(.horizontal, 13).frame(height: 42)
                            .background(selected ? Style.mint : Color(red: 0.95, green: 0.96, blue: 0.95), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selectedTokenIndices.contains(index) ? Style.teal : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }
            Button { if isGrouping { groupSelected() } else { isGrouping = true; selectedTokenIndices.removeAll() } } label: {
                HStack {
                    Image(systemName: "link")
                    Text(isGrouping ? "Save selected phrase" : "Group adjacent words as a phrase")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(Style.heading(14))
                .foregroundStyle(Style.purpleInk)
                .padding(14)
                .background(Style.lavender.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isGrouping && !groupingValid)
            .opacity(isGrouping && !groupingValid ? 0.55 : 1)
            if isGrouping {
                Text("Select two or more adjacent words.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                Button("Cancel grouping") { isGrouping = false; selectedTokenIndices.removeAll() }
                    .font(Style.heading(13)).foregroundStyle(Style.quiet).buttonStyle(.plain)
            }
            HStack {
                Text("Your selections").font(Style.heading(20)).foregroundStyle(Style.ink)
                Text("\(selections.count) items").font(Style.heading(13)).foregroundStyle(Style.teal).padding(.horizontal, 10).padding(.vertical, 7).background(Style.mint, in: Capsule())
            }
            .padding(.top, 6)
            if selections.isEmpty {
                Text("Tap a word, or select adjacent words and group them as a phrase.")
                    .font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 17))
            } else {
                ForEach(selections.sorted { ($0.indices.first ?? 0) < ($1.indices.first ?? 0) }) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.indices.count == 1 ? "checkmark" : "link")
                            .foregroundStyle(item.indices.count == 1 ? Style.teal : Style.purpleInk)
                            .frame(width: 34, height: 34)
                            .background(item.indices.count == 1 ? Style.mint : Style.lavender, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title(tokens)).font(Style.heading(18)).foregroundStyle(Style.ink)
                            Text(item.indices.count == 1 ? "Single word" : "Saved together as phrase")
                                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                        }
                        Spacer()
                        Button { selections.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark").foregroundStyle(Style.quiet) }.buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(Style.ink.opacity(0.08)))
                }
            }
            Text("Nothing is added to vocabulary until you review and confirm each selection. Hyphenated words stay together.")
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Style.mint.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var wizardContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center) {
                flowTitle(kicker: "REVIEW BEFORE SAVING", title: "Create Vocabulary", subtitle: "Add the meaning in your own words.")
                Spacer(minLength: 4)
                Text("\(wizardIndex + 1) OF \(drafts.count)")
                    .font(Style.heading(12)).foregroundStyle(Style.purpleInk)
                    .padding(.horizontal, 10).padding(.vertical, 7).background(Style.lavender, in: Capsule())
            }
            if drafts.indices.contains(wizardIndex) {
                let index = wizardIndex
                VStack(alignment: .leading, spacing: 3) {
                    Text(drafts[index].word).font(Style.heading(28)).foregroundStyle(Style.ink)
                    Text(selections.indices.contains(index) && selections[index].indices.count > 1 ? "PHRASE · FROM YOUR SENTENCE" : "WORD · FROM YOUR SENTENCE")
                        .font(Style.heading(12)).foregroundStyle(Style.purpleInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(17)
                .background(Style.lavender.opacity(0.55), in: RoundedRectangle(cornerRadius: 19))
                VStack(alignment: .leading, spacing: 14) {
                    FlowField(title: "Kwéyòl word or phrase", required: true, placeholder: "Word or phrase", text: $drafts[index].word)
                    FlowField(title: "English meaning", required: true, placeholder: "What does it mean?", text: $drafts[index].meaning)
                    FlowField(title: "Pronunciation hint", required: false, placeholder: "Type how it sounds...", text: $drafts[index].pronunciation)
                    recordingButton(drafts[index].audioFile, target: "word", title: "Record pronunciation")
                }
                .padding(17).background(.white, in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).stroke(Style.ink.opacity(0.08)))
                Text("From your saved sentence").font(Style.heading(19)).foregroundStyle(Style.ink)
                VStack(alignment: .leading, spacing: 12) {
                    if !drafts[index].example.isEmpty {
                        HStack {
                            Text("Kwéyòl example").font(Style.heading(14))
                            Spacer()
                            Button { drafts[index].example = "" } label: { Image(systemName: "xmark").foregroundStyle(Style.coral) }.buttonStyle(.plain)
                        }
                        Text(drafts[index].example).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    }
                    if !drafts[index].translation.isEmpty {
                        Divider()
                        HStack {
                            Text("English translation").font(Style.heading(14))
                            Spacer()
                            Button { drafts[index].translation = "" } label: { Image(systemName: "xmark").foregroundStyle(Style.coral) }.buttonStyle(.plain)
                        }
                        Text(drafts[index].translation).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    }
                    if drafts[index].example.isEmpty && drafts[index].translation.isEmpty {
                        Text("No sentence attached to this entry.").font(.system(size: 14, design: .rounded)).foregroundStyle(Style.quiet)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.96, green: 0.96, blue: 0.94), in: RoundedRectangle(cornerRadius: 17))
                Text("Collections · optional").font(Style.heading(19)).foregroundStyle(Style.ink)
                collectionButton(count: drafts[index].collectionIDs.count)
            }
        }
    }

    private var duplicateContent: some View {
        VStack(alignment: .leading, spacing: 17) {
            flowTitle(kicker: "EXISTING VOCABULARY", title: "Check for duplicates", subtitle: "We’ll ask before making another entry.")
            if let duplicateWord {
                let candidates = store.senses(for: duplicateWord)
                let selectedSense = candidates.first { $0.id == selectedDuplicateSenseID }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark").font(Style.heading(22)).foregroundStyle(Style.coral)
                            .frame(width: 38, height: 38).background(Style.paleYellow, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(duplicateWord.word) already exists").font(Style.heading(19)).foregroundStyle(Style.ink)
                            Text(candidates.count == 1 ? "Meaning: \(duplicateWord.meaning)" : "\(candidates.count) saved meanings")
                                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                        }
                    }
                    Divider().padding(.vertical, 5)
                    Text("New sentence you just saved").font(Style.heading(14)).foregroundStyle(Style.ink)
                    Text(sentence.kweyol).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    Text(sentence.english).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                }
                .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
                if candidates.count > 1 {
                    Text("Which meaning does this sentence illustrate?")
                        .font(Style.heading(16)).foregroundStyle(Style.ink)
                    ForEach(candidates) { candidate in
                        Button { selectedDuplicateSenseID = candidate.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedDuplicateSenseID == candidate.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Style.teal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.meaning).font(Style.heading(15)).foregroundStyle(Style.ink)
                                    Text("Entry \(candidate.homonym) · Meaning \(candidate.sense)\(candidate.partOfSpeech.map { " · \($0)" } ?? "")")
                                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Style.quiet)
                                }
                                Spacer()
                            }
                            .padding(13).background(.white, in: RoundedRectangle(cornerRadius: 15))
                        }.buttonStyle(.plain)
                    }
                }
                Text("What would you like to do?").font(Style.heading(19)).foregroundStyle(Style.ink)
                duplicateOption("Add this sentence as another example", subtitle: "Keep the existing word and add context", icon: "plus", tint: Style.teal, fill: Style.mint) {
                    guard let selectedSense else { return }
                    store.addExample(to: selectedSense.id, from: sentence)
                    advanceWizard()
                }
                .disabled(selectedSense == nil)
                .opacity(selectedSense == nil ? 0.45 : 1)
                duplicateOption("Open existing entry", subtitle: "View or edit the saved word", icon: "text.book.closed.fill", tint: Style.purpleInk, fill: Style.lavender) {
                    cleanupDraftAudio()
                    onOpenWord(duplicateWord)
                }
                duplicateOption("Skip this word", subtitle: "No duplicate will be created", icon: "arrow.uturn.backward", tint: Style.coral, fill: Style.peach) {
                    advanceWizard()
                }
                Text("Your original sentence remains saved whichever option you choose.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.91, green: 0.96, blue: 0.98), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .editor {
                VStack(spacing: 9) {
                    Button { saveSentence(); step = .extract } label: {
                        HStack { Text("Extract Words & Phrases"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(Style.heading(16)).foregroundStyle(Style.purpleInk)
                            .padding(.horizontal, 17).frame(height: 49)
                            .background(Style.lavender, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).disabled(!editorValid).opacity(editorValid ? 1 : 0.5)
                    FlowPrimaryButton(title: "Save Sentence", enabled: editorValid) { saveSentence(); onDone() }
                }
            } else if step == .extract {
                FlowPrimaryButton(title: "Create Vocabulary (\(selections.count))", enabled: !selections.isEmpty) { startWizard() }
            } else if step == .wizard {
                Button("Skip") { advanceWizard() }
                    .font(Style.heading(15)).foregroundStyle(Style.coral)
                    .frame(width: 58, height: 53)
                FlowPrimaryButton(title: wizardIndex == drafts.count - 1 ? "Save Vocabulary" : "Save & Next", enabled: canSaveCurrentDraft) { saveVocabulary() }
            }
        }
        .padding(.horizontal, 23).padding(.top, 12).padding(.bottom, 10)
        .background(Style.background.shadow(.drop(color: Style.ink.opacity(0.07), radius: 9, y: -3)))
    }

    private func flowTitle(kicker: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker).font(Style.heading(12)).tracking(1.15).foregroundStyle(Style.coral)
            (Text(title).foregroundColor(Style.ink) + Text(".").foregroundColor(Style.coral))
                .font(Style.heading(37)).tracking(-1.4).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 5)
    }
    private func recordingButton(_ audio: String?, target: String, title: String) -> some View {
        Button { if audio != nil { store.playAudio(audio) } else { recordingTarget = target } } label: {
            HStack(spacing: 12) {
                Image(systemName: audio == nil ? "music.note" : "play.fill")
                    .font(.system(size: 18, weight: .bold)).frame(width: 34, height: 34)
                    .background(Style.lavender, in: RoundedRectangle(cornerRadius: 10))
                Text(audio == nil ? title : "Play pronunciation")
                    .font(Style.heading(15))
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(Style.purpleInk).padding(.horizontal, 13).frame(height: 56)
            .background(Style.lavender.opacity(0.72), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if audio != nil {
                Button("Record again") { recordingTarget = target }
                Button("Delete recording", role: .destructive) {
                    if target == "sentence" {
                        if audio != store.sentence(sentence.id)?.audioFile { store.removeAudio(audio) }
                        sentence.audioFile = nil
                    } else if drafts.indices.contains(wizardIndex) {
                        store.removeAudio(audio)
                        drafts[wizardIndex].audioFile = nil
                    }
                }
            }
        }
    }
    private func collectionButton(count: Int) -> some View {
        Button { showCollections = true } label: {
            HStack(spacing: 13) {
                Image(systemName: "square.3.layers.3d").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Style.teal).frame(width: 42, height: 42)
                    .background(Style.mint, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose collections").font(Style.heading(17)).foregroundStyle(Style.ink)
                    Text("\(count) selected").font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Style.quiet)
            }
            .padding(13).background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Style.ink.opacity(0.08)))
        }.buttonStyle(.plain)
    }
    private func duplicateOption(_ title: String, subtitle: String, icon: String, tint: Color, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundStyle(tint)
                .frame(width: 38, height: 38).background(fill, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Style.heading(16)).foregroundStyle(Style.ink)
                Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Style.teal)
        }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Style.ink.opacity(0.08))) }.buttonStyle(.plain)
    }

    private func saveSentence() {
        store.upsert(sentence)
    }
    private func toggleToken(_ index: Int) {
        if isGrouping {
            if !selectedTokenIndices.insert(index).inserted { selectedTokenIndices.remove(index) }
            return
        }
        if let existing = selections.first(where: { $0.indices.contains(index) }) {
            selections.removeAll { $0.id == existing.id }
            return
        }
        selections.append(ExtractSelection(indices: [index]))
    }
    private func groupSelected() {
        let indices = selectedTokenIndices.sorted()
        guard indices.count >= 2, indices == Array((indices.first!)...(indices.last!)) else { return }
        selections.removeAll { !$0.indices.filter(indices.contains).isEmpty }
        selections.append(ExtractSelection(indices: indices))
        selectedTokenIndices.removeAll()
        isGrouping = false
    }
    private func startWizard() {
        cleanupDraftAudio()
        selections.sort { ($0.indices.first ?? 0) < ($1.indices.first ?? 0) }
        drafts = selections.map { selection in
            WordRecord(word: selection.title(tokens), meaning: "", example: sentence.kweyol, translation: sentence.english, collectionIDs: sentence.collectionIDs)
        }
        wizardIndex = 0
        step = .wizard
    }
    private func saveVocabulary() {
        guard drafts.indices.contains(wizardIndex) else { return }
        var draft = drafts[wizardIndex]
        draft.word = draft.word.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.meaning = draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.word.isEmpty else { return }
        drafts[wizardIndex] = draft
        if let existing = store.duplicate(of: draft.word) {
            duplicateWord = existing
            let candidates = store.senses(for: existing)
            selectedDuplicateSenseID = candidates.count == 1 ? candidates.first?.id : nil
            step = .duplicate
        } else {
            guard !draft.meaning.isEmpty else { return }
            store.upsert(draft)
            advanceWizard()
        }
    }
    private var canSaveCurrentDraft: Bool {
        guard drafts.indices.contains(wizardIndex) else { return false }
        let draft = drafts[wizardIndex]
        let word = draft.word.trimmingCharacters(in: .whitespacesAndNewlines)
        return !word.isEmpty && (!draft.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.duplicate(of: word) != nil)
    }
    private func advanceWizard() {
        if drafts.indices.contains(wizardIndex), store.word(drafts[wizardIndex].id) == nil { store.removeAudio(drafts[wizardIndex].audioFile) }
        duplicateWord = nil
        selectedDuplicateSenseID = nil
        if wizardIndex + 1 < drafts.count { wizardIndex += 1; step = .wizard }
        else { onDone() }
    }
    private func back() {
        switch step {
        case .editor: close()
        case .extract: step = .editor
        case .wizard: step = .extract
        case .duplicate: step = .wizard
        }
    }
    private func close() {
        if sentence.audioFile != store.sentence(sentence.id)?.audioFile { store.removeAudio(sentence.audioFile) }
        cleanupDraftAudio()
        onClose()
    }
    private func cleanupDraftAudio() {
        for draft in drafts where store.word(draft.id) == nil { store.removeAudio(draft.audioFile) }
    }
}

private struct SentenceFlowHeader: View {
    let onBack: () -> Void
    let onCancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Style.teal).frame(width: 46, height: 46)
                    .background(Style.mint, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
            BrandLockup()
            Spacer()
            Button("Cancel", action: onCancel)
                .font(Style.heading(14)).foregroundStyle(Style.teal).buttonStyle(.plain)
        }
        .padding(.horizontal, 23).frame(height: 67).background(Style.background)
    }
}

private struct FlowPrimaryButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.up.right") }
                .font(Style.heading(17)).foregroundStyle(.white)
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 55)
                .background(Style.teal, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }
}

private struct FlowField: View {
    let title: String
    let required: Bool
    let placeholder: String
    @Binding var text: String
    var multiline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(Style.teal)
                if required { Text("*").foregroundStyle(Style.coral) }
                else { Text("(optional)").foregroundStyle(Style.quiet) }
            }.font(Style.heading(15))
            if multiline {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty { Text(placeholder).foregroundStyle(Style.quiet).padding(.leading, 5).padding(.top, 8) }
                    TextEditor(text: $text).scrollContentBackground(.hidden).opacity(text.isEmpty ? 0.65 : 1)
                }
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(Style.ink).padding(12).frame(height: 89)
                .background(AddWordStyle.field, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AddWordStyle.border, lineWidth: 2))
            } else {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(Style.ink).tint(Style.teal)
                    .autocorrectionDisabled(title.contains("Kwéyòl"))
                    .lineLimit(1...3)
                    .padding(.horizontal, 16).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .background(AddWordStyle.field, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AddWordStyle.border, lineWidth: 2))
            }
        }
    }
}

private struct FlowWrap: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(proposal: proposal, subviews: subviews).positions
        for (index, point) in positions.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified) }
    }
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let width = proposal.width ?? 430
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}

private struct SentenceDetailScreen: View {
    let sentence: SentenceRecord
    @ObservedObject var store: VocabularyStore
    let onBack: () -> Void
    let onEdit: () -> Void
    let onExtract: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false
    var body: some View {
        VStack(spacing: 0) {
            SentenceFlowHeader(onBack: onBack, onCancel: onBack)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Saved sentence.").font(Style.heading(38)).foregroundStyle(Style.ink)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("KWÉYÒL").font(Style.heading(12)).tracking(1.1).foregroundStyle(Style.teal)
                        Text(sentence.kweyol).font(Style.heading(28)).foregroundStyle(Style.ink)
                        Divider()
                        Text("ENGLISH").font(Style.heading(12)).tracking(1.1).foregroundStyle(Style.teal)
                        Text(sentence.english).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(Style.quiet)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    if !sentence.pronunciation.isEmpty { detailRow("Pronunciation hint", text: sentence.pronunciation) }
                    if let audio = sentence.audioFile {
                        Button { store.playAudio(audio) } label: { Label("Play pronunciation", systemImage: "play.fill").font(Style.heading(17)).foregroundStyle(Style.purpleInk).frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Style.lavender, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain)
                    }
                    if !sentence.notes.isEmpty { detailRow("Notes", text: sentence.notes) }
                    if !sentence.collectionIDs.isEmpty { detailRow("Collections", text: sentence.collectionIDs.map(store.collectionTitle).joined(separator: ", ")) }
                }
                .padding(.horizontal, 23).padding(.top, 20)
            }
            VStack(spacing: 9) {
                Button(action: onExtract) { HStack { Text("Extract Words & Phrases"); Spacer(); Image(systemName: "arrow.up.right") }.font(Style.heading(17)).foregroundStyle(.white).padding(.horizontal, 18).frame(height: 55).background(Style.teal, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain)
                Button("Edit sentence", action: onEdit).font(Style.heading(15)).foregroundStyle(Style.teal).frame(height: 40).buttonStyle(.plain)
                Button("Delete sentence", role: .destructive) { confirmDelete = true }
                    .font(Style.heading(13)).foregroundStyle(Style.coral).frame(height: 30).buttonStyle(.plain)
            }
            .padding(.horizontal, 23).padding(.top, 10).padding(.bottom, 8)
            .background(Style.background)
        }
        .background(Style.background)
        .confirmationDialog("Delete this sentence?", isPresented: $confirmDelete) {
            Button("Delete sentence", role: .destructive, action: onDelete)
        }
    }
    private func detailRow(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Style.heading(14)).foregroundStyle(Style.teal)
            Text(text).font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(Style.ink)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }
}
