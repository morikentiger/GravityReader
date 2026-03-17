import AppKit

class GravityCaptureManager {
    private var statusBar: StatusBarController?
    var logWindow: LogWindowController?
    private var timer: Timer?
    let speechManager = SpeechManager()
    var yuiManager: YUiManager?
    private let gravityBundleID = "com.hiclub.gravity"
    private let pollInterval: TimeInterval = 2.0

    private var spokenHistory: [String: Date] = [:]
    private let reuseInterval: TimeInterval = 300

    private var isFirstPoll = true

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    func start() {
        NSLog("[GR] start() called. logWindow=\(logWindow != nil), statusBar=\(statusBar != nil)")
        spokenHistory.removeAll()
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

    private func poll() {
        let texts = extractTexts()

        if texts.isEmpty {
            logWindow?.addEntry("⚠️ テキスト取得できません — アクセシビリティ許可を確認してください")
            statusBar?.setStatus("⚠️ 許可が必要")
            return
        }

        if isFirstPoll {
            let now = Date()
            for text in texts { spokenHistory[text] = now }
            isFirstPoll = false
            statusBar?.setStatus("✅ 準備完了 (\(texts.count)件)")
            logWindow?.addEntry("📌 ベースライン取得: \(texts.count)件 — ここから新着を読み上げます")
            return
        }

        let now = Date()
        spokenHistory = spokenHistory.filter { now.timeIntervalSince($0.value) < reuseInterval }

        for text in texts {
            guard spokenHistory[text] == nil else { continue }
            spokenHistory[text] = now
            statusBar?.setLastRead(text)
            logWindow?.addEntry(text)
            speechManager.speak(text)
            yuiManager?.feedMessage(text)
        }
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
