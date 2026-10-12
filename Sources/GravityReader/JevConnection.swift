import Foundation

/// Diagnostics deliberately exclude credentials, request bodies and server error bodies.
enum JevConnection {
    static let statusChanged = Notification.Name("JevStatusChanged")
    static let configurationChanged = Notification.Name("JevConfigurationChanged")

    static func publish(_ message: String) {
        AppDefaults.suite.set(message, forKey: "GR_JevLastStatus")
        NotificationCenter.default.post(name: statusChanged, object: nil)
    }

    static func failure(status: Int?, error: Error?) -> String {
        if let error = error as? URLError {
            return error.code == .timedOut ? "タイムアウト（5秒）。回線・サービス混雑を確認してください" : "通信エラー（\(error.code.rawValue)）。ネットワークを確認してください"
        }
        switch status ?? 0 {
        case 401: return "認証エラー（401）。TypeSafe APIキーを保存し直してください"
        case 403: return "利用権限エラー（403）。TypeSafeのアクセス権を確認してください"
        case 402: return "利用枠エラー（402）。TypeSafeの残高を確認してください"
        case 422: return "リクエスト形式エラー（422）"
        case 429: return "利用上限（429）。しばらく待って再試行してください"
        case 500...599: return "TypeSafe側の一時エラー（\(status ?? 0)）"
        default: return "接続失敗（HTTP \(status ?? 0)）"
        }
    }

    static func check(text: String = "こんにちは、今日はいい天気ですね。", context: [String] = [], completion: @escaping (JevCommentGate.Verdict, String) -> Void) {
        // Credential access can include a macOS prompt and must not share the network deadline.
        DispatchQueue.global(qos: .userInitiated).async {
            let key = KeychainHelper.load(key: JevCommentGate.keychainKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                DispatchQueue.main.async { completion(.unavailable, "APIキー未取得。保存状態とmacOSのキーチェーン許可を確認してください") }
                return
            }
            send(text: text, context: context, key: key, completion: completion)
        }
    }

    static func send(text: String, context: [String], key: String, session: URLSession = .shared, completion: @escaping (JevCommentGate.Verdict, String) -> Void) {
        guard let request = try? JevCommentGate.makeRequest(text: text, context: context, key: key) else {
            DispatchQueue.main.async { completion(.unavailable, "判定リクエストを作成できません") }
            return
        }
        let started = Date()
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let verdict: JevCommentGate.Verdict
            let message: String
            if error != nil || status != 200 {
                verdict = .unavailable
                message = failure(status: status, error: error)
            } else if let data = data, JevCommentGate.parse(data) != .unavailable {
                verdict = JevCommentGate.parse(data)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let answer = (json?["answers"] as? [String: [String: Any]])?["moderation"]
                let probabilities = answer?["probabilities"] as? [String: Double]
                let probability = probabilities?["spam"] ?? 0
                let confidence = answer?["confidence"] as? Double ?? 0
                message = String(format: "判定成功 %.2f秒・スパム確率 %.0f%%・確信度 %.0f%%", Date().timeIntervalSince(started), probability * 100, confidence * 100)
            } else {
                verdict = .unavailable
                message = "応答形式エラー（HTTP 200）。判定結果を読み取れません"
            }
            DispatchQueue.main.async { completion(verdict, message) }
        }.resume()
    }
}
