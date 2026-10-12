import Foundation

/// Fish Audio REST TTS: https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech
struct FishAudioRequest {
    static let keychainKey = "FishAudioAPIKey"
    static let models = ["s2.1-pro-free", "s2.1-pro", "s2-pro", "s1"]

    static func make(text: String, apiKey: String, referenceID: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(models.contains(model) ? model : models[0], forHTTPHeaderField: "model")
        var body: [String: Any] = ["text": text, "format": "mp3", "normalize": true]
        let reference = referenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty { body["reference_id"] = reference }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func failureMessage(status: Int?) -> String {
        switch status ?? 0 {
        case 401, 403: return "APIキーまたはアクセス権を確認してください"
        case 402: return "Fish Audioの残高・利用枠を確認してください"
        case 429: return "リクエスト上限に達しました"
        case 400, 404, 422: return "声のID・モデル設定を確認してください"
        case 500...599: return "Fish Audio側で一時的なエラーが発生しました"
        default: return "接続に失敗しました"
        }
    }
}
