import Foundation

/// YUiの好感度・ユーザー記憶・会話メモリ・永続化を担当
class YUiMemoryManager {
    var onLog: ((String) -> Void)?

    // MARK: - 好感度システム

    /// ユーザーごとの好感度（0〜100、初期値50）
    private(set) var likability: [String: Int] = [:]
    private let likabilityKey = "YUiLikability"

    // MARK: - ユーザー別記憶

    /// ユーザーごとの会話記憶（名前 → 要約テキスト）
    private(set) var userMemory: [String: String] = [:]
    private let userMemoryKey = "YUiUserMemory"

    /// ユーザーごとの未保存メッセージ蓄積（記憶更新トリガー用）
    var pendingUserMessages: [String: [String]] = [:]
    let userMemoryUpdateThreshold = 5  // 5件たまったら記憶更新

    // MARK: - 会話メモリ

    var conversationMemory: [(timestamp: Date, text: String)] = []
    var memorySummary: String = ""
    var myResponseHistory: [String] = []
    let maxResponseHistory = 20
    let memoryDuration: TimeInterval = 1800
    private var compressionTimer: Timer?

    // MARK: - 永続化パス

    static var memoryFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    // MARK: - ユーザー名の揺れ吸収

    /// ユーザー名の揺れを吸収して一貫したキーにする
    private func resolveUserKey(_ name: String) -> String {
        // 完全一致
        if likability[name] != nil { return name }
        // 部分一致
        for key in likability.keys {
            if key.contains(name) || name.contains(key) { return key }
        }
        return name
    }

    // MARK: - 好感度

    /// 好感度を取得
    func getLikability(for user: String) -> Int {
        return likability[resolveUserKey(user)] ?? 50
    }

    /// 好感度の全一覧
    func getAllLikability() -> [String: Int] {
        return likability
    }

    /// 好感度を調整（-10〜+10の範囲で変動）
    func adjustLikability(user: String, delta: Int) {
        let key = resolveUserKey(user)
        let current = likability[key] ?? 50
        let newVal = max(0, min(100, current + delta))
        likability[key] = newVal
        saveLikability()
        let emoji: String
        if delta > 0 { emoji = "💗" }
        else if delta < 0 { emoji = "💔" }
        else { emoji = "💛" }
        onLog?("\(emoji) \(key)の好感度: \(current) → \(newVal)")
    }

    /// 好感度を保存
    func saveLikability() {
        AppDefaults.suite.set(likability, forKey: likabilityKey)
    }

    /// 好感度を読み込み
    func loadLikability() {
        if let saved = AppDefaults.suite.dictionary(forKey: likabilityKey) as? [String: Int] {
            likability = saved
        }
    }

    // MARK: - ユーザー記憶

    /// ユーザー記憶を保存
    func saveUserMemory() {
        AppDefaults.suite.set(userMemory, forKey: userMemoryKey)
    }

    /// ユーザー記憶を読み込み
    func loadUserMemory() {
        if let saved = AppDefaults.suite.dictionary(forKey: userMemoryKey) as? [String: String] {
            userMemory = saved
        }
    }

    /// ユーザーの記憶を取得（名前揺れ対応）
    func getUserMemory(for user: String) -> String? {
        let key = resolveUserKey(user)
        return userMemory[key]
    }

    /// ユーザーとの会話を要約して記憶に保存
    func updateUserMemory(user: String, recentMessages: [String], apiClient: YUiAPIClient) {
        guard !recentMessages.isEmpty else { return }

        let key = resolveUserKey(user)
        let existing = userMemory[key] ?? ""

        let memorySystemPrompt = """
            あなたは人物メモを管理するアシスタントです。
            会話から以下の情報を抽出して、箇条書きで記録してください。

            【必ず記録する情報（最優先）】
            - 好きなもの（食べ物、音楽、アニメ、場所、人物など）
            - 嫌いなもの・苦手なもの
            - やりたいこと・行きたい場所・欲しいもの
            - 趣味・特技・仕事
            - 性格の特徴（明るい、シャイ、面白い等）
            - 具体的なエピソード（〇〇に行った、〇〇を食べた等）
            - 悩み・相談ごと

            【記録のルール】
            - 「〇〇が好き」「〇〇に行きたい」のように具体的に
            - 曖昧な情報は捨てる。具体的なものだけ残す
            - 箇条書き（・）で。1項目1行
            - 既存の記憶と重複する情報は省略
            - 古い情報でも具体的なら消さない
            """

        let prompt: String
        if existing.isEmpty {
            prompt = """
                以下は\(user)さんとの会話です。この人について記録を作ってください。

                \(recentMessages.joined(separator: "\n"))
                """
        } else {
            prompt = """
                以下は\(user)さんとの新しい会話です。既存の記録に新情報を追加してください。
                既存の情報は消さずに残し、新しい情報を追加してください。

                【既存の記録】
                \(existing)

                【新しい会話】
                \(recentMessages.joined(separator: "\n"))
                """
        }

        apiClient.callRaw(systemPrompt: memorySystemPrompt, userMessage: prompt) { [weak self] summary in
            DispatchQueue.main.async {
                guard let self = self, let summary = summary else { return }
                self.userMemory[key] = summary
                self.saveUserMemory()
                NSLog("[YUi] \(user)の記憶を更新: \(summary)")
            }
        }
    }

