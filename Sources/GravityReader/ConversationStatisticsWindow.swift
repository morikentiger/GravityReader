import AppKit

final class ConversationStatisticsWindow: NSWindowController, NSWindowDelegate {
    private let statistics: ConversationStatistics
    private let textView = NSTextView()
    private var timer: Timer?
    var plan: YUiConversationDirector.Plan?
    var activity = "新しい発言を待つ"

    init(statistics: ConversationStatistics) {
        self.statistics = statistics
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "会話の状態と統計"
        window.minSize = NSSize(width: 480, height: 440)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.frame = scroll.contentView.bounds
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    func refresh() {
        let now = Date()
        let s = statistics.snapshot(now: now)
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—（未計測）" }
        func age(_ time: Date?) -> String { time.map { "\(max(0, Int(now.timeIntervalSince($0))))秒前" } ?? "まだありません" }
        let result = NSMutableAttributedString()
        func section(_ title: String, _ body: String) {
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            result.append(NSAttributedString(string: body + "\n\n", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(white: 0.88, alpha: 1), .paragraphStyle: paragraph]))
        }
        section("いまのYUi", activity + "\n" + (plan?.status ?? "会話の判断を待っています"))
        section("直近5分の会話", "受け取った音声 \(s.voice)件　コメント \(s.comments)件　YUiの返答 \(s.replies)件\nYUiの割合：発言数 \(percent(s.replyShare)) ／ 文字量 \(percent(s.characterShare))\n最後の入力：\(age(s.lastInput))　最後の返答：\(age(s.lastReply))")
        let latency = s.medianLatency.map { String(format: "%.1f秒（%d件の中央値）", $0, s.latencySamples) } ?? "—（返答待ち）"
        section("返答の待ち時間", "\(latency)\n最新入力の受信から、返答を読み上げへ送るまで。\n人の発話待ち・生成時間を含み、TTSの準備・再生時間は含みません。")
        let trend = s.minutes.enumerated().map { index, bucket in
            "\(5 - index)〜\(4 - index)分前　人 \(bucket.human)件　YUi \(bucket.yui)件"
        }.joined(separator: "\n")
        section("1分ごとの変化（古い順）", trend)
        let suppressions = s.suppressed.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)件" }.joined(separator: "\n")
        section("直近5分の抑制・除外", suppressions.isEmpty ? "抑制・除外の記録はありません。" : suppressions)
        section("今回の起動から", "入力 \(s.sessionInputs)件　返答 \(s.sessionReplies)件　抑制・除外 \(s.sessionSuppressed)件\n\n会話数はYUiが受け取った入力と出力を集計。システムログは含みません。\n音声は確定した区切りを1件と数えます。割合は発話時間ではありません。\n本文や発言者名は統計に保存せず、再起動でリセットします。毎秒更新。")
        let selection = textView.selectedRange()
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        textView.textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { textView.setSelectedRange(selection) }
        if let origin = origin { textView.enclosingScrollView?.contentView.scroll(to: origin) }
    }
}
