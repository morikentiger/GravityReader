import AppKit

class GravityCaptureManager {
    private var statusBar: StatusBarController?
    var logWindow: LogWindowController?
    private var timer: Timer?
    let speechManager = SpeechManager()
    var yuiManager: YUiManager?
    var roomTranscription: RoomTranscriptionManager?
    private let gravityBundleID = "com.hiclub.gravity"
    private let pollInterval: TimeInterval = 2.0

    /// 一度読み上げたテキストはセッション中ずっと記憶（再読み上げしない）
    private var spokenHistory: Set<String> = []

    /// 前回ポーリングで取得したテキスト一覧（差分検出用）
    private var previousSnapshot: [String] = []

    private var isFirstPoll = true

    /// 直前に検出されたユーザー名（メッセージの発言者推定用）
    private var lastDetectedUser: String?

    /// 検出済みの全ユーザー名（フルネーム）
    private(set) var detectedUsers: [String] = []

    /// ユーザー一覧が更新されたときのコールバック
    var onUsersUpdated: (([String]) -> Void)?

    /// 現在の音声ルーム参加者
    private(set) var currentParticipants: [String] = []

    /// 全員見えてるのにリストにいなかった連続回数（名前→回数）
    private var missingCount: [String: Int] = [:]

    /// この回数連続で見えなかったら退出確定
    private let missingThreshold = 3


