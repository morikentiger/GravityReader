import AppKit

// MARK: - Log Entry Model
private struct LogEntry {
    let id: UUID = UUID()
    let timestamp: Date
    let text: String
    let isYUi: Bool
    let speaker: String?         // nil = system
    let attributedString: NSAttributedString

    var category: LogCategory {
        if isYUi { return .yui }
        if let s = speaker, !s.isEmpty, s != "_default" { return .user }
        // Heuristic: if text starts with speaker emoji, treat as user
        if text.hasPrefix("\u{1F5E3}") { return .user }
        return .system
    }
}

private enum LogCategory: String {
    case all    = "全て"
    case yui    = "YUi"
    case user   = "ユーザー"
    case system = "システム"
}

class LogWindowController: NSWindowController, NSTextFieldDelegate, NSMenuDelegate {
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var entryCount = 0

    // --- Search / Filter ---
    private var searchField: NSTextField!
    private var filterPopup: NSPopUpButton!
    private var bookmarkToggleButton: NSButton!
    private var searchBarContainer: NSView!

    // --- Statistics panel ---
    private var statsContainer: NSView!
    private var statsLabel: NSTextField!
    private var statsToggleButton: NSButton!
    private var statsVisible = false

    // --- Personality sliders ---
    private var sliderContainer: NSView!
    private var frequencySlider: NSSlider!
    private var stanceSlider: NSSlider!
    private var attitudeSlider: NSSlider!
    private var autoModeToggle: NSButton!
    private var frequencyValueLabel: NSTextField!
    private var stanceValueLabel: NSTextField!
    private var attitudeValueLabel: NSTextField!
    /// コールバック：スライダー変更時
    var onPersonalityChanged: ((YUiPersonality) -> Void)?
    /// 現在のパーソナリティ（外部から設定）
    private var currentPersonality = YUiPersonality.load()

    // --- Data model ---
    private var allEntries: [LogEntry] = []
    private var filteredEntryIDs: Set<UUID> = []
    private var isFiltering = false
    private var showBookmarksOnly = false

    // --- Bookmarks ---
    private var bookmarkedIDs: Set<String> = []   // stored as UUID strings
    private let bookmarksDefaultsKey = "GravityReaderLogBookmarks"

