import Foundation

// MARK: - YUi パーソナリティスライダー

/// YUiの対話パーソナリティ設定（3軸スライダー + 自動モード）
struct YUiPersonality: Equatable {
    /// 応答頻度 0.0=静か, 1.0=よく喋る
    var responseFrequency: Float = 0.5
    /// 対話スタンス 0.0=共感・受容, 1.0=挑戦・深掘り
    var dialogueStance: Float = 0.5
    /// 遊び心 0.0=落ち着き, 1.0=軽妙（保存キーは互換維持）
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

    var clamped: YUiPersonality {
        var p = self
        p.responseFrequency = responseFrequency.isFinite ? min(1, max(0, responseFrequency)) : 0.5
        p.dialogueStance = dialogueStance.isFinite ? min(1, max(0, dialogueStance)) : 0.5
        p.attitude = attitude.isFinite ? min(1, max(0, attitude)) : 0.5
        return p
    }

    /// 自発的な応答の最短間隔。0 → 60秒、0.5 → 21秒、1 → 8秒。
    var baseInterval: TimeInterval {
        let t = Double(1 - clamped.responseFrequency)
        return 8 + t * t * 52
    }

    var manualFrequencyPreset: YUiFrequency? {
        guard !autoMode else { return nil }
        return YUiFrequency.allCases.first { abs($0.sliderValue - responseFrequency) < 0.001 }
    }

    var promptModifier: String {
        let p = clamped
        let stance: String
        if p.dialogueStance < 0.3 {
            stance = "相手が挙げた具体的な出来事や感覚を拾う。共感の定型句や頼まれていない助言で済ませない。"
        } else if p.dialogueStance < 0.7 {
            stance = "具体的な感想か自分の見方を一つ添える。毎回質問で終わらせず、相手が続けられる余地を残す。"
        } else {
            stance = "自分の見方・理由・意外な比較を一つ示す。説教や無理な反論ではなく、話題の別の面を見せる。"
        }
        let play: String
        if p.attitude < 0.3 {
            play = "落ち着いて率直に。冷たくしたり、わざと褒め渋る演技はしない。"
        } else if p.attitude < 0.7 {
            play = "自然な友達の距離感。内容に合えば軽いツッコミもよいが、無理に笑いを取らない。"
        } else {
            play = "話題に沿う短い比喩・意外な視点・軽いツッコミを使える。大げさな称賛やツンデレの定型演技はしない。"
        }
        return "【視点】\(stance)\n【遊び心】\(play)\n相談・訂正・事実への質問では、ユーモアより相手の求める内容を優先する。"
    }

}

/// YUiの応答頻度
enum YUiFrequency: String, CaseIterable {
    case high = "高（即応答）"
    case medium = "中（20秒）"
    case low = "低（1分）"

    var displayTitle: String {
        switch self {
        case .high: return "よく参加（通常9秒以上）"
        case .medium: return "ふつう（通常21秒以上）"
        case .low: return "聞き役（通常50秒以上）"
        }
    }

    var sliderValue: Float {
        switch self {
        case .high: return 0.85
        case .medium: return 0.5
        case .low: return 0.1
        }
    }
}
