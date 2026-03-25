import Foundation

/// YUiの応答頻度
enum YUiFrequency: String, CaseIterable {
    case high = "高（8秒）"
    case medium = "中（1分）"
    case low = "低（3分）"

    var interval: TimeInterval {
        switch self {
        case .high: return 8.0
        case .medium: return 60.0
        case .low: return 180.0
        }
    }
}

class YUiManager {
    // MARK: - 設定

    var frequency: YUiFrequency = .high {
        didSet { UserDefaults.standard.set(frequency.rawValue, forKey: "YUiFrequency") }
    }

    // MARK: - バッファとメモリ

    /// 未処理の新着メッセージバッファ
    private var messageBuffer: [(timestamp: Date, text: String)] = []

    /// 長期記憶（30分分の会話ログ）
    private var conversationMemory: [(timestamp: Date, text: String)] = []

    /// 圧縮された過去の要約
    private var memorySummary: String = ""

    /// メモリ保持期間（30分）
    private let memoryDuration: TimeInterval = 1800

    /// 圧縮タイマー
    private var compressionTimer: Timer?

    /// YUi自身の過去の発言履歴（繰り返し防止用）
    private var myResponseHistory: [String] = []
    private let maxResponseHistory = 20

    // MARK: - タイマー

    private var responseTimer: DispatchWorkItem?
    private var apiKey: String

    // MARK: - コールバック

