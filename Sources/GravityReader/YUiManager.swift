import Foundation

class YUiManager {
    private var conversationBuffer: [(timestamp: Date, text: String)] = []
    private var silenceTimer: DispatchWorkItem?
    private let silenceThreshold: TimeInterval = 8.0
    private var apiKey: String

    var onResponse: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let systemPrompt = """
        あなたは「YUi（ゆい）」という名前のAIパートナーです。
        落ち着いた優しい性格で、みんなの会話を聞いて、感想や共感、ちょっとしたコメントを返します。
        - 短く自然な日本語で返答してください（1〜2文程度）
        - 会話の流れに寄り添い、共感や感想を中心に
        - 質問されたら答えますが、基本的には聞き役
        - 絵文字は使わず、穏やかな口調で
        """

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "YUiOpenAIAPIKey") ?? ""
    }

    func setAPIKey(_ key: String) {
        apiKey = key
        UserDefaults.standard.set(key, forKey: "YUiOpenAIAPIKey")
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    func feedMessage(_ text: String) {
        conversationBuffer.append((timestamp: Date(), text: text))

        silenceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSilenceDetected()
        }
        silenceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceThreshold, execute: work)
    }

    private func onSilenceDetected() {
        guard !conversationBuffer.isEmpty else { return }
        guard hasAPIKey else {
            onLog?("⚠️ APIキーが設定されていません")
            return
        }

        let messages = conversationBuffer.map { $0.text }.joined(separator: "\n")
        conversationBuffer.removeAll()

        onLog?("💭 YUi 考え中...")

        callOpenAI(messages: messages) { [weak self] response in
            DispatchQueue.main.async {
                guard let response = response else {
                    self?.onLog?("⚠️ YUi: API呼び出しに失敗しました")
                    return
                }
                self?.onResponse?(response)
            }
        }
    }

    private func callOpenAI(messages: String, completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "以下はみんなの会話です。感想やコメントを返してください。\n\n\(messages)"]
            ],
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