    /// ユーザーが来た時に再会イベント用の情報を返す（greetedUsersの管理は呼び出し側で行う）
    func onUserJoined(_ username: String, apiClient: YUiAPIClient) {
        // Note: このメソッドはYUiManagerから呼ばれ、greetedUsersチェックや
        // onResponse呼び出しはYUiManager側で管理する。
        // ここではユーザー記憶の取得と好感度の提供のみ行う。
    }

    /// 会話内容から好感度を判定してもらう
    func evaluateLikability(user: String, recentMessages: [String], apiClient: YUiAPIClient) {
        guard !recentMessages.isEmpty else { return }
        let message = recentMessages.last ?? ""
        // 短すぎるメッセージは評価しない
        guard message.count >= 3 else { return }

        let prompt = """
            あなたはYUi（ゆい）というAIキャラクターの感情を管理するシステムです。
            ユーザーの発言を見て、YUiの好感度がどう変化するか判定してください。

            ルール:
            - 返答は数値のみ（-3〜+3の整数）
            - +3: YUiに直接優しく話しかけてくれた、すごく面白い
            - +2: 好意的、褒めてくれた
            - +1: 普通に楽しい会話、YUiに軽く触れた
            - 0: 普通の会話、YUiに無関係
            - -1: ちょっと失礼、冷たい
            - -2: 悪口、からかい
            - -3: 暴言、YUiを侮辱
            - ほとんどの発言は0。+1か-1がたまに。+2以上は特別な時だけ
            - 数値だけ返して。説明は不要

            ユーザー: \(user)
            発言: \(message)
            現在の好感度: \(getLikability(for: user))/100
            """

        apiClient.callRaw(systemPrompt: prompt, userMessage: message) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self,
                      let text = response?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let delta = Int(text.filter { $0.isNumber || $0 == "-" }) else { return }
                if delta != 0 {
                    self.adjustLikability(user: user, delta: delta)
                }
            }
        }
    }

    // MARK: - メモリ管理

    func pruneMemory() {
        let cutoff = Date().addingTimeInterval(-memoryDuration)
        conversationMemory.removeAll { $0.timestamp < cutoff }
    }

    func startCompressionTimer(hasAPIKey: Bool, apiClient: YUiAPIClient?) {
        compressionTimer = Timer.scheduledTimer(withTimeInterval: memoryDuration, repeats: true) { [weak self, weak apiClient] _ in
            guard let apiClient = apiClient else { return }
            self?.compressMemory(apiClient: apiClient)
        }
    }

    /// 30分以上前の会話を要約に圧縮 + ユーザー別記憶を更新
    func compressMemory(apiClient: YUiAPIClient) {
        let cutoff = Date().addingTimeInterval(-memoryDuration)
        let oldMessages = conversationMemory.filter { $0.timestamp < cutoff }

        guard !oldMessages.isEmpty else { return }

        // ユーザー別に会話を振り分けて記憶を更新
        var userMessages: [String: [String]] = [:]
        for entry in oldMessages {
            if let colonRange = entry.text.range(of: ": ") ?? entry.text.range(of: "： ") {
                let user = String(entry.text[entry.text.startIndex..<colonRange.lowerBound])
                if user != "YUi" && !user.isEmpty {
                    userMessages[user, default: []].append(entry.text)
                }
            }
        }
        for (user, msgs) in userMessages where msgs.count >= 2 {
            updateUserMemory(user: user, recentMessages: msgs, apiClient: apiClient)
        }

        let texts = oldMessages.map { $0.text }.joined(separator: "\n")

        // 古いメッセージを削除
        conversationMemory.removeAll { $0.timestamp < cutoff }

        onLog?("🧠 メモリ圧縮中...")

        // OpenAIで要約生成
        let summaryPrompt = "以下の会話を3行以内で簡潔に要約してください。重要な話題、人名、結論を残してください。\n\n\(texts)"

        apiClient.callRaw(systemPrompt: "あなたは会話の要約をするアシスタントです。", userMessage: summaryPrompt) { [weak self] summary in
            DispatchQueue.main.async {
                if let summary = summary {
                    if let existing = self?.memorySummary, !existing.isEmpty {
                        self?.memorySummary = "\(existing)\n\(summary)"
                    } else {
                        self?.memorySummary = summary
                    }
                    self?.onLog?("🧠 メモリ圧縮完了")
                    self?.saveMemory()
                }
            }
        }
    }

    // MARK: - メモリ永続化

    /// 未保存のユーザー記憶をすべてフラッシュ（アプリ終了時用）
    func flushAllMemory(apiClient: YUiAPIClient?) {
        // 未保存のユーザー別メッセージを記憶に反映
        if let apiClient = apiClient {
            for (user, msgs) in pendingUserMessages where msgs.count >= 2 {
                updateUserMemory(user: user, recentMessages: msgs, apiClient: apiClient)
            }
        }
        pendingUserMessages.removeAll()
        saveMemory()
        saveUserMemory()
        saveLikability()
    }

    /// メモリをJSONファイルに保存
    func saveMemory() {
        let entries = conversationMemory.map { entry -> [String: Any] in
            ["timestamp": entry.timestamp.timeIntervalSince1970, "text": entry.text]
        }
        let data: [String: Any] = [
            "conversationMemory": entries,
            "memorySummary": memorySummary,
            "myResponseHistory": myResponseHistory,
            "savedAt": Date().timeIntervalSince1970
        ]
        do {
            let json = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            try json.write(to: Self.memoryFileURL)
        } catch {
            NSLog("[YUi] メモリ保存エラー: \(error)")
            onLog?("⚠️ メモリ保存に失敗: \(error.localizedDescription)")
        }
    }

    /// メモリをJSONファイルから読み込み
    func loadMemory() {
        let data: Data
        let json: [String: Any]
        do {
            data = try Data(contentsOf: Self.memoryFileURL)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            json = parsed
        } catch {
            // ファイルが存在しない場合は正常（初回起動時）
            return
        }

        // 保存時刻チェック（24時間以上前なら要約だけ復元）
        let savedAt = json["savedAt"] as? TimeInterval ?? 0
        let age = Date().timeIntervalSince1970 - savedAt
        let isOld = age > 86400  // 24時間

        // 要約は常に復元
        if let summary = json["memorySummary"] as? String, !summary.isEmpty {
            memorySummary = summary
        }

        // レスポンス履歴は常に復元
        if let history = json["myResponseHistory"] as? [String] {
            myResponseHistory = history
        }

        // 会話メモリは24時間以内なら復元
        if !isOld, let entries = json["conversationMemory"] as? [[String: Any]] {
            conversationMemory = entries.compactMap { entry in
                guard let ts = entry["timestamp"] as? TimeInterval,
                      let text = entry["text"] as? String else { return nil }
                return (timestamp: Date(timeIntervalSince1970: ts), text: text)
            }
            // 30分以上古いものは除外
            pruneMemory()
        }

        if !conversationMemory.isEmpty || !memorySummary.isEmpty {
            NSLog("[YUi] メモリ復元: 会話\(conversationMemory.count)件, 要約\(memorySummary.count)文字")
        }
    }

    // MARK: - ヘルパー

    /// 直近のメッセージから主な発言者を特定
    func detectPrimaryUser(from messages: [String]) -> String? {
        // 最新のメッセージから「ユーザー名: メッセージ」を探す
        for msg in messages.reversed() {
            if let colonRange = msg.range(of: ": ") ?? msg.range(of: "： ") {
                let user = String(msg[msg.startIndex..<colonRange.lowerBound])
                if user != "YUi" && !user.isEmpty { return user }
            }
        }
        return nil
    }
}
