import Foundation

/// Local turn planning. No extra model calls, no inferred personality scores saved
/// to user preferences, and only accepted, recent conversation is considered.
enum YUiConversationDirector {
    enum Move: String {
        case waiting = "会話待ち"
        case answer = "具体的に答える"
        case repair = "訂正を受け止める"
        case support = "気持ちを受け止める"
        case observe = "具体的なところを拾う"
        case perspective = "自分の見方を添える"
        case playful = "軽いユーモアで返す"
    }

    struct Plan: Equatable {
        let personality: YUiPersonality
        let move: Move
        let reason: String
        let isDirect: Bool
        let hasRecentConversation: Bool

        /// Frequency controls actual scheduling, not just wording. Direct requests
        /// need not wait a minute, but never bypass human speech / playback guards.
        var settlingDelay: TimeInterval {
            isDirect ? 1.5 : 2 + Double(1 - personality.responseFrequency) * 8
        }
        var minimumInterval: TimeInterval { isDirect ? 8 : personality.baseInterval }
        func schedulingDelay(now: Date, oldestInput: Date, lastReply: Date, listenUntil: Date) -> TimeInterval {
            let settling = min(settlingDelay, max(0, 20 - now.timeIntervalSince(oldestInput)))
            return max(settling, minimumInterval - now.timeIntervalSince(lastReply), listenUntil.timeIntervalSince(now), 0.1)
        }
        var allowsInitiation: Bool {
            hasRecentConversation && personality.responseFrequency >= 0.4 && move != .support && move != .repair
        }
        var status: String {
            let timing = isDirect ? "呼びかけ・質問を優先" : "発話間隔 ≥\(Int(minimumInterval.rounded()))秒"
            return "\(move.rawValue) · \(reason) · \(timing)"
        }
        var prompt: String {
            let action: String
            switch move {
            case .waiting:
                action = "新しい発言を待つ。過去の質問への答えを勝手に繰り返さない。"
            case .answer:
                action = "質問への答え・具体例・選択肢の結論を先に一つ出す。『一つだけかぁ』『難しいね』だけで終わらない。"
            case .repair:
                action = "直前の自分の答えのどこが違ったかを文脈から確認し、修正した答えを出す。言い訳や軽口を挟まない。"
            case .support:
                action = "相手が実際に話した出来事を一つ拾って受け止める。『わかるよ』だけ、安易な励まし、説教、冗談で片付けない。助言は求められた時だけ。"
            case .observe:
                action = "今の発言の具体的な物・行動・意外な点を一つ拾い、それについて感想を添える。内容を言い換えるだけの相槌にしない。"
            case .perspective:
                action = "今の話題について自分なら何を選ぶか、どう見るかを理由一つとともに示す。反対するための反対や無関係な話題転換をしない。"
            case .playful:
                action = "相手が出した具体的な物や状況を使って、短い比喩か軽いツッコミを一つ。人を傷つけたり、架空の体験・事実で笑いを取らない。無理なら具体的な感想でよい。"
            }
            return """
                【このターンの返し方】\(move.rawValue)
                \(action)
                \(personality.promptModifier)
                直前と同じ出だし・相槌・質問で返さない。面白さは発言の具体性と見方から出し、テンションや語尾だけで作らない。
                相手の質問と文脈を優先し、この方針が文脈に合わなければ無理に当てはめない。
                一度に一つのことだけ、短い1文で話して相手に番を返す。
                """
        }
    }