    /// 参加/退出の正規表現
    private let joinPattern: NSRegularExpression? = {
        // "ぬぬ が音声ルームに参加しました" or "鼻セレブ (初見)が音声ルームに参加しました"
        try? NSRegularExpression(pattern: #"^(.+?)(?:\s*\(.+?\))?\s*が音声ルームに参加しました$"#)
    }()
    private let leavePattern: NSRegularExpression? = {
        // "XXX が退出しました" or "XXX が音声ルームから退出しました"
        try? NSRegularExpression(pattern: #"^(.+?)(?:\s*\(.+?\))?\s*が(?:音声ルームから)?退出しました$"#)
    }()

    // MARK: - UIノイズフィルタ

    /// 完全一致で除外するUIテキスト
    private let uiNoiseExact: Set<String> = [
        "GRAVITY", "ゲスト", "参加メンバー", "メッセージを送信",
        "公開音声ルーム", "ランキング>>", "アナウンス >>",
        "不適切なワードが含まれています。",
    ]

    /// 前方一致で除外するパターン
    private let uiNoisePrefixes = [
        "AI社長が訊く",
    ]

    /// 正規表現で除外するパターン
    private let uiNoisePatterns: [NSRegularExpression] = {
        let patterns = [
            #"^\d{1,3}%$"#,             // "100%", "23%" 等のパーセンテージ
            #"^\d{1,2}$"#,              // "2", "3" 等の単独数字
            #"^あと\d+日$"#,             // "あと6日" 等のカウントダウン
            #"^(初級|中級|上級|特級|超級)\d+$"#,  // "初級60000" 等のランク表示
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// ユーザー名っぽいパターン（「名前, タグ」形式）
    private let userNamePattern: NSRegularExpression? = {
        // "ぴうセポネ。🐣ྀི" や "まきねこ🐈, XOXO" や "もりけん社長🥕🥩[オーナー]" 等
        try? NSRegularExpression(pattern: #"^(.+),\s*.+$"#)
    }()

    /// 通知バナーに含まれるキーワード（ユーザー名として誤検出を防止）
    private let notificationKeywords = [
        "ミッション", "達成", "レアアイテム", "GET可能", "特典", "ランキング",
        "アイテム", "ガチャ", "コイン", "ポイント", "報酬", "イベント",
        "キャンペーン", "アップデート", "メンテナンス", "お知らせ",
    ]

    /// ボイスコマンドパターン: "!voice ユーザー名 声の名前" や "！声　ぺんぽん　ずんだもん"
    /// 半角・全角スペース両対応
    private let voiceCommandPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[!！](voice|声)[\s\u{3000}]+(.+?)[\s\u{3000}]+(.+)$"#)
    }()

    /// 読み辞書コマンド: "!読み 辛い つらい" or "!yomi C3PO シースリーピーオー"
    private let readingCommandPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[!！](読み|yomi)[\s\u{3000}]+(.+?)[\s\u{3000}]+(.+)$"#)
    }()

    /// 読み辞書削除コマンド: "!読み削除 辛い" or "!yomi-del C3PO"
    private let readingDeletePattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[!！](読み削除|yomi-del)[\s\u{3000}]+(.+)$"#)
    }()

    /// 読み辞書一覧: "!読み一覧" or "!yomi-list"
    private let readingListPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[!！](読み一覧|yomi-list)[\s\u{3000}]*$"#)
    }()

    private func isUINoiseOrSystemMessage(_ text: String) -> Bool {
        if uiNoiseExact.contains(text) { return true }
        for prefix in uiNoisePrefixes {
            if text.hasPrefix(prefix) { return true }
        }
        let range = NSRange(text.startIndex..., in: text)
        for regex in uiNoisePatterns {
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }
        if text.count <= 1 { return true }
        return false
    }

    /// 通知バナーかどうか判定
    private func isNotificationBanner(_ text: String) -> Bool {
        for keyword in notificationKeywords {
            if text.contains(keyword) { return true }
        }
        return false
    }

    /// ユーザー名パターンかどうか（"名前, タグ" 形式）
    private func extractUserName(_ text: String) -> String? {
        // 通知バナーはユーザー名ではない
        if isNotificationBanner(text) { return nil }
        guard let regex = userNamePattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let nameRange = Range(match.range(at: 1), in: text) {
            return String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// テキストが既知の参加者名かどうか判定し、マッチした名前を返す（カンマなしの名前も検出）
    private func matchKnownParticipant(_ text: String) -> String? {
        // 参加者リストの名前と一致するか
        for participant in currentParticipants {
            if text == participant { return participant }
            if participant.contains(text) || text.contains(participant) { return participant }
        }
        // 検出済みユーザー名と一致するか
        for user in detectedUsers {
            if text == user { return user }
            if user.contains(text) || text.contains(user) { return user }
        }
        return nil
    }

    /// ユーザーをリストに登録（重複しない）
    private func registerUser(_ fullName: String) {
        if !detectedUsers.contains(fullName) {
            detectedUsers.append(fullName)
            onUsersUpdated?(detectedUsers)
        }
    }

    /// 部分一致でフルネームを解決（「ナポリタン」→「ナポリタン🍝」等）
    func resolveUserName(_ partial: String) -> String? {
        // 完全一致優先
        if detectedUsers.contains(partial) { return partial }
        if currentParticipants.contains(partial) { return partial }
        // 部分一致（含む）— detectedUsers + currentParticipants 両方を検索
        let allKnown = Set(detectedUsers + currentParticipants)
        let matches = allKnown.filter { $0.contains(partial) }
        if matches.count == 1 { return matches.first }
        // ユーザーのボイスマップのキーも検索
        let mapMatches = speechManager.allUserVoiceAssignments().keys.filter { $0.contains(partial) }
        if mapMatches.count == 1 { return mapMatches.first }
        // 複数ヒットなら最短名を返す
        let all = Array(matches) + Array(mapMatches)
        if let shortest = all.min(by: { $0.count < $1.count }) { return shortest }
        // ヒットなし → そのまま登録して返す（新規ユーザーとして扱う）
        registerUser(partial)
        return partial
    }

    /// ボイスコマンドを検出して処理。処理した場合trueを返す
    /// 形式: "!声 ユーザー名 声の名前" (例: "!声 ナポリタン ずんだもん")
    private func handleVoiceCommand(_ text: String) -> Bool {
        guard let regex = voiceCommandPattern else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let userRange = Range(match.range(at: 2), in: text),
              let voiceNameRange = Range(match.range(at: 3), in: text) else { return false }

        let partialUser = String(text[userRange]).trimmingCharacters(in: .whitespaces)
        let voiceName = String(text[voiceNameRange]).trimmingCharacters(in: .whitespaces)
        let user = resolveUserName(partialUser) ?? partialUser

        // "システム" or "system" → システム音声に戻す
        if voiceName == "システム" || voiceName.lowercased() == "system" {
            speechManager.setVoiceForUser(user, mode: .system)
            logWindow?.addEntry("🎤 \(user) の声をシステム音声に変更しました")
            return true
        }

        // VOICEVOXスピーカーを名前で検索
        if let speaker = speechManager.findSpeakerByName(voiceName) {
            speechManager.setVoiceForUser(user, mode: .voicevox(speaker.id))
            logWindow?.addEntry("🎤 \(user) の声を \(speaker.name)（\(speaker.style)）に変更しました")
            return true
        }

        logWindow?.addEntry("⚠️ 「\(voiceName)」は見つかりませんでした。VOICEVOXのキャラクター名を指定してください")
        return true // コマンドとしては認識した
    }

    /// 読み辞書コマンドを検出して処理。処理した場合trueを返す
    private func handleReadingCommand(_ text: String) -> Bool {
        // 全角スペースも含めてトリム
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
        // !読み or ！読み で始まらなければ即リターン
        guard trimmed.hasPrefix("!読み") || trimmed.hasPrefix("！読み")
           || trimmed.hasPrefix("!yomi") || trimmed.hasPrefix("！yomi") else { return false }

        let range = NSRange(trimmed.startIndex..., in: trimmed)

        // 一覧: !読み一覧（先にチェック — 登録パターンより前に）
        if let regex = readingListPattern,
           regex.firstMatch(in: trimmed, range: range) != nil {
            let entries = speechManager.readingDictionaryEntries()
            if entries.isEmpty {
                logWindow?.addEntry("📖 読み辞書は空です")
            } else {
                logWindow?.addEntry("📖 読み辞書一覧:")
                for entry in entries {
                    logWindow?.addEntry("   \(entry.word) → \(entry.reading)")
                }
            }
            return true
        }

        // 削除: !読み削除 辛い
        if let regex = readingDeletePattern,
           let match = regex.firstMatch(in: trimmed, range: range),
           let wordRange = Range(match.range(at: 2), in: trimmed) {
            let word = String(trimmed[wordRange]).trimmingCharacters(in: .whitespaces)
            speechManager.removeReading(word: word)
            logWindow?.addEntry("📖 読み辞書削除: \(word)")
            return true
        }

        // 登録: !読み 辛い つらい
        if let regex = readingCommandPattern,
           let match = regex.firstMatch(in: trimmed, range: range),
           let wordRange = Range(match.range(at: 2), in: trimmed),
           let readingRange = Range(match.range(at: 3), in: trimmed) {
            let word = String(trimmed[wordRange]).trimmingCharacters(in: .whitespaces)
            let reading = String(trimmed[readingRange]).trimmingCharacters(in: .whitespaces)
            speechManager.registerReading(word: word, reading: reading)
            logWindow?.addEntry("📖 読み辞書登録: \(word) → \(reading)")
            return true
        }

        return false
    }

    // MARK: - 参加者トラッキング

    /// AXツリーの生テキストから「参加メンバー」セクションを解析
    /// リスト終端（次のUIセクション）が見えたら全員見えている→いない人は退出確定
    /// リスト終端が見えない（スクロールで途切れ）→追加のみ、退出判定しない
    private func parseParticipantList(_ allTexts: [String]) {
        guard let startIdx = allTexts.firstIndex(of: "参加メンバー") else { return }

        var visibleMembers: [String] = []
        var listEndFound = false  // リストの終端（=次のUIセクション）が見えたか

        let sectionStopWords: Set<String> = [
            "GRAVITY", "メッセージを送信", "公開音声ルーム",
            "ランキング>>", "アナウンス >>",
        ]

        for i in (startIdx + 1)..<allTexts.count {
            let text = allTexts[i]
            if sectionStopWords.contains(text) {
                // 次のセクションに到達 = リスト全体が見えている
                listEndFound = true
                break
            }
            if text == "ゲスト" { continue }
            if isUINoiseOrSystemMessage(text) {
                listEndFound = true
                break
            }

            let name = text.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                visibleMembers.append(name)
            }
        }

        guard !visibleMembers.isEmpty else { return }

        // 見えたメンバーを追加
        var changed = false
        for member in visibleMembers {
            registerUser(member)
            if !currentParticipants.contains(where: { $0 == member || $0.contains(member) || member.contains($0) }) {
                currentParticipants.append(member)
                changed = true
            }
        }

        // リスト全体が見えている場合のみ退出判定
        // 条件: リストの下端が見えている AND もりけんが見えている（=上が切れてない）
        let topVisible = visibleMembers.contains(where: { $0.contains("もりけん") })
        if listEndFound && topVisible {
            // 見えてない人のカウントを増やす
            for participant in currentParticipants {
                let found = visibleMembers.contains(participant)
                    || visibleMembers.contains(where: { $0.contains(participant) || participant.contains($0) })
                if !found {
                    missingCount[participant, default: 0] += 1
                } else {
                    missingCount[participant] = 0
                }
            }

            // 連続で見えなかった人を退出扱い
            var removed: [String] = []
            currentParticipants.removeAll { participant in
                if (missingCount[participant] ?? 0) >= missingThreshold {
                    removed.append(participant)
                    missingCount.removeValue(forKey: participant)
                    return true
                }
                return false
            }
            for name in removed {
                logWindow?.addEntry("👋 \(name) が退出（残り\(currentParticipants.count)人）")
                yuiManager?.feedMessage("[システム] \(name)が退出しました")
                changed = true
            }
        } else {
            // 全員見えてない時はカウントをリセット（誤判定防止）
            missingCount.removeAll()
        }

        if changed {
            let list = currentParticipants.joined(separator: "、")
            logWindow?.addEntry("👥 参加者(\(currentParticipants.count)人): \(list)")
            yuiManager?.updateParticipants(currentParticipants)
            onUsersUpdated?(detectedUsers)
        }
    }

    /// 入退室メッセージかどうかチェック。処理した場合trueを返す
    private func handleJoinLeaveMessage(_ text: String) -> Bool {
        // 参加
        if let regex = joinPattern {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let nameRange = Range(match.range(at: 1), in: text) {
                let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
                registerUser(name)
                if !currentParticipants.contains(where: { $0.contains(name) }) {
                    currentParticipants.append(name)
                    yuiManager?.updateParticipants(currentParticipants)
                }
                yuiManager?.feedMessage("[システム] \(name)が参加しました")
                return false  // 読み上げはする（入退室通知は残す）
            }
        }
        // 退出（退出メッセージだけが参加者を減らす唯一の手段）
        if let regex = leavePattern {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let nameRange = Range(match.range(at: 1), in: text) {
                let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
                currentParticipants.removeAll { $0.contains(name) || name.contains($0) }
                logWindow?.addEntry("👋 \(name) が退出（残り\(currentParticipants.count)人）")
                yuiManager?.updateParticipants(currentParticipants)
                yuiManager?.feedMessage("[システム] \(name)が退出しました")
                return false  // 読み上げはする
            }
        }
        return false
    }

    // MARK: - Public

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    func start() {
        NSLog("[GR] start() called. logWindow=\(logWindow != nil), statusBar=\(statusBar != nil)")
        spokenHistory.removeAll()
        previousSnapshot.removeAll()
        currentParticipants.removeAll()
        detectedUsers.removeAll()
        missingCount.removeAll()
        lastDetectedUser = nil
        isFirstPoll = true
        statusBar?.setStatus("動作中 🔊")
        logWindow?.setStatus(running: true)

        poll()

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func speakTest() {
        NSLog("[GR] speakTest() called. logWindow=\(logWindow != nil)")
        let text = "GravityReaderのテストです。正常に読み上げています。"
        logWindow?.addEntry(text)
        speechManager.speak(text)
    }

    func speakText(_ text: String) {
        speechManager.speak(text)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speechManager.stop()
        statusBar?.setStatus("停止中")
        logWindow?.setStatus(running: false)
    }

    // MARK: - Polling

    private func poll() {
        let allEntries = extractTextsWithRoles()

        if allEntries.isEmpty {
            logWindow?.addEntry("⚠️ テキスト取得できません — アクセシビリティ許可を確認してください")
            statusBar?.setStatus("⚠️ 許可が必要")
            return
        }

        let allTexts = allEntries.map { $0.text }

        // 話者検出（volumeボタン監視）
        let volumeSlots = parseVolumeSlots(allEntries)
        detectSpeakers(from: volumeSlots)

        // 参加者リストを解析（UIノイズ除外前の生テキストから）
        parseParticipantList(allTexts)

        if isFirstPoll {
            // ベースライン: メッセージ(AXGenericElement)だけをspokenHistoryに登録
            // AXStaticText（ユーザー名）は毎回出るので登録しない
            for i in 0..<allEntries.count {
                if allEntries[i].role == "AXGenericElement" {
                    spokenHistory.insert(allEntries[i].text)
                }
                if allEntries[i].role == "AXStaticText" {
                    // 次がAXGenericElementならユーザー名+メッセージのペア
                    if i + 1 < allEntries.count && allEntries[i + 1].role == "AXGenericElement" {
                        if let userName = extractUserName(allEntries[i].text) {
                            registerUser(userName)
                        } else if !isNotificationBanner(allEntries[i].text) && !isUINoiseOrSystemMessage(allEntries[i].text) {
                            // カンマなしでも名前として登録
                            registerUser(allEntries[i].text)
                        }
                    }
                }
            }
            isFirstPoll = false
            statusBar?.setStatus("✅ 準備完了 (\(allEntries.count)件)")
            logWindow?.addEntry("📌 ベースライン取得: \(allEntries.count)件 — ここから新着を読み上げます")
            return
        }

        // AXStaticText→AXGenericElement のペアで処理
        var i = 0
        while i < allEntries.count {
            let entry = allEntries[i]

            // AXStaticText の場合: 次がAXGenericElementならユーザー名+メッセージのペア
            if entry.role == "AXStaticText" {
                let nextIsMessage = (i + 1 < allEntries.count && allEntries[i + 1].role == "AXGenericElement")

                if nextIsMessage && !isNotificationBanner(entry.text) && !isUINoiseOrSystemMessage(entry.text) {
                    // これはユーザー名ラベル → 発言者を更新
                    if let userName = extractUserName(entry.text) {
                        lastDetectedUser = userName
                        registerUser(userName)
                    } else if let matched = matchKnownParticipant(entry.text) {
                        lastDetectedUser = matched
                    } else {
                        // 未知の名前でもメッセージ直前なら発言者として扱う
                        lastDetectedUser = entry.text
                        registerUser(entry.text)
                    }
                }
                // StaticText自体はスキップ（読み上げない）
                // ※ spokenHistoryに入れない（同じ名前が毎回出るため）
                i += 1
                continue
            }

            // AXButton（volumeボタン等）はメッセージではないのでスキップ
            if entry.role == "AXButton" {
                i += 1
                continue
            }

            // AXGenericElement = メッセージ本文
            let text = entry.text

            // コマンド検出はUIノイズ・重複チェックより先に行う（ただし重複実行は防止）
            if !spokenHistory.contains(text) {
                if handleVoiceCommand(text) { spokenHistory.insert(text); i += 1; continue }
                if handleReadingCommand(text) { spokenHistory.insert(text); i += 1; continue }
            }

            if isUINoiseOrSystemMessage(text) {
                spokenHistory.insert(text)
                i += 1
                continue
            }

            guard !spokenHistory.contains(text) else { i += 1; continue }
            spokenHistory.insert(text)

            // 入退室メッセージの処理
            handleJoinLeaveMessage(text)

            statusBar?.setLastRead(text)

            // 声紋登録中は全部止める（読み上げもYUiも）
            let enrolling = roomTranscription?.isEnrolling ?? false

            // ユーザー別ボイスで読み上げ + ログに発言者を表示
            if let user = lastDetectedUser {
                logWindow?.addEntry("[\(user)] \(text)")
                if !enrolling {
                    speechManager.speak(text, forUser: user)
                    yuiManager?.feedMessage("\(user): \(text)")
                }
                // 声紋学習トリガー: テキストチャットした人の声を覚える
                roomTranscription?.notifyChatMessage(speaker: user)
            } else {
                logWindow?.addEntry(text)
                if !enrolling {
                    speechManager.speak(text)
                    yuiManager?.feedMessage(text)
                }
            }

            i += 1
        }
    }

    // MARK: - Accessibility

    /// AXロールとテキストのペア
    struct AXTextEntry {
        let role: String  // "AXStaticText" = ユーザー名, "AXGenericElement" = メッセージ, "AXButton" = ボタン
        let text: String
    }

    // MARK: - 話者検出（volume ボタン監視）

    /// 現在マイクで喋っている人（AXツリーのvolumeボタンから検出）
    private(set) var currentSpeakers: [String] = []

    /// 誰かがマイクで喋っているか
    var isSomeoneSpeaking: Bool { !currentSpeakers.isEmpty }

    /// 前回のvolumeボタン状態（変化検出用）
    private var previousVolumeStates: [VolumeSlot] = []

    /// スピーカースロット情報
    struct VolumeSlot {
        let slotIndex: Int      // 0=owner, 1=slot2, 2=slot3, ...
        let buttonDesc: String  // "volume room owner", "volume no speak light", etc.
        let isSpeaking: Bool
    }

    /// AXエントリからvolumeボタン状態を解析
    private func parseVolumeSlots(_ entries: [AXTextEntry]) -> [VolumeSlot] {
        var slots: [VolumeSlot] = []
        var slotIndex = 0

        for entry in entries {
            guard entry.role == "AXButton", entry.text.hasPrefix("volume") else { continue }

            // 話者判定ルール:
            // "volume room owner" → オーナーのスロット。これだけでは喋ってるか不明。
            //    "volume room owner speak" 等に変わったら喋ってる判定（要検証）
            // "volume no speak light" → 確実に喋ってない
            // "volume speak light" 等 "no speak" を含まず "room owner" だけでもない → 喋ってる
            let desc = entry.text
            let isSpeaking: Bool
            if desc == "volume room owner" {
                // 静的な表示 — 喋ってるかは不明なので false
                // "volume room owner speak" 等の変化形がもしあれば true
                isSpeaking = false
            } else if desc.contains("room owner") && !desc.contains("no speak") {
                // "volume room owner speak" 等 — owner が喋ってる
                isSpeaking = true
            } else {
                // "no speak" を含む → 喋ってない / 含まない → 喋ってる
                isSpeaking = !desc.contains("no speak")
            }

            slots.append(VolumeSlot(
                slotIndex: slotIndex,
                buttonDesc: desc,
                isSpeaking: isSpeaking
            ))
            slotIndex += 1
        }
        return slots
    }

    /// volumeスロットから話者を特定
    private func detectSpeakers(from slots: [VolumeSlot]) {
        var speakers: [String] = []

        for slot in slots where slot.isSpeaking {
            if let name = speakerNameForSlot(slot.slotIndex) {
                speakers.append(name)
            } else {
                speakers.append("スロット\(slot.slotIndex + 1)")
            }
        }

        // 変化があった時だけログ（ボタン状態も出す）
        let prevSet = Set(currentSpeakers)
        let newSet = Set(speakers)
        if prevSet != newSet {
            if speakers.isEmpty && !currentSpeakers.isEmpty {
                logWindow?.addEntry("🔇 発話終了")
            } else if !speakers.isEmpty {
                logWindow?.addEntry("🔊 発話中: \(speakers.joined(separator: ", "))")
            }
            // デバッグ: 全スロットの状態をログ
            let stateStr = slots.map { "[\($0.slotIndex):\($0.buttonDesc)=\($0.isSpeaking ? "🔊" : "🔇")]" }.joined(separator: " ")
            logWindow?.addEntry("🎚 スロット状態: \(stateStr)")
        }
        currentSpeakers = speakers
    }

    /// スロット番号からユーザー名を推定
    /// slot 0 = ルーム主（もりけんなど、最初の参加者）
    /// slot 1〜 = マイクに上がっている順
    private func speakerNameForSlot(_ slotIndex: Int) -> String? {
        // ルーム主 = currentParticipants の最初のユーザー（or detectedUsersの最初）
        if slotIndex == 0 {
            // "volume room owner" はルーム主
            if let owner = currentParticipants.first {
                return owner
            }
            if let owner = detectedUsers.first {
                return owner
            }
            return "ルーム主"
        }

        // slot 1以降は参加者リストの順番に対応（仮定）
        // currentParticipants[0] = owner, [1] = slot2, [2] = slot3, ...
        if slotIndex < currentParticipants.count {
            return currentParticipants[slotIndex]
        }

        return nil
    }

    /// ロール付きでテキストを取得
    private func extractTextsWithRoles() -> [AXTextEntry] {
        guard let gravity = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == gravityBundleID
        }) else {
            NSLog("[GR] GRAVITY process not found!")
            return []
        }

        let axApp = AXUIElementCreateApplication(gravity.processIdentifier)
        var result: [AXTextEntry] = []
        var seenTexts: Set<String> = []
        collect(axApp, &result, seenTexts: &seenTexts)
        return result
    }

    /// 旧API互換（参加者パース用）
    private func extractTexts() -> [String] {
        return extractTextsWithRoles().map { $0.text }
    }

    private func collect(_ el: AXUIElement, _ result: inout [AXTextEntry], seenTexts: inout Set<String>, _ depth: Int = 0) {
        guard depth < 20 else { return }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        // AXMenuBarは丸ごとスキップ（メニューの中身はチャットじゃない）
        if roleStr == "AXMenuBar" { return }

        if roleStr == "AXGenericElement" || roleStr == "AXStaticText" || roleStr == "AXButton" {
            for attr in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute] {
                var val: AnyObject?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
                   let t = val as? String {
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }

                    if roleStr == "AXButton" {
                        // volumeボタンだけ拾う（話者検出用）
                        if trimmed.hasPrefix("volume") {
                            result.append(AXTextEntry(role: roleStr, text: trimmed))
                        }
                    } else if roleStr == "AXStaticText" {
                        // ユーザー名ラベルは同じ名前でも毎回取得する（ペアリングに必要）
                        result.append(AXTextEntry(role: roleStr, text: trimmed))
                    } else {
                        // メッセージ本文は重複除外（同じテキストの再読み上げ防止）
                        if !seenTexts.contains(trimmed) {
                            seenTexts.insert(trimmed)
                            result.append(AXTextEntry(role: roleStr, text: trimmed))
                        }
                    }
                    break
                }
            }
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids { collect(kid, &result, seenTexts: &seenTexts, depth + 1) }
    }

