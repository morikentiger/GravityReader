import AppKit

class LogWindowController: NSWindowController {
    private var textView: NSTextView!
    private var entryCount = 0

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GravityReader ログ"
        window.minSize = NSSize(width: 240, height: 300)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)

        self.init(window: window)

        // NSTextView.scrollableTextView() で正しく配線されたScrollView+TextViewを生成
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        textView.textColor = NSColor(white: 0.9, alpha: 1)
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)

        // contentViewにぴったり配置
        scrollView.frame = window.contentView!.bounds
        scrollView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(scrollView)

        if let screen = NSScreen.main {
            let sw = screen.visibleFrame
            window.setFrame(NSRect(
                x: sw.maxX - 308, y: sw.midY - 300,
                width: 300, height: 600
            ), display: false)
        }
    }

    func addEntry(_ text: String, isYUi: Bool = false) {
        guard let storage = textView?.textStorage else { return }

        entryCount += 1

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let time = fmt.string(from: Date())

        let textColor = isYUi
            ? NSColor(red: 0.5, green: 0.9, blue: 0.8, alpha: 1)
            : NSColor(white: 0.92, alpha: 1)

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: "\(time) ",
            attributes: [
                .foregroundColor: NSColor(white: 0.45, alpha: 1),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            ]
        ))
        line.append(NSAttributedString(
            string: text + "\n",
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        ))

        storage.append(line)
        textView.scrollToEndOfDocument(nil)
        window?.title = "GravityReader ログ (\(entryCount))"
    }

    func setStatus(running: Bool) {
        // ウィンドウタイトルに状態を反映
        let prefix = running ? "🔊" : "⏸"
        window?.title = "\(prefix) GravityReader ログ (\(entryCount))"
    }

    @objc private func clearLog() {
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        entryCount = 0
        window?.title = "GravityReader ログ"
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