    // --- Statistics ---
    private var speakerCounts: [String: Int] = [:]
    private var sessionStart = Date()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GravityReader ログ"
        window.minSize = NSSize(width: 240, height: 400)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)

        self.init(window: window)

        loadBookmarks()
        buildUI(in: window)

        if let screen = NSScreen.main {
            let sw = screen.visibleFrame
            window.setFrame(NSRect(
                x: sw.maxX - 308, y: sw.midY - 350,
                width: 300, height: 700
            ), display: false)
        }
    }

    // MARK: - UI Construction

    private func buildUI(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        // ── Search bar container (top) ──
        searchBarContainer = NSView()
        searchBarContainer.translatesAutoresizingMaskIntoConstraints = false
        searchBarContainer.wantsLayer = true
        searchBarContainer.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        contentView.addSubview(searchBarContainer)

        searchField = NSTextField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "検索..."
        searchField.font = .systemFont(ofSize: 12)
        searchField.isBezeled = true
        searchField.bezelStyle = .roundedBezel
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.cell?.sendsActionOnEndEditing = false
        // Dark appearance styling
        searchField.backgroundColor = NSColor(white: 0.2, alpha: 1)
        searchField.textColor = NSColor(white: 0.9, alpha: 1)
        searchBarContainer.addSubview(searchField)

        filterPopup = NSPopUpButton()
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.font = .systemFont(ofSize: 11)
        filterPopup.addItems(withTitles: ["全て", "YUi", "ユーザー", "システム"])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        searchBarContainer.addSubview(filterPopup)

        bookmarkToggleButton = NSButton(title: "\u{1F516}", target: self, action: #selector(toggleBookmarkView))
        bookmarkToggleButton.translatesAutoresizingMaskIntoConstraints = false
        bookmarkToggleButton.isBordered = false
        bookmarkToggleButton.font = .systemFont(ofSize: 14)
        bookmarkToggleButton.toolTip = "ブックマーク一覧"
        searchBarContainer.addSubview(bookmarkToggleButton)

        NSLayoutConstraint.activate([
            searchBarContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            searchBarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            searchBarContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            searchBarContainer.heightAnchor.constraint(equalToConstant: 32),

            searchField.leadingAnchor.constraint(equalTo: searchBarContainer.leadingAnchor, constant: 4),
            searchField.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            filterPopup.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 4),
            filterPopup.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),
            filterPopup.widthAnchor.constraint(equalToConstant: 80),

            bookmarkToggleButton.leadingAnchor.constraint(equalTo: filterPopup.trailingAnchor, constant: 2),
            bookmarkToggleButton.trailingAnchor.constraint(lessThanOrEqualTo: searchBarContainer.trailingAnchor, constant: -4),
            bookmarkToggleButton.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),

            searchField.trailingAnchor.constraint(equalTo: filterPopup.leadingAnchor, constant: -4),
        ])

        // ── Stats container (bottom, collapsible) ──
        statsContainer = NSView()
        statsContainer.translatesAutoresizingMaskIntoConstraints = false
        statsContainer.wantsLayer = true
        statsContainer.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        statsContainer.isHidden = true
        contentView.addSubview(statsContainer)

        statsLabel = NSTextField(labelWithString: "")
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = NSColor(white: 0.75, alpha: 1)
        statsLabel.maximumNumberOfLines = 0
        statsLabel.lineBreakMode = .byWordWrapping
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsContainer.addSubview(statsLabel)

        // Stats toggle button (always visible at bottom-left)
        statsToggleButton = NSButton(title: "📊 統計", target: self, action: #selector(toggleStats))
        statsToggleButton.translatesAutoresizingMaskIntoConstraints = false
        statsToggleButton.bezelStyle = .recessed
        statsToggleButton.isBordered = true
        statsToggleButton.font = .systemFont(ofSize: 11)
        statsToggleButton.toolTip = "統計パネル表示/非表示"
        statsToggleButton.setButtonType(.pushOnPushOff)
        contentView.addSubview(statsToggleButton)

        // ── Personality slider container (bottom) ──
        sliderContainer = NSView()
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        sliderContainer.wantsLayer = true
        sliderContainer.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        contentView.addSubview(sliderContainer)

        buildSliderPanel()

        // ── Scroll view + text view (middle) ──
        let sv = NSTextView.scrollableTextView()
        scrollView = sv
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView = sv.documentView as? NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        textView.textColor = NSColor(white: 0.9, alpha: 1)
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)

        // Context menu for bookmarks
        let menu = NSMenu()
        menu.delegate = self
        textView.menu = menu

        contentView.addSubview(scrollView)

        // Stats container constraints
        let statsHeight = statsContainer.heightAnchor.constraint(equalToConstant: 80)
        statsHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            // Slider container at very bottom
            sliderContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sliderContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sliderContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sliderContainer.heightAnchor.constraint(equalToConstant: 72),

            // Stats toggle button above slider container
            statsToggleButton.bottomAnchor.constraint(equalTo: sliderContainer.topAnchor, constant: -2),
            statsToggleButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            statsToggleButton.heightAnchor.constraint(equalToConstant: 24),
            statsToggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),

            // Stats container above toggle button
            statsContainer.bottomAnchor.constraint(equalTo: statsToggleButton.topAnchor),
            statsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statsHeight,

            statsLabel.topAnchor.constraint(equalTo: statsContainer.topAnchor, constant: 4),
            statsLabel.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor, constant: -8),
            statsLabel.bottomAnchor.constraint(lessThanOrEqualTo: statsContainer.bottomAnchor, constant: -4),

            // Scroll view fills space between search bar and stats
            scrollView.topAnchor.constraint(equalTo: searchBarContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // scrollView の下端は動的に管理（統計パネル表示/非表示で切り替え）
        updateScrollViewBottomConstraint()

        // Cmd+F key handling via monitor
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "f" {
                if self.window?.isKeyWindow == true {
                    self.window?.makeFirstResponder(self.searchField)
                    return nil
                }
            }
            return event
        }
    }

    private var scrollViewBottomConstraint: NSLayoutConstraint?

    private func updateScrollViewBottomConstraint() {
        guard let contentView = window?.contentView else { return }
        scrollViewBottomConstraint?.isActive = false

        if statsVisible {
            scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: statsContainer.topAnchor)
        } else {
            scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: statsToggleButton.topAnchor)
        }
        scrollViewBottomConstraint?.isActive = true
        contentView.layoutSubtreeIfNeeded()
    }

    // MARK: - Personality Slider Panel

    private func buildSliderPanel() {
        let labelColor = NSColor(white: 0.55, alpha: 1)
        let valueColor = NSColor(white: 0.8, alpha: 1)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

        // 3つのスライダーを横に並べる
        // 各スライダー: ラベル(上) + スライダー(中) + 値ラベル(下)
        let sliderData: [(String, String, Float, Selector)] = [
            ("応答頻度", "静か ← → よく喋る", currentPersonality.responseFrequency, #selector(frequencySliderChanged(_:))),
            ("スタンス", "共感 ← → 挑戦", currentPersonality.dialogueStance, #selector(stanceSliderChanged(_:))),
            ("態度", "ツン ← → デレ", currentPersonality.attitude, #selector(attitudeSliderChanged(_:))),
        ]

        var sliders: [NSSlider] = []
        var valueLabels: [NSTextField] = []
        var columns: [NSView] = []

        for (title, hint, value, action) in sliderData {
            let col = NSView()
            col.translatesAutoresizingMaskIntoConstraints = false
            sliderContainer.addSubview(col)
            columns.append(col)

            // タイトルラベル
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = labelFont
            titleLabel.textColor = valueColor
            titleLabel.alignment = .center
            col.addSubview(titleLabel)

            // スライダー
            let slider = NSSlider(value: Double(value), minValue: 0.0, maxValue: 1.0,
                                  target: self, action: action)
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.controlSize = .small
            slider.isContinuous = true
            col.addSubview(slider)
            sliders.append(slider)

            // ヒントラベル
            let hintLabel = NSTextField(labelWithString: hint)
            hintLabel.translatesAutoresizingMaskIntoConstraints = false
            hintLabel.font = NSFont.systemFont(ofSize: 8)
            hintLabel.textColor = labelColor
            hintLabel.alignment = .center
            col.addSubview(hintLabel)

            // 値ラベル
            let valLabel = NSTextField(labelWithString: String(format: "%.0f%%", value * 100))
            valLabel.translatesAutoresizingMaskIntoConstraints = false
            valLabel.font = valueFont
            valLabel.textColor = labelColor
            valLabel.alignment = .center
            col.addSubview(valLabel)
            valueLabels.append(valLabel)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: col.topAnchor, constant: 2),
                titleLabel.centerXAnchor.constraint(equalTo: col.centerXAnchor),

                slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                slider.leadingAnchor.constraint(equalTo: col.leadingAnchor, constant: 4),
                slider.trailingAnchor.constraint(equalTo: col.trailingAnchor, constant: -4),

                hintLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 1),
                hintLabel.centerXAnchor.constraint(equalTo: col.centerXAnchor),

                valLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 0),
                valLabel.centerXAnchor.constraint(equalTo: col.centerXAnchor),
            ])
        }

        frequencySlider = sliders[0]
        stanceSlider = sliders[1]
        attitudeSlider = sliders[2]
        frequencyValueLabel = valueLabels[0]
        stanceValueLabel = valueLabels[1]
        attitudeValueLabel = valueLabels[2]

        // Auto mode toggle (右端に小さく)
        autoModeToggle = NSButton(checkboxWithTitle: "自動", target: self, action: #selector(autoModeToggled(_:)))
        autoModeToggle.translatesAutoresizingMaskIntoConstraints = false
        autoModeToggle.font = NSFont.systemFont(ofSize: 9)
        autoModeToggle.contentTintColor = valueColor
        autoModeToggle.state = currentPersonality.autoMode ? .on : .off
        sliderContainer.addSubview(autoModeToggle)

        // 3カラムの横並びレイアウト
        let col0 = columns[0], col1 = columns[1], col2 = columns[2]

        NSLayoutConstraint.activate([
            col0.topAnchor.constraint(equalTo: sliderContainer.topAnchor),
            col0.bottomAnchor.constraint(equalTo: sliderContainer.bottomAnchor),
            col0.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 2),

            col1.topAnchor.constraint(equalTo: sliderContainer.topAnchor),
            col1.bottomAnchor.constraint(equalTo: sliderContainer.bottomAnchor),
            col1.leadingAnchor.constraint(equalTo: col0.trailingAnchor, constant: 2),
            col1.widthAnchor.constraint(equalTo: col0.widthAnchor),

            col2.topAnchor.constraint(equalTo: sliderContainer.topAnchor),
            col2.bottomAnchor.constraint(equalTo: sliderContainer.bottomAnchor),
            col2.leadingAnchor.constraint(equalTo: col1.trailingAnchor, constant: 2),
            col2.widthAnchor.constraint(equalTo: col0.widthAnchor),
            col2.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -28),

            autoModeToggle.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -4),
            autoModeToggle.topAnchor.constraint(equalTo: sliderContainer.topAnchor, constant: 4),
        ])

        updateSliderEnabled()
    }

    private func updateSliderEnabled() {
        let isManual = !currentPersonality.autoMode
        let alpha: CGFloat = isManual ? 1.0 : 0.5
        frequencySlider.isEnabled = isManual
        stanceSlider.isEnabled = isManual
        attitudeSlider.isEnabled = isManual
        frequencySlider.alphaValue = alpha
        stanceSlider.alphaValue = alpha
        attitudeSlider.alphaValue = alpha
    }

    @objc private func frequencySliderChanged(_ sender: NSSlider) {
        currentPersonality.responseFrequency = Float(sender.doubleValue)
        frequencyValueLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
        notifyPersonalityChanged()
    }

    @objc private func stanceSliderChanged(_ sender: NSSlider) {
        currentPersonality.dialogueStance = Float(sender.doubleValue)
        stanceValueLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
        notifyPersonalityChanged()
    }

    @objc private func attitudeSliderChanged(_ sender: NSSlider) {
        currentPersonality.attitude = Float(sender.doubleValue)
        attitudeValueLabel.stringValue = String(format: "%.0f%%", sender.doubleValue * 100)
        notifyPersonalityChanged()
    }

    @objc private func autoModeToggled(_ sender: NSButton) {
        currentPersonality.autoMode = sender.state == .on
        updateSliderEnabled()
        notifyPersonalityChanged()
    }

    private func notifyPersonalityChanged() {
        currentPersonality.save()
        onPersonalityChanged?(currentPersonality)
    }

    /// 外部からパーソナリティを更新（自動モード時の表示反映用）
    func updatePersonalityDisplay(_ personality: YUiPersonality) {
        currentPersonality = personality
        frequencySlider?.doubleValue = Double(personality.responseFrequency)
        stanceSlider?.doubleValue = Double(personality.dialogueStance)
        attitudeSlider?.doubleValue = Double(personality.attitude)
        autoModeToggle?.state = personality.autoMode ? .on : .off
        frequencyValueLabel?.stringValue = String(format: "%.0f%%", personality.responseFrequency * 100)
        stanceValueLabel?.stringValue = String(format: "%.0f%%", personality.dialogueStance * 100)
        attitudeValueLabel?.stringValue = String(format: "%.0f%%", personality.attitude * 100)
        updateSliderEnabled()
    }

    // MARK: - Bookmark Persistence

    private func loadBookmarks() {
        if let saved = AppDefaults.suite.array(forKey: bookmarksDefaultsKey) as? [String] {
            bookmarkedIDs = Set(saved)
        }
    }

    private func saveBookmarks() {
        AppDefaults.suite.set(Array(bookmarkedIDs), forKey: bookmarksDefaultsKey)
    }

    // MARK: - Add / Update Entries

    func addEntry(_ text: String, isYUi: Bool = false) {
        guard let storage = textView?.textStorage else { return }

        entryCount += 1

        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let time = fmt.string(from: now)

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

        // Determine speaker name for stats
        let speakerName: String? = extractSpeaker(from: text, isYUi: isYUi)

        let entry = LogEntry(timestamp: now, text: text, isYUi: isYUi, speaker: speakerName, attributedString: line)
        allEntries.append(entry)

        // Update stats
        let displaySpeaker = speakerName ?? (isYUi ? "YUi" : "システム")
        speakerCounts[displaySpeaker, default: 0] += 1
        updateStatsLabel()

        if shouldShow(entry: entry) {
            let displayLine = buildDisplayLine(for: entry)
            storage.append(displayLine)
            textView.scrollToEndOfDocument(nil)
        }

        window?.title = "GravityReader ログ (\(entryCount))"
    }

    private func extractSpeaker(from text: String, isYUi: Bool) -> String? {
        if isYUi { return "YUi" }
        // Try to extract "speaker: text" pattern after emoji
        // Pattern: 🗣 SpeakerName: ...
        if text.hasPrefix("\u{1F5E3} ") || text.hasPrefix("\u{1F5E3}") {
            let stripped = text.drop(while: { $0 == "\u{1F5E3}" || $0 == " " })
            if let colonIdx = stripped.firstIndex(of: ":") {
                let name = String(stripped[stripped.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
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
            string: "\u{1F5E3} " + text + "\n",
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
                string: "\u{1F5E3} \(speaker): \(text)\n",
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

            // Also record in allEntries for search/filter/stats
            let now = Date()
            let entryText = "\u{1F5E3} \(speaker): \(text)"
            let entry = LogEntry(timestamp: now, text: entryText, isYUi: false, speaker: speaker, attributedString: line)
            allEntries.append(entry)
            speakerCounts[speaker, default: 0] += 1
            updateStatsLabel()

            window?.title = "GravityReader ログ (\(entryCount))"
        } else {
            // パーシャル行がない場合は通常の確定行を追加
            addEntry("\u{1F5E3} \(speaker): \(text)")
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
        let prefix = running ? "\u{1F50A}" : "\u{23F8}"
        window?.title = "\(prefix) GravityReader ログ (\(entryCount))"
    }

    @objc private func clearLog() {
        textView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        entryCount = 0
        allEntries.removeAll()
        speakerCounts.removeAll()
        sessionStart = Date()
        updateStatsLabel()
        window?.title = "GravityReader ログ"
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Search / Filter

    @objc private func searchChanged() {
        applyFilter()
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Real-time search as user types
        applyFilter()
    }

    private func applyFilter() {
        guard let storage = textView?.textStorage else { return }

        let query = searchField.stringValue.lowercased()
        let selectedFilter = filterPopup.titleOfSelectedItem ?? "全て"
        let category: LogCategory? = {
            switch selectedFilter {
            case "YUi": return .yui
            case "ユーザー": return .user
            case "システム": return .system
            default: return nil
            }
        }()

        let hasFilter = !query.isEmpty || category != nil || showBookmarksOnly
        isFiltering = hasFilter

        // Rebuild text view from allEntries
        let result = NSMutableAttributedString()
        for entry in allEntries {
            if shouldShow(entry: entry, query: query, category: category) {
                result.append(buildDisplayLine(for: entry))
            }
        }

        storage.setAttributedString(result)

        // Partial entries are appended back if not filtering
        if !hasFilter {
            // Re-append any active partial lines
            // (They operate on raw storage, so after a refilter they are lost.
            //  We clear them to keep things consistent.)
            partialLineRanges.removeAll()
        }

        textView.scrollToEndOfDocument(nil)
    }

    private func shouldShow(entry: LogEntry, query: String? = nil, category: LogCategory? = nil) -> Bool {
        let q = query ?? searchField.stringValue.lowercased()
        let cat: LogCategory? = category ?? {
            switch filterPopup.titleOfSelectedItem ?? "全て" {
            case "YUi": return .yui
            case "ユーザー": return .user
            case "システム": return .system
            default: return nil
            }
        }()
        let hasFilter = !q.isEmpty || cat != nil || showBookmarksOnly

        if !hasFilter { return true }

        // Bookmark filter
        if showBookmarksOnly && !bookmarkedIDs.contains(entry.id.uuidString) {
            return false
        }

        // Category filter
        if let c = cat, entry.category != c {
            return false
        }

        // Text search
        if !q.isEmpty && !entry.text.lowercased().contains(q) {
            return false
        }

        return true
    }

    /// Build a display attributed string for an entry, with bookmark marker if needed
    private func buildDisplayLine(for entry: LogEntry) -> NSAttributedString {
        let isBookmarked = bookmarkedIDs.contains(entry.id.uuidString)
        if isBookmarked {
            let result = NSMutableAttributedString()
            // Add a colored left-border marker
            result.append(NSAttributedString(
                string: "\u{2503} ",
                attributes: [
                    .foregroundColor: NSColor(red: 0.95, green: 0.7, blue: 0.2, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            ))
            result.append(entry.attributedString)
            return result
        }
        return entry.attributedString
    }

    // MARK: - Bookmark Toggle (context menu)

    @objc private func toggleBookmarkView() {
        showBookmarksOnly.toggle()
        if showBookmarksOnly {
            bookmarkToggleButton.title = "\u{1F516}\u{2713}"
            bookmarkToggleButton.toolTip = "全て表示に戻す"
        } else {
            bookmarkToggleButton.title = "\u{1F516}"
            bookmarkToggleButton.toolTip = "ブックマーク一覧"
        }
        applyFilter()
    }

    // MARK: - Context Menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Standard items
        menu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())

        // Find which entry the click is on
        if let windowPoint = window?.convertPoint(fromScreen: NSEvent.mouseLocation) {
            let viewPoint = textView.convert(windowPoint, from: nil)
            let charIndex = textView.characterIndexForInsertion(at: viewPoint)
            if let entry = entryAtCharacterIndex(charIndex) {
                let isBookmarked = bookmarkedIDs.contains(entry.id.uuidString)
                let title = isBookmarked ? "\u{1F516} ブックマーク解除" : "\u{1F516} ブックマーク"
                let item = NSMenuItem(title: title, action: #selector(toggleBookmarkForClickedEntry(_:)), keyEquivalent: "")
                item.representedObject = entry.id.uuidString
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "ログをクリア", action: #selector(clearLog), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    /// Find the LogEntry corresponding to a character index in the current display
    private func entryAtCharacterIndex(_ charIndex: Int) -> LogEntry? {
        guard charIndex >= 0 else { return nil }
        var offset = 0
        for entry in allEntries {
            guard shouldShow(entry: entry) else { continue }
            let line = buildDisplayLine(for: entry)
            let len = line.length
            if charIndex >= offset && charIndex < offset + len {
                return entry
            }
            offset += len
        }
        return nil
    }

    @objc private func toggleBookmarkForClickedEntry(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String else { return }
        if bookmarkedIDs.contains(idString) {
            bookmarkedIDs.remove(idString)
        } else {
            bookmarkedIDs.insert(idString)
        }
        saveBookmarks()
        applyFilter()
    }

    // MARK: - Statistics Panel

    @objc private func toggleStats() {
        statsVisible.toggle()
        statsContainer.isHidden = !statsVisible
        updateScrollViewBottomConstraint()
        if statsVisible {
            updateStatsLabel()
        }
    }

    private func updateStatsLabel() {
        guard statsVisible || true else { return }  // always compute, show when visible

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let startTime = fmt.string(from: sessionStart)

        var lines = "セッション開始: \(startTime) | 総発言数: \(entryCount)\n"

        let sortedSpeakers = speakerCounts.sorted { $0.value > $1.value }
        let speakerParts = sortedSpeakers.map { "\($0.key): \($0.value)" }
        if !speakerParts.isEmpty {
            lines += speakerParts.joined(separator: "  ")
        }

        statsLabel.stringValue = lines
    }
}