    /// デバッグ用: AXツリーの構造をダンプ（ウィンドウ内容のみ、メニュー除外）
    func dumpAXTree() {
        guard let gravity = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == gravityBundleID
        }) else { return }

        let axApp = AXUIElementCreateApplication(gravity.processIdentifier)
        var lines: [String] = []
        // AXWindowだけを対象（AXMenuBarをスキップ）
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(kid, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWindow" {
                dumpElement(kid, &lines, depth: 0, maxDepth: 20)
                break  // 最初のウィンドウだけ
            }
        }
        let dump = lines.joined(separator: "\n")
        logWindow?.addEntry("🔍 AXツリー ダンプ:\n\(dump)")
    }

    private func dumpElement(_ el: AXUIElement, _ lines: inout [String], depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)

        var role: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? "?"

        // テキストがある要素だけ詳細表示（ノイズ削減）
        var texts: [String] = []
        for attr in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute] {
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
               let t = val as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                let attrName = attr == kAXDescriptionAttribute ? "desc" : attr == kAXValueAttribute ? "val" : "title"
                texts.append("\(attrName)=\"\(t.prefix(60))\"")
            }
        }

        // テキストがある要素 or 浅い階層は常に表示
        if !texts.isEmpty {
            lines.append("\(indent)[\(roleStr)] \(texts.joined(separator: " | "))")
        } else if depth <= 3 {
            lines.append("\(indent)[\(roleStr)]")
        }
        // テキストなしの深い要素はスキップ（子は引き続き探索）

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids { dumpElement(kid, &lines, depth: depth + 1, maxDepth: maxDepth) }
    }
}
