import AppKit

class GravityCaptureManager {
    private var statusBar: StatusBarController?
    var logWindow: LogWindowController?
    private var timer: Timer?
    let speechManager = SpeechManager()
    var yuiManager: YUiManager?
    private let gravityBundleID = "com.hiclub.gravity"
    private let pollInterval: TimeInterval = 2.0

    /// 一度読み上げたテキストはセッション中ずっと記憶（再読み上げしない）
    private var spokenHistory: Set<String> = []

    /// 前回ポーリングで取得したテキスト一覧（差分検出用）
    private var previousSnapshot: [String] = []

    private var isFirstPoll = true

    // MARK: - UIノイズフィルタ

    /// 完全一致で除外するUIテキスト
    private let uiNoiseExact: Set<String> = [
        "GRAVITY", "ゲスト", "参加メンバー", "メッセージを送信",
        "公開音声ルーム", "ランキング>>", "アナウンス >>",
        "不適切なワードが含まれています。",
    ]

    /// 前方一致・含有で除外するパターン
    private let uiNoisePrefixes = [
        "AI社長が訊く",
    ]

    /// 正規表現で除外するパターン
    private let uiNoisePatterns: [NSRegularExpression] = {
        let patterns = [
            #"^\d{1,3}%$"#,             // "100%", "23%" 等のパーセンテージ
            #"^\d{1,2}$"#,              // "2", "3" 等の単独数字
            #"^あと\d+日$"#,             // "あと6日" 等のカウントダウン
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private func isUINoiseOrSystemMessage(_ text: String) -> Bool {
        // 完全一致
        if uiNoiseExact.contains(text) { return true }

        // 前方一致
        for prefix in uiNoisePrefixes {
            if text.hasPrefix(prefix) { return true }
        }

        // 正規表現マッチ
        let range = NSRange(text.startIndex..., in: text)
        for regex in uiNoisePatterns {
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }

        // 極端に短いテキスト（1文字）はノイズの可能性が高い
        if text.count <= 1 { return true }

        return false
    }

    // MARK: - Public

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    func start() {
        NSLog("[GR] start() called. logWindow=\(logWindow != nil), statusBar=\(statusBar != nil)")
        spokenHistory.removeAll()
        previousSnapshot.removeAll()
        isFirstPoll = true
        statusBar?.setStatus("動作中 🔊")
        logWindow?.setStatus(running: true)

        poll()

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func speakTest() {
        NSLog("[GR] speakTest() called. logWindow=\(logWindow != nil)")
        let text = "GravityReaderのテストです。正常に読み上げています。"
        logWindow?.addEntry(text)
        speechManager.speak(text)
    }

    func speakText(_ text: String) {
        speechManager.speak(text)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speechManager.stop()
        statusBar?.setStatus("停止中")
        logWindow?.setStatus(running: false)
    }

    // MARK: - Polling

    private func poll() {
        let allTexts = extractTexts()

        if allTexts.isEmpty {
            logWindow?.addEntry("⚠️ テキスト取得できません — アクセシビリティ許可を確認してください")
            statusBar?.setStatus("⚠️ 許可が必要")
            return
        }

        // UIノイズを除外
        let texts = allTexts.filter { !isUINoiseOrSystemMessage($0) }

        if isFirstPoll {
            // 初回はベースラインとして記憶するだけ（読み上げしない）
            for text in texts { spokenHistory.insert(text) }
            previousSnapshot = texts
            isFirstPoll = false
            statusBar?.setStatus("✅ 準備完了 (\(texts.count)件)")
            logWindow?.addEntry("📌 ベースライン取得: \(texts.count)件 — ここから新着を読み上げます")
            return
        }

        // 前回のスナップショットにも spokenHistory にもないものだけが新着
        for text in texts {
            guard !spokenHistory.contains(text) else { continue }
            spokenHistory.insert(text)
            statusBar?.setLastRead(text)
            logWindow?.addEntry(text)
            speechManager.speak(text)
            yuiManager?.feedMessage(text)
        }

        previousSnapshot = texts
    }

    // MARK: - Accessibility

    private func extractTexts() -> [String] {
        guard let gravity = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == gravityBundleID
        }) else {
            NSLog("[GR] GRAVITY process not found!")
            return []
        }

        let axApp = AXUIElementCreateApplication(gravity.processIdentifier)
        var result: [String] = []
        collect(axApp, &result)
        return result
    }

    private func collect(_ el: AXUIElement, _ result: inout [String], _ depth: Int = 0) {
        guard depth < 20 else { return }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        if roleStr == "AXGenericElement" || roleStr == "AXStaticText" {
            for attr in [kAXDescriptionAttribute, kAXValueAttribute, kAXTitleAttribute] {
                var val: AnyObject?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
                   let t = val as? String {
                    let trimmed = t.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !result.contains(trimmed) {
                        result.append(trimmed)
                        break
                    }
                }
            }
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for kid in kids { collect(kid, &result, depth + 1) }
    }
}
