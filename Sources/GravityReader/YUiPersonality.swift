import Foundation

// MARK: - YUi パーソナリティスライダー

/// YUiの対話パーソナリティ設定（3軸スライダー + 自動モード）
struct YUiPersonality {
    /// 応答頻度 0.0=静か, 1.0=よく喋る
    var responseFrequency: Float = 0.5
    /// 対話スタンス 0.0=共感・受容, 1.0=挑戦・深掘り
    var dialogueStance: Float = 0.5
    /// 態度 0.0=ツンツン, 1.0=デレデレ
    var attitude: Float = 0.5
    /// 自動モード（YUiが状況に応じて自動調整）
    var autoMode: Bool = true

    // MARK: - 永続化

    private static let keyFrequency = "YUiPersonality_responseFrequency"
    private static let keyStance    = "YUiPersonality_dialogueStance"
    private static let keyAttitude  = "YUiPersonality_attitude"
    private static let keyAutoMode  = "YUiPersonality_autoMode"

    func save() {
        let d = AppDefaults.suite
        d.set(responseFrequency, forKey: Self.keyFrequency)
        d.set(dialogueStance, forKey: Self.keyStance)
        d.set(attitude, forKey: Self.keyAttitude)
        d.set(autoMode, forKey: Self.keyAutoMode)
    }

    static func load() -> YUiPersonality {
        let d = AppDefaults.suite
        var p = YUiPersonality()
        if d.object(forKey: keyFrequency) != nil { p.responseFrequency = d.float(forKey: keyFrequency) }
        if d.object(forKey: keyStance) != nil { p.dialogueStance = d.float(forKey: keyStance) }
        if d.object(forKey: keyAttitude) != nil { p.attitude = d.float(forKey: keyAttitude) }
        if d.object(forKey: keyAutoMode) != nil { p.autoMode = d.bool(forKey: keyAutoMode) } else { p.autoMode = true }
        return p
    }

    // MARK: - 応答間隔への反映

    /// responseFrequency スライダー値からベース応答間隔を算出
    var baseInterval: TimeInterval {
        // 0.0 → 60秒（静か）, 0.5 → 10秒, 1.0 → 3秒（よく喋る）
        let t = Double(1.0 - responseFrequency)
        return 3.0 + t * t * 57.0  // 二次カーブで自然な感覚
    }

    // MARK: - システムプロンプト修飾

    /// 現在のパーソナリティをLLMへの指示文に変換
    var promptModifier: String {
        var lines: [String] = []

        // 対話スタンス
        let stance = dialogueStance
        if stance < 0.3 {
            lines.append("【対話スタンス：共感重視】相手の気持ちに寄り添い、受け止めることを最優先。アドバイスや深掘りより「わかるよ」「そうだよね」。否定しない。")
        } else if stance < 0.7 {
            lines.append("【対話スタンス：バランス型】共感と深掘りをバランスよく。相手が語りたそうなら聞き、意見を求められたら自分の考えを伝える。")
        } else {
            lines.append("【対話スタンス：挑戦・深掘り重視】ただ同調するのではなく「本当にそう？」「もっとこうしたら？」と相手を前に進ませる。優しさは維持しつつ、甘やかさない。")
        }

        // 態度
        let att = attitude
        if att < 0.3 {
            lines.append("【態度：ツンツン】素直に褒めない。「べ、別にすごくないし」「…まぁ悪くないんじゃない」。照れ隠し。でも根は優しい。たまにデレる瞬間がギャップになる。")
        } else if att < 0.7 {
            lines.append("【態度：ナチュラル】普通の友達のような距離感。素直に笑うし、素直にツッコむ。特に飾らない。")
        } else {
            lines.append("【態度：デレデレ】親しみ全開。「すごい！」「えらい！」「好き！」ストレートに気持ちを伝える。甘えた口調も混ぜてOK。嬉しい時は隠さない。")
        }

        return lines.joined(separator: "\n")
    }
}

/// YUiの応答頻度
enum YUiFrequency: String, CaseIterable {
    case high = "高（即応答）"
    case medium = "中（20秒）"
    case low = "低（1分）"

    /// ベース待機時間（会話テンポで動的に調整される）
    var baseInterval: TimeInterval {
        switch self {
        case .high: return 5.0      // 5秒ベース → テンポに応じて3-8秒
        case .medium: return 20.0
        case .low: return 60.0
        }
    }
}
