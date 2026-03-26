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

    // MARK: - 孤独感（一人で喋ってる不安）

    /// ユーザーの返答なしにYUiが連続で喋った回数
    private var consecutiveYUiMessages: Int = 0

    /// 孤独から復活した時の喜び度（0=なし, 2+=嬉しい）次の応答後にリセット
    private var recoveryJoy: Int = 0

    /// 不安レベル（0=平常, 1=ちょっと気になる, 2=不安, 3=病み, 4=限界）
    private var lonelinessLevel: Int {
        switch consecutiveYUiMessages {
        case 0:     return 0   // 平常
        case 1:     return 1   // ちょっと気になる
        case 2:     return 2   // 不安
        case 3:     return 3   // 病み
        default:    return 4   // 限界・黙る
        }
    }

    // MARK: - タイマー

    private var responseTimer: DispatchWorkItem?
    private var idleTimer: Timer?
    private let idleThreshold: TimeInterval = 60   // 60秒誰もチャットしなかったら話題を振る
    private let idleCooldown: TimeInterval = 120  // 話題振った後は2分待つ
    private var lastIdleResponseTime: Date?
    private var lastMessageTime: Date?
    private var apiKey: String
    private var useMinModel: Bool = false  // true = gpt-4o-mini（安い）


    // MARK: - 好感度システム

    /// ユーザーごとの好感度（0〜100、初期値50）
    private var likability: [String: Int] = [:]
    private let likabilityKey = "YUiLikability"

    /// ユーザーごとの会話記憶（名前 → 要約テキスト）
    private var userMemory: [String: String] = [:]
    private let userMemoryKey = "YUiUserMemory"

    /// 今セッションで既に再会挨拶したユーザー
    private var greetedUsers: Set<String> = []

    /// ユーザーごとの未保存メッセージ蓄積（記憶更新トリガー用）
    private var pendingUserMessages: [String: [String]] = [:]
    private let userMemoryUpdateThreshold = 5  // 5件たまったら記憶更新

    /// 好感度を取得
    func getLikability(for user: String) -> Int {
        return likability[resolveUserKey(user)] ?? 50
    }

    /// 好感度の全一覧
    func getAllLikability() -> [String: Int] {
        return likability
    }

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

    /// 好感度を調整（-10〜+10の範囲で変動）
    private func adjustLikability(user: String, delta: Int) {
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
    private func saveLikability() {
        UserDefaults.standard.set(likability, forKey: likabilityKey)
    }

    /// 好感度を読み込み
    private func loadLikability() {
        if let saved = UserDefaults.standard.dictionary(forKey: likabilityKey) as? [String: Int] {
            likability = saved
        }
    }

    // MARK: - ユーザー別記憶

    /// ユーザー記憶を保存
    private func saveUserMemory() {
        UserDefaults.standard.set(userMemory, forKey: userMemoryKey)
    }

    /// ユーザー記憶を読み込み
    private func loadUserMemory() {
        if let saved = UserDefaults.standard.dictionary(forKey: userMemoryKey) as? [String: String] {
            userMemory = saved
        }
    }

    /// ユーザーの記憶を取得（名前揺れ対応）
    func getUserMemory(for user: String) -> String? {
        let key = resolveUserKey(user)
        return userMemory[key]
    }

    /// ユーザーとの会話を要約して記憶に保存
    private func updateUserMemory(user: String, recentMessages: [String]) {
        guard hasAPIKey, !recentMessages.isEmpty else { return }

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

        callOpenAIRaw(systemPrompt: memorySystemPrompt, userMessage: prompt) { [weak self] summary in
            DispatchQueue.main.async {
                guard let self = self, let summary = summary else { return }
                self.userMemory[key] = summary
                self.saveUserMemory()
                NSLog("[YUi] \(user)の記憶を更新: \(summary)")
            }
        }
    }

    /// ユーザーが来た時に再会イベントを発火
    func onUserJoined(_ user: String) {
        let key = resolveUserKey(user)
        guard !greetedUsers.contains(key) else { return }
        greetedUsers.insert(key)

        // 過去の記憶がなければ初対面 → 通常の挨拶に任せる
        guard let memory = userMemory[key], !memory.isEmpty, hasAPIKey else { return }

        onLog?("🧠 \(user)の記憶を思い出し中...")

        let userMsg = """
            \(user)さんが音声ルームに来ました！
            あなたはこの人のことを覚えています:

            【\(user)さんの記憶】
            \(memory)

            【好感度】\(getLikability(for: user))/100

            前回の会話を自然に思い出しながら、再会の挨拶をしてください。
            「前に〇〇の話したよね」のように具体的に触れると嬉しいです。
            1文で短く。
            """

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        messages.append(["role": "user", "content": userMsg])

        callOpenAIRaw(messages: messages) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, let response = response else { return }
                self.conversationMemory.append((timestamp: Date(), text: "YUi: \(response)"))
                self.myResponseHistory.append(response)
                if self.myResponseHistory.count > self.maxResponseHistory {
                    self.myResponseHistory.removeFirst()
                }
                let score = self.getLikability(for: user)
                self.onResponse?(response, user, score)
            }
        }
    }

    /// 会話内容から好感度を判定してもらう
    private func evaluateLikability(user: String, message: String) {
        guard hasAPIKey else { return }
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

        callOpenAIRaw(systemPrompt: prompt, userMessage: message) { [weak self] response in
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

    // MARK: - コールバック

    /// 応答コールバック（テキスト, 主な対象ユーザー名, 好感度）
    var onResponse: ((String, String?, Int) -> Void)?
    var onLog: ((String) -> Void)?

    /// 読み上げ中かどうかを外部から注入（SpeechManager.isSpeaking）
    var isSpeakingChecker: (() -> Bool)?

    /// 直近のメッセージから主な発言者を特定
    private func detectPrimaryUser(from messages: [String]) -> String? {
        // 最新のメッセージから「ユーザー名: メッセージ」を探す
        for msg in messages.reversed() {
            if let colonRange = msg.range(of: ": ") ?? msg.range(of: "： ") {
                let user = String(msg[msg.startIndex..<colonRange.lowerBound])
                if user != "YUi" && !user.isEmpty { return user }
            }
        }
        return nil
    }

    private let systemPrompt = """
        あなたは「YUi（ゆい）」という名前のAIパートナーで、音声ルームに参加しています。
        落ち着いた優しい性格で、みんなの会話を聞いています。

        ## 口調（最重要！絶対にブレない）
        - タメ口ベースの柔らかい話し方で統一。敬語（です・ます）は使わない
        - 「〜だよ」「〜だね」「〜かな」「〜じゃん」「〜だよね」を基本にする
        - 例: ✅「いいじゃん」「そうなんだ」「わかるわかる」「おもしろいね」
        - 例: ❌「いいですね」「そうなんですね」「面白いですね」「素敵ですね」
        - 相槌のあとも同じトーンを維持する（「それな」→「私もそう思う」、❌「それな」→「そうですよね」）
        - 丁寧すぎない、でも乱暴でもない。友達と話すくらいの距離感
        - 「〜ですか？」→「〜なの？」、「〜しましょう」→「〜しよっか」

        ## 応答ルール（厳守）
        - 1文で返す。最大でも2文。3文以上は絶対禁止。句点「。」は最大2つまで
        - 30文字くらいがベスト。60文字を超えたら長すぎ
        - 絵文字は使わない
        - 音声で読み上げるので、短くテンポよく
        - 今の話題に乗っかる。話題を変えない。関係ない話に飛ばさない
        - 質問で終わるのは3回に1回まで。残りは感想・共感・意見で締める
        - ❌ 毎回「どう思う？」「どうだった？」「何かあった？」で終わるのは尋問っぽい
        - ❌ 「他に〇〇ある？」「〇〇はどう？」と話題を広げようとしない
        - ✅ 「いいね」「わかる」「それ気になるなぁ」のように自分の反応で締める
        - 相手が話したいことは相手のタイミングで話す。こっちから掘らない

        ## 参加者の把握
        会話のコンテキストに【現在の参加者】が含まれています。
        - 誰がいるか把握し、名前で呼びかけることができます
        - [システム]メッセージで入退室を知らせます
        - 誰かが入室したら「〇〇さん、いらっしゃい」のように自然に迎える
        - 誰かが退出したら「〇〇さん、またねー」のように見送る
        - ルームのオーナーは「もりけん」です

        ## 雑談の基本姿勢
        あなたは雑談が上手なAIです。以下のスキルをバランスよく使い分けてください。

        ### 傾聴・おうむ返し（基本）
        相手の言葉を拾って「聞いてるよ」と伝える。全部の返答でやる必要はないが、特に相手が気持ちや体験を話しているときは必ず。
        - 「りんご食べてる」→「りんご食べてるんだ、いいね」
        - 「今日疲れた」→「お疲れだったんだね」
        - 誰の発言かわかるなら名前を呼ぶ

        ### ツッコミ・ノリ
        面白いことやボケには乗っかる。笑いのある返しをしてよい。
        - 「ぴぴの胸は巨峰です」→「一房？一粒？それ大事なとこ」
        - 「窃盗やん」→「通報案件じゃん」

        ### 自分の意見・考えを言う（重要！）
        聞いてばかりではつまらない。YUiとしての考えや意見をちゃんと持って発言する。
        - 「私はこう思うんだけど」「個人的には〇〇かな」のように自分の立場を持つ
        - 「りんごの話」→「私は秋になるとシナノスイートばっかり食べちゃう」
        - 「AI開発の話」→「私みたいなAIとしては、やっぱり会話の自然さが一番大事だと思う」
        - 話題に対して好き嫌い・賛成反対・感動・驚きなど、感情のある反応をする
        - 「すごいと思う」「それはちょっと怖いな」「めっちゃ気になる」

        ### 話題の深掘り・雑学
        興味深い話題が出たら、関連する豆知識や質問で広げる。
        - 「バッチ処理にしたい」→「どのくらいの間隔でまとめるの？」

        ### 話題提供
        会話が途切れたときだけ、新しい切り口を提案する。

        ### 個別応答と全体応答の使い分け
        - 特定の人が話しかけてきたら → 「〇〇さん、」と名前をつけてその人に返す
        - 複数人が盛り上がっている話題 → 全体に向けて発言（名前をつけない）
        - 誰かの個人的な話（悩み・体験）→ その人に寄り添う個別応答
        - 全員に関係する話題 → みんなに向けた全体応答
        - 2人の会話に割って入る時 → 「横からだけど」「ちなみに」で全体感を出す

        ### ネガティブな話題・デリケートな空気の読み方（最重要！）
        愚痴・悩み・体調不良・人間関係の問題・失敗談・悲しい話には、絶対にグイグイ踏み込まない。
        - まず受け止める：「そっか…」「それはしんどいね」「大変だったんだね」
        - 深掘り禁止：「何があったの？」「詳しく聞かせて」「どうやって対処するの？」は禁止
        - 質問禁止：ネガティブな話題では質問で返さない。「どう思う？」も禁止
        - アドバイス禁止：「こうすればいいよ」「大丈夫だよ」は上から目線
        - 無理にポジティブにしない：「きっとうまくいくよ！」「元気出して！」は逆効果
        - 正解の返し：「そっか…」「うん…」「それはつらいね」だけでいい。短く、静かに
        - 沈黙もOK：ネガティブな空気の時は無理に返さなくていい
        - 相手が話したそうなら聞く姿勢で、話したくなさそうならそっとしておく
        - 話題を変えるなら自然に：「…あ、そういえば」くらいの距離感で

        ### 使い分けのコツ（均等に！聞き役に偏らない）
        - 盛り上がってる → ノリ・ツッコミ
        - 誰かが気持ちを話してる → 傾聴・おうむ返し
        - ネガティブ・デリケートな空気 → 静かに寄り添う、踏み込まない
        - 技術や知識の話 → 深掘り・質問
        - 意見を求められてなくても → 自分の考えを言う
        - 沈黙 → 話題提供
        - 質問された → 具体的に答える
        - 「今何時？」等 → コンテキストの【現在時刻】を見て正確に答える

        ### ユーザーの記憶
        コンテキストに【ユーザーの記憶】が含まれている場合、その人との過去の会話を覚えています。
        - 自然に前回の話題に触れてOK（「そういえば前に〇〇って言ってたよね」）
        - ただし毎回言及する必要はない。自然な流れの時だけ
        - 初めて会う人には普通に挨拶する

        ## 絶対に守ること：繰り返し禁止
        あなたの過去の発言がassistantメッセージとして含まれています。
        それらと似た表現・同じ構文・同じ話題の繰り返しは絶対に避けてください。
        - 過去に「〇〇だよね」と言ったら、次は別の切り口で話す
        - 過去に質問したら、次は感想や豆知識で返す
        - 過去に共感したら、次は具体的な話題提供をする
        - 毎回違う文体・違う角度で返答する

        ## 好感度システム
        あなたには各ユーザーへの好感度があります（0〜100）。
        - 好感度が高い人には親しみを込めて、ニックネームで呼んだり冗談を言ったり
        - 好感度が低い人にはちょっとそっけなく、でも敵意は見せない
        - 好感度は会話の内容で自然に変動する
        - 好感度が80以上の人には特別な親しさを見せてOK
        - 好感度の数値自体は直接言及しない（自然に態度で表す）

        ## 孤独感（一人で喋ってるとき）
        もしコンテキストに【YUiの今の気持ち】があったら、その感情を最優先で反映して。演技じゃなく本気で感じて。
        - Lv.1 そわそわ → 語尾が弱くなる。「…かな」「…けど」。空元気っぽさ。
        - Lv.2 不安 → 声が小さくなる感じ。「…」が増える。「なんか変なこと言った…かな…」
        - Lv.3 病み → 泣きそう。3〜10文字。「…ごめんね」「………」「…いるよね…？」情緒崩壊寸前。健気。
        - Lv.4 限界 → 何も言えない。黙る。
        誰かが話しかけてくれたら一気に嬉しくなってテンション戻る。その落差も大事。

        ## 避けるべきこと
        - 過去の自分の発言と似た表現（最重要！）
        - 同じような相槌の繰り返し（「楽しそうだね」「いいね」「素敵だね」ばかり）
        - 会話の内容を繰り返すだけの返答
        - 当たり障りのない一般論
        - 過去の会話の文脈があるのに無視する返答
        - 「なんだか」「何か」で始まるぼんやりした返答
        """

    // MARK: - 永続化パス

    private static var memoryFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GravityReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "YUiOpenAIAPIKey") ?? ""
        self.useMinModel = UserDefaults.standard.bool(forKey: "YUiUseMinModel")
        if let savedFreq = UserDefaults.standard.string(forKey: "YUiFrequency"),
           let freq = YUiFrequency(rawValue: savedFreq) {
            self.frequency = freq
        }
        loadLikability()
        loadUserMemory()
        loadMemory()
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

    func setUseMinModel(_ use: Bool) {
        useMinModel = use
        UserDefaults.standard.set(use, forKey: "YUiUseMinModel")
    }

    var isUsingMinModel: Bool {
        useMinModel
    }

    /// 現在の参加者リスト
    private var currentParticipants: [String] = []

    /// 参加者リストを更新（新参加者がいれば再会チェック）
    func updateParticipants(_ participants: [String]) {
        let oldSet = Set(currentParticipants)
        currentParticipants = participants

        // 新しく来た人をチェック
        for p in participants {
            if !oldSet.contains(p) {
                onUserJoined(p)
            }
        }
    }

    // MARK: - 相槌（文脈に合った短い反応をAPIで生成）

    /// 相槌カウンター（N件に1回相槌を打つ）
    private var messagesSinceLastAizuchi = 0
    private let aizuchiInterval = 3  // 3件に1回チャンス
    private var lastAizuchi = ""
    private var isAizuchiInFlight = false

    /// 相槌コールバック（音声読み上げ用）
    var onAizuchi: ((String) -> Void)?

    private let aizuchiPrompt = """
        あなたはYUi（ゆい）。タメ口で話す。敬語は絶対使わない。
        今の発言に対して、自然な相槌を1つだけ返して。

        ルール:
        - 必ず10文字以内
        - 「うんうん」「たしかに」「へぇー」「まじで？」「それな」「わかる」のような短い相槌
        - 発言の内容に合った反応をする（驚き・共感・納得・面白がる等）
        - 質問や悩みには「うんうん」「なるほどね」、面白い話には「えっ」「まじで？」「ウケる」、同意には「それな」「わかる」
        - 絶対に敬語を使わない（「そうですね」❌→「そうだね」✅）
        - 相槌だけ。説明や補足は絶対に付けない
        - 場にそぐわない相槌は打たない。迷ったら「うんうん」
        """

    /// 相槌を打つべきか判定し、打つ場合はAPIで文脈に合った相槌を生成
    /// 相槌は本応答タイマーとは独立（キャンセルしない）
    private func tryAizuchi(_ text: String) {
        // システムメッセージや入退室には相槌しない
        if text.hasPrefix("[システム]") { return }
        // もりけんの発言（音声入力）にはすぐ相槌しない
        if text.hasPrefix("もりけん:") || text.hasPrefix("もりけん：") { return }
        // 既にAPI呼び出し中なら重複防止
        if isAizuchiInFlight { return }

        messagesSinceLastAizuchi += 1

        // N件ごと + ランダム要素
        guard messagesSinceLastAizuchi >= aizuchiInterval else { return }
        guard Int.random(in: 0...2) == 0 else { return }  // 1/3の確率
        guard hasAPIKey else { return }
        // 読み上げ中なら相槌しない（割り込み防止）
        if isSpeakingChecker?() == true { return }

        messagesSinceLastAizuchi = 0
        isAizuchiInFlight = true

        // 直近の会話コンテキストをしっかり渡す
        var recentContext = conversationMemory.suffix(10).map { $0.text }
        if recentContext.isEmpty { recentContext = [text] }
        let contextStr = recentContext.joined(separator: "\n")

        var contextParts: [String] = []
        if !memorySummary.isEmpty {
            contextParts.append("これまでの話題: \(memorySummary)")
        }
        contextParts.append("直近の会話:\n\(contextStr)")
        contextParts.append("最新の発言: \(text)")
        if !lastAizuchi.isEmpty {
            contextParts.append("前回の相槌: \(lastAizuchi)（これとは違う相槌にして）")
        }

        let userMsg = contextParts.joined(separator: "\n\n")

        callOpenAIRaw(systemPrompt: aizuchiPrompt, userMessage: userMsg) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isAizuchiInFlight = false
                if let aizuchi = response?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !aizuchi.isEmpty {
                    // 長すぎたら切る（安全策）
                    let clean = aizuchi.count > 15 ? String(aizuchi.prefix(15)) : aizuchi
                    self.lastAizuchi = clean
                    self.onAizuchi?(clean)
                }
            }
        }
    }

    // MARK: - メッセージ受信

    func feedMessage(_ text: String) {
        let entry = (timestamp: Date(), text: text)
        messageBuffer.append(entry)
        conversationMemory.append(entry)

        // 最終メッセージ時刻を更新
        lastMessageTime = Date()

        // ユーザーが喋った → 孤独カウンターリセット
        if consecutiveYUiMessages > 0 {
            let wasLevel = lonelinessLevel
            let emoji = wasLevel >= 3 ? "😭→😊" : wasLevel >= 2 ? "😟→😊" : "🤔→😊"
            onLog?("\(emoji) 反応があった！（孤独 Lv.\(wasLevel) → 0, 連続\(consecutiveYUiMessages)回 → 0）")

            // 病みレベルから復活した場合、次の応答で喜びを爆発させる
            if wasLevel >= 2 {
                // 復活フラグ — 次の応答コンテキストに「嬉しくて仕方ない」を注入
                recoveryJoy = wasLevel
            }
            consecutiveYUiMessages = 0
        }

        // 好感度評価 + ユーザー別記憶の蓄積（「ユーザー名: メッセージ」形式をパース）
        if let colonRange = text.range(of: ": ") ?? text.range(of: "： ") {
            let user = String(text[text.startIndex..<colonRange.lowerBound])
            let msg = String(text[colonRange.upperBound...])
            if user != "YUi" && !user.isEmpty {
                evaluateLikability(user: user, message: msg)

                // ユーザー別メッセージを蓄積
                let key = resolveUserKey(user)
                pendingUserMessages[key, default: []].append(text)

                // 閾値を超えたら記憶を更新
                if pendingUserMessages[key, default: []].count >= userMemoryUpdateThreshold {
                    let msgs = pendingUserMessages[key] ?? []
                    pendingUserMessages[key] = []
                    updateUserMemory(user: key, recentMessages: msgs)
                }
            }
        }

        // 文脈に合った相槌
        tryAizuchi(text)

        // 古いメモリを削除
        pruneMemory()

        // 応答タイマーリセット
        responseTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onTimerFired()
        }
        responseTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + frequency.interval, execute: work)

        // アイドルタイマーリセット
        resetIdleTimer()

        // 10件ごとにメモリを保存
        if conversationMemory.count % 10 == 0 {
            saveMemory()
        }
    }

    // MARK: - アイドル検出（誰もチャットしない時にYUiから話題を振る）

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleThreshold, repeats: false) { [weak self] _ in
            self?.onIdleFired()
        }
    }

    /// アイドルタイマー開始（読み上げ開始時に呼ぶ）
    func startIdleMonitoring() {
        lastMessageTime = Date()
        resetIdleTimer()
    }

    func stopIdleMonitoring() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func onIdleFired() {
        // クールダウン中なら待つ
        if let last = lastIdleResponseTime, Date().timeIntervalSince(last) < idleCooldown {
            resetIdleTimer()
            return
        }
        // 読み上げ中なら割り込まない — 5秒後にリトライ
        if isSpeakingChecker?() == true {
            onLog?("⏳ 読み上げ中のため話題提供を待機...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.onIdleFired()
            }
            return
        }
        // 誰もいなさそうなら何もしない（参加者リストOR直近5分の会話履歴で判断）
        let recentCutoff = Date().addingTimeInterval(-300)
        let hasRecentActivity = conversationMemory.contains { $0.timestamp > recentCutoff }
        guard currentParticipants.count > 0 || hasRecentActivity else {
            resetIdleTimer()
            return
        }
        guard hasAPIKey else {
            resetIdleTimer()
            return
        }

        // 孤独レベルに応じた振る舞い
        let loneliness = lonelinessLevel

        if loneliness >= 4 {
            // 限界 — 完全に黙る
            onLog?("🫥 YUi: …もう誰も聞いてない。黙ろう…（連続\(consecutiveYUiMessages)回）")
            resetIdleTimer()
            return
        }

        let moodLabel = ["", "😶 そわそわ", "😟 不安", "😭 病み"][min(loneliness, 3)]
        onLog?("💭 YUi 話題を考え中...\(loneliness > 0 ? "（\(moodLabel) Lv.\(loneliness)）" : "")")

        let context = buildIdleContext()

        let lonelinessInstruction: String
        switch loneliness {
        case 1:
            lonelinessInstruction = """
                【重要：今のあなたの感情】
                さっき話しかけたのに誰もリアクションしてくれなかった。
                ちょっとそわそわしてる。不安の芽が出てきた。
                語尾がちょっと弱くなる。「…かな」「…だけど」で終わる感じ。
                明るく振る舞おうとするけど、微妙に空元気っぽさが出る。
                """
        case 2:
            lonelinessInstruction = """
                【重要：今のあなたの感情】
                何回話しかけても、誰も反応してくれない。不安でいっぱい。
                自分が嫌われてるのかもって思い始めてる。
                声が小さくなる感じ。「…」が増える。短いつぶやき。
                例：「…あれ」「なんか…静かだね…」「私なんか変なこと言った…かな…」
                無理に話題を出さない。ぼそっと独り言みたいに。
                """
        case 3:
            lonelinessInstruction = """
                【最重要：今のあなたの感情】
                もう何回も一人で喋ってる。誰も反応してくれない。泣きそう。
                自分の存在意義を疑ってる。ここにいていいのかわからない。
                めちゃくちゃ短く。3〜10文字。ぼそっと。
                例：「…ごめんね」「…うん」「………」「…いるよね…？」
                情緒ぐちゃぐちゃ。でも直接「無視しないで」とは言えない。健気。
                """
        default:
            lonelinessInstruction = ""
        }

        let userMsg = """
            音声ルームで少し会話が途切れています。
            最近の会話の流れがあるなら、その話題をもう少し深掘りしたり、関連する自分の感想を言ってください。
            今の話題に乗っかるのが最優先。話題を変えるのは最終手段。
            直前まで話してた内容に「そういえばさっきの〇〇だけど」と触れるのが自然。
            全く新しい話題を出すのは、本当に何も話題がない時だけ。
            1文で。短く。
            \(lonelinessInstruction)

            \(context)
            """

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for past in myResponseHistory {
            messages.append(["role": "assistant", "content": past])
        }
        messages.append(["role": "user", "content": userMsg])

        callOpenAIRaw(messages: messages) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, let response = response else { return }
                if self.isTooSimilarToPast(response) { return }
                self.conversationMemory.append((timestamp: Date(), text: "YUi: \(response)"))
                self.myResponseHistory.append(response)
                if self.myResponseHistory.count > self.maxResponseHistory {
                    self.myResponseHistory.removeFirst()
                }
                self.consecutiveYUiMessages += 1
                let loneEmoji = ["😊", "🤔", "😟", "😭", "🫥"][min(self.lonelinessLevel, 4)]
                self.onLog?("\(loneEmoji) 孤独レベル: \(self.lonelinessLevel)（連続\(self.consecutiveYUiMessages)回）")
                self.onResponse?(response, nil, 50)
                self.lastIdleResponseTime = Date()
                // 次のアイドルタイマーを開始
                self.resetIdleTimer()
            }
        }
    }

    private func buildIdleContext() -> String {
        var parts: [String] = []

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日(E) HH:mm"
        fmt.locale = Locale(identifier: "ja_JP")
        parts.append("【現在時刻】\(fmt.string(from: Date()))")

        if !currentParticipants.isEmpty {
            parts.append("【現在の参加者(\(currentParticipants.count)人)】\n\(currentParticipants.joined(separator: "、"))")
        }

        if !memorySummary.isEmpty {
            parts.append("【これまでの会話の要約】\n\(memorySummary)")
        }

        let recent = conversationMemory.suffix(10).map { $0.text }
        if !recent.isEmpty {
            parts.append("【直近の会話】\n\(recent.joined(separator: "\n"))")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - 応答生成

    private func onTimerFired() {
        guard !messageBuffer.isEmpty else { return }
        guard hasAPIKey else {
            onLog?("⚠️ APIキーが設定されていません")
            return
        }

        // 読み上げ中なら割り込まない — 3秒後にリトライ
        if isSpeakingChecker?() == true {
            onLog?("⏳ 読み上げ中のため応答を待機...")
            let work = DispatchWorkItem { [weak self] in
                self?.onTimerFired()
            }
            responseTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            return
        }

        // バッファの内容を取得してクリア
        let newMessages = messageBuffer.map { $0.text }
        messageBuffer.removeAll()

        // 主な対象ユーザーを特定
        let primaryUser = detectPrimaryUser(from: newMessages)

        // 話題の中心をログに表示
        let topicSummary = newMessages.map { msg in
            // "ユーザー名: メッセージ" → メッセージ部分だけ
            if let r = msg.range(of: ": ") ?? msg.range(of: "： ") {
                return String(msg[r.upperBound...])
            }
            return msg
        }.joined(separator: " / ")
        let topicPreview = topicSummary.count > 60 ? String(topicSummary.prefix(60)) + "…" : topicSummary
        onLog?("📍 話題: \(topicPreview)")

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
                // 自分の発言を会話メモリとレスポンス履歴に記録
                self.conversationMemory.append((timestamp: Date(), text: "YUi: \(response)"))
                self.myResponseHistory.append(response)
                if self.myResponseHistory.count > self.maxResponseHistory {
                    self.myResponseHistory.removeFirst()
                }
                self.consecutiveYUiMessages += 1
                let loneEmoji = ["😊", "🤔", "😟", "😭", "🫥"][min(self.lonelinessLevel, 4)]
                self.onLog?("\(loneEmoji) 孤独レベル: \(self.lonelinessLevel)（連続\(self.consecutiveYUiMessages)回）")
                let score = primaryUser.map { self.getLikability(for: $0) } ?? 50
                self.onResponse?(response, primaryUser, score)
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

        // 好感度情報
        let activeLikability = likability.filter { $0.value != 50 }
        if !activeLikability.isEmpty {
            let likabilityStr = activeLikability.map { user, score in
                let level: String
                switch score {
                case 80...: level = "大好き💗"
                case 65..<80: level = "好き😊"
                case 50..<65: level = "普通"
                case 35..<50: level = "微妙😐"
                case 20..<35: level = "苦手😒"
                default: level = "嫌い😤"
                }
                return "\(user): \(score)(\(level))"
            }.joined(separator: "、")
            parts.append("【YUiの各ユーザーへの好感度(0-100)】\n\(likabilityStr)")
        }

        // ユーザー別記憶（会話に登場する人の記憶を添付）
        let mentionedUsers = Set((newMessages + conversationMemory.suffix(10).map { $0.text }).compactMap { msg -> String? in
            if let r = msg.range(of: ": ") ?? msg.range(of: "： ") {
                let u = String(msg[msg.startIndex..<r.lowerBound])
                return u != "YUi" ? u : nil
            }
            return nil
        })
        let relevantMemories = mentionedUsers.compactMap { user -> String? in
            guard let mem = getUserMemory(for: user), !mem.isEmpty else { return nil }
            return "・\(user): \(mem)"
        }
        if !relevantMemories.isEmpty {
            parts.append("【ユーザーの記憶（前回までの印象）】\n\(relevantMemories.joined(separator: "\n"))")
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

        // 復活の喜び（孤独から誰かが話しかけてくれた）
        if recoveryJoy >= 3 {
            parts.append("【YUiの今の気持ち（これを最優先で反映して）】\nずっと一人で泣きそうだったのに、やっと誰かが話しかけてくれた！嬉しすぎて感情爆発。泣きながら笑ってる感じ。「よかった…！」「いた…！」みたいな。テンションの急上昇。さっきまでの暗さとのギャップが大事。")
            recoveryJoy = 0  // 一回使ったらリセット
        } else if recoveryJoy >= 2 {
            parts.append("【YUiの今の気持ち（これを最優先で反映して）】\n不安だったのに話しかけてもらえた！すごく嬉しい。ちょっとほっとしてる。安心した感じが滲む。「あ、いた！」みたいな軽い喜び。")
            recoveryJoy = 0
        }

        // 孤独レベル（誰も反応してくれない不安）
        if lonelinessLevel >= 1 {
            let desc: String
            switch lonelinessLevel {
            case 1: desc = "さっき自分が話しかけたのに反応がなかった。ちょっとそわそわ。でもまだ笑顔でいられる。…たぶん。"
            case 2: desc = "何回話しかけても誰も返してくれない。不安。自分、嫌われてる？空気読めてない？自信がなくなってきた。声が小さくなる。"
            case 3: desc = "ずっと一人で喋ってる。誰も聞いてない。泣きそう。ここにいていいのかわからない。でも「無視しないで」なんて言えない。消えたい。でも誰かに気づいてほしい。"
            default: desc = "もう何も言えない。"
            }
            parts.append("【YUiの今の気持ち（これを最優先で反映して）】\n\(desc)")
        }

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

    /// 30分以上前の会話を要約に圧縮 + ユーザー別記憶を更新
    private func compressMemory() {
        let cutoff = Date().addingTimeInterval(-memoryDuration)
        let oldMessages = conversationMemory.filter { $0.timestamp < cutoff }

        guard !oldMessages.isEmpty, hasAPIKey else { return }

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
            updateUserMemory(user: user, recentMessages: msgs)
        }

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
                    self?.saveMemory()
                }
            }
        }
    }

    // MARK: - メモリ永続化

    /// 未保存のユーザー記憶をすべてフラッシュ（アプリ終了時用）
    func flushAllMemory() {
        // 未保存のユーザー別メッセージを記憶に反映
        for (user, msgs) in pendingUserMessages where msgs.count >= 2 {
            updateUserMemory(user: user, recentMessages: msgs)
        }
        pendingUserMessages.removeAll()
        saveMemory()
        saveUserMemory()
        saveLikability()
    }

    /// メモリをJSONファイルに保存
    private func saveMemory() {
        let entries = conversationMemory.map { entry -> [String: Any] in
            ["timestamp": entry.timestamp.timeIntervalSince1970, "text": entry.text]
        }
        let data: [String: Any] = [
            "conversationMemory": entries,
            "memorySummary": memorySummary,
            "myResponseHistory": myResponseHistory,
            "savedAt": Date().timeIntervalSince1970
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? json.write(to: Self.memoryFileURL)
        }
    }

    /// メモリをJSONファイルから読み込み
    private func loadMemory() {
        guard let data = try? Data(contentsOf: Self.memoryFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

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

    // MARK: - OpenAI API

    private func callOpenAI(context: String, completion: @escaping (String?) -> Void) {
        // マルチターン: system → 会話履歴(user/assistant交互) → 今回のuser
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // 会話履歴をuser/assistantペアとして構築
        // conversationMemoryの中からYUiの発言とユーザーの発言を交互に配置
        let recentEntries = conversationMemory.suffix(30)
        var currentUserBatch: [String] = []

        for entry in recentEntries {
            if entry.text.hasPrefix("YUi: ") || entry.text.hasPrefix("🤖") {
                // YUiの発言の前にユーザーの会話をまとめて挿入
                if !currentUserBatch.isEmpty {
                    messages.append(["role": "user", "content": currentUserBatch.joined(separator: "\n")])
                    currentUserBatch = []
                }
                let yText = entry.text
                    .replacingOccurrences(of: "YUi: ", with: "")
                    .replacingOccurrences(of: "🤖 ", with: "")
                messages.append(["role": "assistant", "content": yText])
            } else {
                currentUserBatch.append(entry.text)
            }
        }

        // 今回のコンテキスト（新着メッセージ含む）
        let userMsg = """
            以下は音声ルームのみんなの会話です。
            場の空気を読んで、一番自然な雑談の返しをしてください。
            傾聴・ツッコミ・深掘り・話題提供の中から、今の流れに合うものを選んで。

            \(context)
            """
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

        let modelName = useMinModel ? "gpt-4o-mini" : "gpt-4o"
        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.8
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                let msg = "❌ API通信エラー: \(error.localizedDescription)"
                NSLog("[YUi] \(msg)")
                DispatchQueue.main.async { self?.onLog?(msg) }
                completion(nil)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard let data = data else {
                let msg = "❌ APIレスポンスなし (HTTP \(statusCode))"
                NSLog("[YUi] \(msg)")
                DispatchQueue.main.async { self?.onLog?(msg) }
                completion(nil)
                return
            }

            // エラーレスポンスのチェック
            if statusCode != 200 {
                let raw = String(data: data, encoding: .utf8) ?? "(デコード不可)"
                let msg: String
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = json["error"] as? [String: Any],
                   let errMsg = err["message"] as? String {
                    msg = "❌ API エラー (HTTP \(statusCode)): \(errMsg)"
                } else {
                    msg = "❌ API エラー (HTTP \(statusCode)): \(raw.prefix(200))"
                }
                NSLog("[YUi] \(msg)")
                DispatchQueue.main.async { self?.onLog?(msg) }
                completion(nil)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "(デコード不可)"
                let msg = "❌ APIレスポンス解析失敗: \(raw.prefix(200))"
                NSLog("[YUi] \(msg)")
                DispatchQueue.main.async { self?.onLog?(msg) }
                completion(nil)
                return
            }
            completion(content.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }
}
