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

    /// 話者別パーシャルライン（キー=話者名, 値=NSRange）
    /// 複数の話者の途中行を同時に表示・更新する
    private var partialLineRanges: [String: NSRange] = [:]

    /// 話者別に途中行を上書き更新（並列2行以上対応）
    func updatePartialEntry(_ text: String, speaker: String = "_default") {
        guard let storage = textView?.textStorage else { return }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let time = fmt.string(from: Date())

        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: "\(time) ",
            attributes: [
                .foregroundColor: NSColor(white: 0.45, alpha: 1),
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            ]
        ))
        line.append(NSAttributedString(
            string: "🗣 " + text + "\n",
            attributes: [
                .foregroundColor: NSColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 0.7),
                .font: NSFont.systemFont(ofSize: 13)
            ]
        ))

        if let range = partialLineRanges[speaker], range.location + range.length <= storage.length {
            // 前の途中行を置き換え — 他の話者の位置もずらす
            let oldLen = range.length
            let newLen = line.length
            let delta = newLen - oldLen

            storage.replaceCharacters(in: range, with: line)
            partialLineRanges[speaker] = NSRange(location: range.location, length: newLen)

            // この行より後ろにある他の話者の位置を調整
            for (key, otherRange) in partialLineRanges where key != speaker {
                if otherRange.location > range.location {
                    partialLineRanges[key] = NSRange(location: otherRange.location + delta, length: otherRange.length)
                }
            }
        } else {
            // 新しい途中行を追加
            let start = storage.length
            storage.append(line)
            partialLineRanges[speaker] = NSRange(location: start, length: line.length)
        }
        textView.scrollToEndOfDocument(nil)
    }

    /// 特定話者の途中行を消す（確定時に呼ぶ）
    func clearPartialEntry(speaker: String = "_default") {
        guard let storage = textView?.textStorage else { return }
        if let range = partialLineRanges[speaker], range.location + range.length <= storage.length {
            let removedLen = range.length
            storage.replaceCharacters(in: range, with: NSAttributedString())

            // 削除した行より後ろの話者の位置を調整
            for (key, otherRange) in partialLineRanges where key != speaker {
                if otherRange.location > range.location {
                    partialLineRanges[key] = NSRange(location: otherRange.location - removedLen, length: otherRange.length)
                }
            }
        }
        partialLineRanges.removeValue(forKey: speaker)
    }

    /// パーシャル行を確定行に変換（黄色→白に変化させる演出）
    func confirmPartialEntry(speaker: String, text: String) {
        guard let storage = textView?.textStorage else { return }

        if let range = partialLineRanges[speaker], range.location + range.length <= storage.length {
            // 既存のパーシャル行を確定テキスト+白色で置き換え
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let time = fmt.string(from: Date())

            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: "\(time) ",
                attributes: [
                    .foregroundColor: NSColor(white: 0.45, alpha: 1),
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                ]
            ))
            line.append(NSAttributedString(
                string: "🗣 \(speaker): \(text)\n",
                attributes: [
                    .foregroundColor: NSColor(white: 0.92, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            ))

            let oldLen = range.length
            let newLen = line.length
            let delta = newLen - oldLen

            storage.replaceCharacters(in: range, with: line)

            // 他の話者の位置を調整
            for (key, otherRange) in partialLineRanges where key != speaker {
                if otherRange.location > range.location {
                    partialLineRanges[key] = NSRange(location: otherRange.location + delta, length: otherRange.length)
                }
            }
            partialLineRanges.removeValue(forKey: speaker)

            entryCount += 1
            window?.title = "GravityReader ログ (\(entryCount))"
        } else {
            // パーシャル行がない場合は通常の確定行を追加
            addEntry("🗣 \(speaker): \(text)")
        }
    }

    /// 全話者の途中行をクリア
    func clearAllPartialEntries() {
        // 後ろから消す（位置ずれ防止）
        let sorted = partialLineRanges.sorted { $0.value.location > $1.value.location }
        guard let storage = textView?.textStorage else { return }
        for (_, range) in sorted {
            if range.location + range.length <= storage.length {
                storage.replaceCharacters(in: range, with: NSAttributedString())
            }
        }
        partialLineRanges.removeAll()
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
