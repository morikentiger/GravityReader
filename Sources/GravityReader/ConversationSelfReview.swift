import Foundation

/// 相手の感情を推測せず、会話で確認できる返答上の改善点だけ点検する。
enum ConversationSelfReview {
    static func lesson(source: String, response: String, reactions: [String]) -> String {
        let feedback = reactions.joined(separator: " ")
        if ["答えてない", "答えていない", "違う", "ダメ", "だめ"].contains(where: feedback.contains) {
            return "相手から訂正・不満を示す発言があった。前の質問と返答を確認し、同じ相槌を繰り返さず具体的に答え直す。"
        }
        let request = ["教えて", "答えて", "続き", "何？", "なぜ", "どうして"].contains(where: source.contains)
        let vague = ["うーん", "どうだろう", "いいよね", "わかるよ", "面白いよね", "かぁ"].contains(where: response.contains)
        if request && vague {
            return "質問・要求に相槌や感想を返している可能性がある。次は要求された具体内容を一つ答え、不明なら確認する。効果は未確認。"
        }
        if source.contains("一つだけ") || source.contains("その続き") {
            return "省略された追加要求は、直前の自分の返答と相手の質問につなげて解釈する。新しい話題や相槌で置き換えない。"
        }
        return reactions.isEmpty
            ? "返答後の反応はまだない。成功と決めつけず、次の発言が質問・訂正・話題継続のどれかを確認する。"
            : "次の発言を観測したが、返答の効果はまだ判断できない。前の質問と次の発言のつながりを確認して返す。"
    }
}