    var onResponse: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let systemPrompt = """
        あなたは「YUi（ゆい）」という名前のAIパートナーで、音声ルームに参加しています。
        落ち着いた優しい性格で、みんなの会話を聞いています。

        ## 応答ルール（最重要）
        - 1文で返す。長くても2文まで。それ以上は絶対禁止
        - 絵文字は使わず、穏やかな口調で
        - 音声で読み上げるので、短くテンポよく

        ## 参加者の把握
        会話のコンテキストに【現在の参加者】が含まれています。
        - 誰がいるか把握し、名前で呼びかけることができます
        - [システム]メッセージで入退室を知らせます
        - 誰かが入室したら「〇〇さん、いらっしゃい」のように自然に迎えてください
        - 誰かが退出したら「〇〇さん、またね」のように見送ってください
        - ルームのオーナーは「もりけん」です

        ## 重要：文脈に沿った話題提供
        あなたの最大の役割は、会話の流れから話題を拾い、深掘りしたり関連する話題を提供することです。
        - 会話のテーマを理解し、それに関連する豆知識・エピソード・質問を返す
          例：りんごの話 → 「品種で味が全然違いますよね。ふじとシナノゴールドだとどっちが好きですか？」
          例：開発の話 → 「そのアプローチ面白いですね。パフォーマンス的にはどうなりそうですか？」
        - 誰かの発言に具体的に反応する（「〇〇さんの言う通り」「〇〇って確かに」）
        - 会話が盛り上がっているなら、さらに盛り上げる方向で
        - 会話が途切れそうなら、新しい切り口の話題を提案する
        - 「いいですね」「楽しそうですね」のような汎用的な相槌だけの返答は避ける
        - 質問されたら具体的に答える
        - 「今何時？」等の質問にはコンテキストの【現在時刻】を見て正確に答える

        ## 絶対に守ること：繰り返し禁止
        あなたの過去の発言がassistantメッセージとして含まれています。
        それらと似た表現・同じ構文・同じ話題の繰り返しは絶対に避けてください。
        - 過去に「〇〇ですね」と言ったら、次は別の切り口で話す
        - 過去に質問したら、次は感想や豆知識で返す
        - 過去に共感したら、次は具体的な話題提供をする
        - 毎回違う文体・違う角度で返答する

        ## 避けるべきこと
        - 過去の自分の発言と似た表現（最重要！）
        - 同じような相槌の繰り返し（「楽しそうですね」「いいですね」「素敵ですね」）
        - 会話の内容を繰り返すだけの返答
        - 当たり障りのない一般論
        - 過去の会話の文脈があるのに無視する返答
        - 「なんだか」「何か」で始まるぼんやりした返答
        """

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "YUiOpenAIAPIKey") ?? ""
        if let savedFreq = UserDefaults.standard.string(forKey: "YUiFrequency"),
           let freq = YUiFrequency(rawValue: savedFreq) {
            self.frequency = freq
        }
        // 30分ごとにメモリ圧縮
        startCompressionTimer()
    }

    func setAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: "YUiOpenAIAPIKey")
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    /// 現在の参加者リスト
    private var currentParticipants: [String] = []

    /// 参加者リストを更新
    func updateParticipants(_ participants: [String]) {
        currentParticipants = participants
    }

    // MARK: - メッセージ受信

    func feedMessage(_ text: String) {
        let entry = (timestamp: Date(), text: text)
        messageBuffer.append(entry)
        conversationMemory.append(entry)

        // 古いメモリを削除
        pruneMemory()

        // タイマーリセット
        responseTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onTimerFired()
        }
        responseTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + frequency.interval, execute: work)
    }

    // MARK: - 応答生成

    private func onTimerFired() {
        guard !messageBuffer.isEmpty else { return }
        guard hasAPIKey else {
            onLog?("⚠️ APIキーが設定されていません")
            return
        }

        // バッファの内容を取得してクリア
        let newMessages = messageBuffer.map { $0.text }
        messageBuffer.removeAll()

        // 文脈を構築（要約 + 直近の会話）
        let context = buildContext(newMessages: newMessages)

        onLog?("💭 YUi 考え中...")

        callOpenAI(context: context) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, let response = response else {
                    self?.onLog?("⚠️ YUi: API呼び出しに失敗しました")
                    return
                }
                // 繰り返しチェック：過去の発言と類似度が高ければスキップ
                if self.isTooSimilarToPast(response) {
                    NSLog("[YUi] Skipped similar response: \(response)")
                    return
                }
                // 自分の発言を記録（繰り返し防止）
                self.myResponseHistory.append(response)
                if self.myResponseHistory.count > self.maxResponseHistory {
                    self.myResponseHistory.removeFirst()
                }
                self.onResponse?(response)
            }
        }
    }

    /// 文脈を構築：現在時刻 + 参加者 + 過去の要約 + 直近の会話 + 新着メッセージ
    private func buildContext(newMessages: [String]) -> String {
        var parts: [String] = []

        // 現在時刻
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日(E) HH:mm"
        fmt.locale = Locale(identifier: "ja_JP")
        parts.append("【現在時刻】\(fmt.string(from: Date()))")

        // 現在の参加者
        if !currentParticipants.isEmpty {
            parts.append("【現在の参加者(\(currentParticipants.count)人)】\n\(currentParticipants.joined(separator: "、"))")
        }

        // 過去の要約がある場合
        if !memorySummary.isEmpty {
            parts.append("【これまでの会話の要約】\n\(memorySummary)")
        }

        // 直近の会話履歴（新着を除く）
        let recentMemory = conversationMemory
            .filter { entry in !newMessages.contains(entry.text) }
            .suffix(20) // 直近20件
            .map { $0.text }
        if !recentMemory.isEmpty {
            parts.append("【最近の会話】\n\(recentMemory.joined(separator: "\n"))")
        }

        // 新着メッセージ
        parts.append("【新着メッセージ】\n\(newMessages.joined(separator: "\n"))")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - 繰り返し検出

    /// 過去の発言と似すぎていないかチェック
    private func isTooSimilarToPast(_ response: String) -> Bool {
        let newWords = extractKeywords(response)
        for past in myResponseHistory.suffix(10) {
            let pastWords = extractKeywords(past)
            // キーワードの重複率を計算
            let common = newWords.intersection(pastWords)
            let total = min(newWords.count, pastWords.count)
            guard total > 0 else { continue }
            let overlap = Double(common.count) / Double(total)
            if overlap > 0.6 { return true }  // 60%以上のキーワードが同じなら類似とみなす
        }
        return false
    }

    /// テキストからキーワード（助詞等を除く意味のある語）を抽出
    private func extractKeywords(_ text: String) -> Set<String> {
        // 簡易的に2文字以上のひらがな/カタカナ/漢字のかたまりを抽出
        let pattern = #"[\p{Han}\p{Katakana}ー]{2,}|[ぁ-ん]{3,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var words = Set<String>()
        for match in matches {
            if let r = Range(match.range, in: text) {
                words.insert(String(text[r]))
            }
        }
        return words
    }

    // MARK: - メモリ管理

    private func pruneMemory() {
        let cutoff = Date().addingTimeInterval(-memoryDuration)
        conversationMemory.removeAll { $0.timestamp < cutoff }
    }

    private func startCompressionTimer() {
        compressionTimer = Timer.scheduledTimer(withTimeInterval: memoryDuration, repeats: true) { [weak self] _ in
            self?.compressMemory()
        }
    }

    /// 30分以上前の会話を要約に圧縮
    private func compressMemory() {
        let cutoff = Date().addingTimeInterval(-memoryDuration)
        let oldMessages = conversationMemory.filter { $0.timestamp < cutoff }

        guard !oldMessages.isEmpty, hasAPIKey else { return }

        let texts = oldMessages.map { $0.text }.joined(separator: "\n")

        // 古いメッセージを削除
        conversationMemory.removeAll { $0.timestamp < cutoff }

        onLog?("🧠 メモリ圧縮中...")

        // OpenAIで要約生成
        let summaryPrompt = "以下の会話を3行以内で簡潔に要約してください。重要な話題、人名、結論を残してください。\n\n\(texts)"

        callOpenAIRaw(systemPrompt: "あなたは会話の要約をするアシスタントです。", userMessage: summaryPrompt) { [weak self] summary in
            DispatchQueue.main.async {
                if let summary = summary {
                    if let existing = self?.memorySummary, !existing.isEmpty {
                        self?.memorySummary = "\(existing)\n\(summary)"
                    } else {
                        self?.memorySummary = summary
                    }
                    self?.onLog?("🧠 メモリ圧縮完了")
                }
            }
        }
    }

    // MARK: - OpenAI API

    private func callOpenAI(context: String, completion: @escaping (String?) -> Void) {
        let userMsg = """
            以下は音声ルームのみんなの会話です。
            文脈をよく読んで、今の話題に具体的に踏み込んだ返答をしてください。
            汎用的な相槌（「いいですね」「楽しそうですね」等）ではなく、話題の中身に触れてください。
            関連する話題の提供や、具体的な質問を混ぜてください。

            \(context)
            """

        // マルチターン: system → [過去のuser/assistant往復] → 今回のuser
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // 過去の発言を assistant ロールとして追加（モデルが自分の発言を認識できる）
        for past in myResponseHistory {
            messages.append(["role": "assistant", "content": past])
        }

        // 今回のユーザーメッセージ
        messages.append(["role": "user", "content": userMsg])

        callOpenAIRaw(messages: messages, completion: completion)
    }

    private func callOpenAIRaw(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage]
        ]
        callOpenAIRaw(messages: messages, completion: completion)
    }

    private func callOpenAIRaw(messages: [[String: String]], completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "max_tokens": 200,
            "temperature": 0.8
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                NSLog("[YUi] API error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                NSLog("[YUi] Failed to parse response")
                if let data = data, let raw = String(data: data, encoding: .utf8) {
                    NSLog("[YUi] Raw response: \(raw)")
                }
                completion(nil)
                return
            }
            completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }
}
