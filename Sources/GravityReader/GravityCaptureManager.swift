import AppKit

class GravityCaptureManager {
    private var statusBar: StatusBarController?
    var logWindow: LogWindowController?
    private var timer: Timer?
    let speechManager = SpeechManager()
    var yuiManager: YUiManager?
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
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// ユーザー名っぽいパターン（「名前, タグ」形式）
    private let userNamePattern: NSRegularExpression? = {
        // "ぴうセポネ。🐣ྀི" や "まきねこ🐈, XOXO" や "もりけん社長🥕🥩[オーナー]" 等
        try? NSRegularExpression(pattern: #"^(.+),\s*.+$"#)
    }()

    /// ボイスコマンドパターン: "!voice ユーザー名 声の名前" や "!声 ナポリタン ずんだもん"
    private let voiceCommandPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^[!！](voice|声)\s+(.+?)\s+(.+)$"#)
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

    /// ユーザー名パターンかどうか（"名前, タグ" 形式）
    private func extractUserName(_ text: String) -> String? {
        guard let regex = userNamePattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range),
           let nameRange = Range(match.range(at: 1), in: text) {
            return String(text[nameRange]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// テキストが既知の参加者名かどうか判定（カンマなしの名前も検出）
    private func isKnownParticipantName(_ text: String) -> Bool {
        // 参加者リストの名前と一致するか
        for participant in currentParticipants {
            if text == participant { return true }
            // 参加者名がテキストに含まれる or テキストが参加者名に含まれる
            if participant.contains(text) || text.contains(participant) { return true }
        }
        // 検出済みユーザー名と一致するか
        for user in detectedUsers {
            if text == user { return true }
            if user.contains(text) || text.contains(user) { return true }
        }
        return false
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
        // 部分一致（含む）
        let matches = detectedUsers.filter { $0.contains(partial) }
        if matches.count == 1 { return matches[0] }
        // ユーザーのボイスマップのキーも検索
        let mapMatches = speechManager.allUserVoiceAssignments().keys.filter { $0.contains(partial) }
        if mapMatches.count == 1 { return mapMatches.first }
        // 複数ヒットなら最短名を返す
        if let shortest = (matches + mapMatches).min(by: { $0.count < $1.count }) { return shortest }
        // ヒットなし → そのまま返す（新規ユーザーとして）
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

    // MARK: - 参加者トラッキング

    /// AXツリーの生テキストから「参加メンバー」セクションを解析
    private func parseParticipantList(_ allTexts: [String]) {
        guard let startIdx = allTexts.firstIndex(of: "参加メンバー") else { return }

        var members: [String] = []
        let sectionStopWords: Set<String> = [
            "GRAVITY", "メッセージを送信", "公開音声ルーム",
            "ランキング>>", "アナウンス >>",
        ]

        for i in (startIdx + 1)..<allTexts.count {
            let text = allTexts[i]
            // 次のUIセクションに到達したら終了
            if sectionStopWords.contains(text) { break }
            if text == "ゲスト" { continue } // セクション区切り
            if isUINoiseOrSystemMessage(text) { break }

            // メンバー名をクリーンアップ（[オーナー]等のタグを保持したまま）
            let name = text.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                members.append(name)
            }
        }

        guard !members.isEmpty else { return }

        // 差分を検出
        let oldSet = Set(currentParticipants)
        let newSet = Set(members)
        let joined = newSet.subtracting(oldSet)
        let left = oldSet.subtracting(newSet)

        if currentParticipants.isEmpty {
            // 初回：参加者一覧を表示
            currentParticipants = members
            let list = members.joined(separator: "、")
            logWindow?.addEntry("👥 現在の参加者(\(members.count)人): \(list)")
            yuiManager?.updateParticipants(members)
        } else if joined.count > 0 || left.count > 0 {
            currentParticipants = members

            for name in left {
                logWindow?.addEntry("👋 \(name) が退出しました")
                yuiManager?.feedMessage("[システム] \(name)が退出しました")
            }
            for name in joined {
                // 入室はjoin/leaveメッセージで処理するのでここでは重複しないようにする
                // ただしメッセージ検出漏れ対策として
                // 参加メンバーリストの差分で検出された入室
                // （メッセージ検出との重複はYUiのfeedMessageで管理）
            }
            yuiManager?.updateParticipants(members)
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
        // 退出
        if let regex = leavePattern {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let nameRange = Range(match.range(at: 1), in: text) {
                let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
                currentParticipants.removeAll { $0.contains(name) }
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
        let allTexts = extractTexts()

        if allTexts.isEmpty {
            logWindow?.addEntry("⚠️ テキスト取得できません — アクセシビリティ許可を確認してください")
            statusBar?.setStatus("⚠️ 許可が必要")
            return
        }

        // 参加者リストを解析（UIノイズ除外前の生テキストから）
        parseParticipantList(allTexts)

        // UIノイズを除外
        let texts = allTexts.filter { !isUINoiseOrSystemMessage($0) }

        if isFirstPoll {
            for text in texts { spokenHistory.insert(text) }
            previousSnapshot = texts
            isFirstPoll = false
            statusBar?.setStatus("✅ 準備完了 (\(texts.count)件)")
            logWindow?.addEntry("📌 ベースライン取得: \(texts.count)件 — ここから新着を読み上げます")
            return
        }

        for text in texts {
            // ユーザー名パターンは常にチェック（spokenHistory関係なく発言者を追跡）
            if let userName = extractUserName(text) {
                lastDetectedUser = userName
                registerUser(userName)
                spokenHistory.insert(text)
                continue
            }

            // 既知の参加者名なら読み上げスキップ（カンマなし名前も対応）
            if isKnownParticipantName(text) {
                spokenHistory.insert(text)
                continue
            }

            guard !spokenHistory.contains(text) else { continue }
            spokenHistory.insert(text)

            // 入退室メッセージの処理（YUiに通知、読み上げは継続）
            handleJoinLeaveMessage(text)

            // ボイスコマンドの処理
            if handleVoiceCommand(text) {
                continue
            }

            statusBar?.setLastRead(text)
            logWindow?.addEntry(text)

            // ユーザー別ボイスで読み上げ
            if let user = lastDetectedUser {
                speechManager.speak(text, forUser: user)
            } else {
                speechManager.speak(text)
            }
            yuiManager?.feedMessage(text)
        }

        previousSnapshot = texts
    }

    // MARK: - Accessibility

    private func extractTexts() -> [String] {
        guard let gravity = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == gravityBundleID
        }) else {
            NSLog("[GR] GRAVITY process not found!")
            return []
        }

        let axApp = AXUIElementCreateApplication(gravity.processIdentifier)
        var result: [String] = []
        collect(axApp, &result)
        return result
    }

    private func collect(_ el: AXUIElement, _ result: inout [String], _ depth: Int = 0) {
        guard depth < 20 else { return }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        if roleStr == "AXGenericElement" || roleStr == "AXStaticText" {
            for attr in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute] {
                var val: AnyObject?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
                   let t = val as? String {
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !result.contains(trimmed) {
                        result.append(trimmed)
                        break
                    }
                }
            }
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids { collect(kid, &result, depth + 1) }
    }
}