    static func plan(settings: YUiPersonality, history: [(timestamp: Date, text: String)],
                     replyCount: Int, now: Date = Date()) -> Plan {
        let recent = history.suffix(40).filter { now.timeIntervalSince($0.timestamp) >= 0 && now.timeIntervalSince($0.timestamp) <= 90 }
        let humans = recent.filter { !$0.text.hasPrefix("YUi:") && !$0.text.hasPrefix("[システム]") && !$0.text.hasSuffix("[不適切]") }
        let latest = humans.last.map { body($0.text).lowercased() } ?? ""
        var p = settings.clamped
        guard !latest.isEmpty else {
            if p.autoMode { p.responseFrequency = 0.15; p.dialogueStance = 0.5; p.attitude = 0.4 }
            return Plan(personality: p, move: .waiting, reason: "直近90秒に新しい会話なし", isDirect: false, hasRecentConversation: false)
        }
        let count = humans.filter { now.timeIntervalSince($0.timestamp) <= 30 }.count
        let ownCount = recent.filter { $0.text.hasPrefix("YUi:") && now.timeIntervalSince($0.timestamp) <= 30 }.count
        let question = contains(latest, ["?", "？", "教えて", "答えて", "どう思う", "どっち", "なぜ", "何で", "おすすめ", "どうすれば", "一つだけ", "ひとつだけ", "具体的に", "tell me", "what ", "why ", "how "])
        let called = contains(latest, ["yui", "ゆい", "ユイ"])
        let correction = contains(latest, ["そうじゃない", "違うよ", "違います", "答えになって", "さっき言った", "そういう意味", "that's not", "i meant"])
        // A brief follow-up retains the context of the preceding human turn.
        let emotionalContext = latest.count < 12 ? humans.suffix(2).map { body($0.text).lowercased() }.joined(separator: " ") : latest
        let sensitive = contains(emotionalContext, ["つらい", "辛い", "悲しい", "しんどい", "悩ん", "不安", "落ち込", "疲れた", "亡くな", "失恋", "つかれた", "i'm sad", "i am sad", "exhausted", "grieving", "worried"])
        let fun = contains(latest, ["笑", "草", "www", "楽しい", "おもしろ", "面白", "ゲーム", "遊ん", "やった", "lol", "haha", "funny", "game"])
        let direct = question || called || correction
        if p.autoMode {
            // Absolute targets avoid drift and do not depend on extreme manual settings.
            p.responseFrequency = count >= 6 ? 0.25 : count >= 3 ? 0.5 : 0.65
            p.dialogueStance = question ? 0.8 : 0.55
            p.attitude = fun ? 0.85 : 0.5
            if sensitive { p.responseFrequency = 0.35; p.dialogueStance = 0.15; p.attitude = 0.1 }
            if ownCount >= 2 { p.responseFrequency = min(p.responseFrequency, 0.2) }
            if direct { p.responseFrequency = max(p.responseFrequency, 0.55) }
            if correction { p.dialogueStance = 0.7; p.attitude = 0.1 }
        }
        let move: Move
        let reason: String
        if correction { move = .repair; reason = "直前への訂正を検出" }
        else if question { move = .answer; reason = sensitive ? "相談の質問に答える" : "質問・具体例の要求を検出" }
        else if sensitive { move = .support; reason = "負担や悩みを示す言葉を検出" }
        else if p.attitude >= 0.7 && replyCount % 3 != 2 { move = .playful; reason = p.autoMode ? "軽い雑談の言葉を検出" : "手動の遊び心を反映" }
        else if p.dialogueStance >= 0.65 || (p.dialogueStance >= 0.35 && replyCount % 3 == 1) { move = .perspective; reason = "具体的な見方を一つ添える" }
        else { move = .observe; reason = "話の中の具体的なところに反応" }
        let pace = !p.autoMode ? "" : ownCount >= 2 ? "・YUiが続いたので間を取る" : count >= 6 ? "・会話が活発なので控えめ" : ""
        return Plan(personality: p, move: move, reason: reason + pace, isDirect: direct, hasRecentConversation: true)
    }

    private static func contains(_ text: String, _ words: [String]) -> Bool { words.contains(where: text.contains) }
    private static func body(_ text: String) -> String {
        guard let range = text.range(of: ": ") ?? text.range(of: "： ") else { return text }
        return String(text[range.upperBound...])
    }
}
