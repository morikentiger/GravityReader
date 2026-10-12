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
        send(messages: messages, jsonOnly: false, completion: completion)
    }

    func callJSON(systemPrompt: String, userMessage: String, completion: @escaping (String?) -> Void) {
        send(messages: [["role": "system", "content": systemPrompt], ["role": "user", "content": userMessage]], jsonOnly: true, completion: completion)
    }

    private func send(messages: [[String: String]], jsonOnly: Bool, completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let modelName = useMinModel ? "gpt-4o-mini" : "gpt-4o"
        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.8,
            "max_tokens": jsonOnly ? 1200 : 600
        ]

        if jsonOnly { body["response_format"] = ["type": "json_object"] }
        request.timeoutInterval = 30
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
            "max_tokens": 100,
            "stream": true
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let delegate = StreamingDelegate(onSentence: onSentence, onComplete: onComplete)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
}

// MARK: - ストリーミングデリゲート

final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    private let onSentence: (String) -> Void
    private let onComplete: (String?) -> Void
    private var lines = SSELineBuffer()
    private var buffer = ""
    private var fullText = ""
    private var completed = false
    private let sentenceSeparators: Set<Character> = ["。", "！", "？", "!", "?", "\n"]

    init(onSentence: @escaping (String) -> Void, onComplete: @escaping (String?) -> Void) {
        self.onSentence = onSentence
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(success: false)
            completionHandler(.cancel)
            session.invalidateAndCancel()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !completed else { return }
        for line in lines.append(data) {
            process(line)
            if completed { session.finishTasksAndInvalidate(); break }
        }
    }

    private func process(_ line: String) {
        guard !completed, line.hasPrefix("data:") else { return }
        let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if jsonString == "[DONE]" { finish(success: true); return }
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if json["error"] != nil { finish(success: false); return }
        guard let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return }
        buffer += content
        fullText += content
        while let end = buffer.firstIndex(where: { sentenceSeparators.contains($0) }) {
            let sentence = String(buffer[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: end)...])
            if !sentence.isEmpty { DispatchQueue.main.async { self.onSentence(sentence) } }
        }
    }

    private func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        if success {
            let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { DispatchQueue.main.async { self.onSentence(sentence) } }
        }
        buffer = ""
        let result = success && !fullText.isEmpty ? fullText : nil
        DispatchQueue.main.async { self.onComplete(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, let finalLine = lines.finish() { process(finalLine) }
        finish(success: error == nil)
        session.finishTasksAndInvalidate()
    }
}
