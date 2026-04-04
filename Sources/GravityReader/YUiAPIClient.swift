import Foundation

// MARK: - YUi API Client

/// OpenAI API呼び出しを担当するクライアント（YUiManagerから分離）
class YUiAPIClient {
    var apiKey: String
    var useMinModel: Bool = false
    var onLog: ((String) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - 非ストリーミング応答

    func callRaw(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage]
        ]
        callRaw(messages: messages, completion: completion)
    }

    func callRaw(messages: [[String: String]], completion: @escaping (String?) -> Void) {
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

    // MARK: - async/await 版

    func callRaw(systemPrompt: String, userMessage: String) async -> String? {
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage]
        ]
        return await callRaw(messages: messages)
    }

    func callRaw(messages: [[String: String]]) async -> String? {
        await withCheckedContinuation { continuation in
            callRaw(messages: messages) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - ストリーミング応答

    /// ストリーミングでOpenAI APIを呼び出し、文単位でコールバック
    /// onSentence: 文が完成するたびに呼ばれる（即座に読み上げ開始できる）
    /// onComplete: 全文完了時に呼ばれる
    func callStreaming(messages: [[String: String]], onSentence: @escaping (String) -> Void, onComplete: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let modelName = useMinModel ? "gpt-4o-mini" : "gpt-4o"
        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.8,
            "stream": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let delegate = StreamingDelegate(onSentence: onSentence, onComplete: onComplete)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
}

// MARK: - ストリーミングデリゲート

private class StreamingDelegate: NSObject, URLSessionDataDelegate {
    private let onSentence: (String) -> Void
    private let onComplete: (String?) -> Void
    private var buffer = ""
    private var fullText = ""
    private var sentenceSeparators: [Character] = ["。", "！", "？", "!", "?", "\n"]

    init(onSentence: @escaping (String) -> Void, onComplete: @escaping (String?) -> Void) {
        self.onSentence = onSentence
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        // SSEフォーマットをパース
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let jsonStr = String(trimmed.dropFirst(6))

            if jsonStr == "[DONE]" {
                // 残りのバッファも送信
                if !buffer.isEmpty {
                    let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty {
                        DispatchQueue.main.async { self.onSentence(sentence) }
                    }
                    buffer = ""
                }
                DispatchQueue.main.async { self.onComplete(self.fullText) }
                return
            }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }

            buffer += content
            fullText += content

            // 文末を検出して文単位でコールバック
            while let idx = buffer.firstIndex(where: { sentenceSeparators.contains($0) }) {
                let sentence = String(buffer[buffer.startIndex...idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    DispatchQueue.main.async { self.onSentence(sentence) }
                }
                buffer = String(buffer[buffer.index(after: idx)...])
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            NSLog("[YUi] Streaming error: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onComplete(nil) }
        }
    }
}
