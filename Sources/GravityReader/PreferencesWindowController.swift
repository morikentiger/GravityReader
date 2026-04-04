import AppKit

// MARK: - UserDefaults Keys (centralised reference)

/// All UserDefaults keys used by GravityReader preferences.
/// Existing keys are kept identical so the rest of the app continues to work.
enum PrefKey {
    // API
    static let openAIAPIKey    = "YUiOpenAIAPIKey"
    static let useMinModel     = "YUiUseMinModel"
    // YUi
    static let frequency       = "YUiFrequency"
    static let lonelinessEnabled = "YUiLonelinessEnabled"
    static let aizuchiEnabled  = "YUiAizuchiEnabled"
    static let memoryDuration  = "YUiMemoryDuration"
    // Voice
    static let voiceMode       = "GR_VoiceMode"
    static let voicevoxURL     = "GR_VoicevoxURL"
    static let speechRate      = "GR_SpeechRate"
    // Notification filter
    static let notificationRules = "GR_NotificationRules"
}

// MARK: - Notification Filter Rule

struct NotificationRule: Codable {
    var keyword: String
    var isUser: Bool   // true = user rule, false = keyword rule
    var enabled: Bool
}

// MARK: - PreferencesWindowController

class PreferencesWindowController: NSWindowController, NSTabViewDelegate {

    // MARK: Callbacks – the owner (AppDelegate) can hook these to propagate changes
    var onAPIKeyChanged: ((String) -> Void)?
    var onModelChanged: ((Bool) -> Void)?     // true = mini
    var onFrequencyChanged: ((YUiFrequency) -> Void)?
    var onVoicevoxURLChanged: ((String) -> Void)?
    var onSpeechRateChanged: ((Float) -> Void)?
    var onReadingDictChanged: (([String: String]) -> Void)?

    // MARK: - Controls (kept as ivars for action wiring)

    // API tab
    private var apiKeyField: NSSecureTextField!
    private var apiKeyStatusLabel: NSTextField!
    private var modelGPT4oButton: NSButton!
    private var modelMiniButton: NSButton!

    // YUi tab
    private var frequencySegmented: NSSegmentedControl!
    private var lonelinessToggle: NSSwitch!
    private var aizuchiToggle: NSSwitch!
    private var memoryPopup: NSPopUpButton!

    // Voice tab
    private var voicevoxURLField: NSTextField!
    private var speechRateSlider: NSSlider!
    private var speechRateLabel: NSTextField!

    // Notification tab
    private var rulesTableView: NSTableView!
    private var notificationRules: [NotificationRule] = []

    // Reading dictionary tab
    private var dictTableView: NSTableView!
    private var dictEntries: [(word: String, reading: String)] = []
    private let dictDefaultsKey = "GR_ReadingDictionary"

    // ────────────────────────────────────────────

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GravityReader 設定"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        // Dark appearance
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.15, alpha: 1)

        self.init(window: window)

        let tabView = NSTabView(frame: window.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self

        tabView.addTabViewItem(makeAPITab())
        tabView.addTabViewItem(makeYUiTab())
        tabView.addTabViewItem(makeVoiceTab())
        tabView.addTabViewItem(makeNotificationTab())
        tabView.addTabViewItem(makeDictionaryTab())

        window.contentView!.addSubview(tabView)

        loadNotificationRules()
        loadDictEntries()
    }

    // MARK: - Tab Builders

    private func makeAPITab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "api")
        item.label = "API設定"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // --- API Key ---
        let keyLabel = makeLabel("OpenAI API Key:", frame: NSRect(x: 20, y: 270, width: 200, height: 20))
        view.addSubview(keyLabel)

        apiKeyField = NSSecureTextField(frame: NSRect(x: 20, y: 238, width: 380, height: 24))
        apiKeyField.placeholderString = "sk-..."
        apiKeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged(_:))
        let currentKey = KeychainHelper.load(key: PrefKey.openAIAPIKey) ?? ""
        if !currentKey.isEmpty { apiKeyField.stringValue = currentKey }
        view.addSubview(apiKeyField)

        let saveKeyBtn = NSButton(title: "保存", target: self, action: #selector(saveAPIKey(_:)))
        saveKeyBtn.frame = NSRect(x: 410, y: 236, width: 50, height: 28)
        saveKeyBtn.bezelStyle = .rounded
        view.addSubview(saveKeyBtn)

        apiKeyStatusLabel = makeLabel("", frame: NSRect(x: 20, y: 210, width: 440, height: 18))
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        updateAPIKeyStatus()
        view.addSubview(apiKeyStatusLabel)

        // --- Model Selection ---
        let modelLabel = makeLabel("モデル選択:", frame: NSRect(x: 20, y: 170, width: 200, height: 20))
        view.addSubview(modelLabel)

        let isMin = AppDefaults.suite.bool(forKey: PrefKey.useMinModel)

        modelGPT4oButton = NSButton(radioButtonWithTitle: "gpt-4o（高品質）", target: self, action: #selector(modelSelected(_:)))
        modelGPT4oButton.frame = NSRect(x: 30, y: 142, width: 200, height: 20)
        modelGPT4oButton.tag = 0
        modelGPT4oButton.state = isMin ? .off : .on
        view.addSubview(modelGPT4oButton)

        modelMiniButton = NSButton(radioButtonWithTitle: "gpt-4o-mini（節約）", target: self, action: #selector(modelSelected(_:)))
        modelMiniButton.frame = NSRect(x: 30, y: 116, width: 200, height: 20)
        modelMiniButton.tag = 1
        modelMiniButton.state = isMin ? .on : .off
        view.addSubview(modelMiniButton)

        item.view = view
        return item
    }

    private func makeYUiTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "yui")
        item.label = "YUi設定"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // --- 応答頻度 ---
        let freqLabel = makeLabel("応答頻度:", frame: NSRect(x: 20, y: 280, width: 100, height: 20))
        view.addSubview(freqLabel)

        frequencySegmented = NSSegmentedControl(labels: ["高（20秒）", "中（1分）", "低（3分）"], trackingMode: .selectOne, target: self, action: #selector(frequencyChanged(_:)))
        frequencySegmented.frame = NSRect(x: 130, y: 278, width: 320, height: 24)
        let savedFreq = YUiFrequency(rawValue: AppDefaults.suite.string(forKey: PrefKey.frequency) ?? "") ?? .high
        switch savedFreq {
        case .high:   frequencySegmented.selectedSegment = 0
        case .medium: frequencySegmented.selectedSegment = 1
        case .low:    frequencySegmented.selectedSegment = 2
        }
        view.addSubview(frequencySegmented)

        // --- 孤独感システム ---
        let loneLabel = makeLabel("孤独感システム:", frame: NSRect(x: 20, y: 230, width: 130, height: 20))
        view.addSubview(loneLabel)

        lonelinessToggle = NSSwitch(frame: NSRect(x: 160, y: 228, width: 40, height: 24))
        let loneEnabled = AppDefaults.suite.object(forKey: PrefKey.lonelinessEnabled) as? Bool ?? true
        lonelinessToggle.state = loneEnabled ? .on : .off
        lonelinessToggle.target = self
        lonelinessToggle.action = #selector(lonelinessToggled(_:))
        view.addSubview(lonelinessToggle)

        let loneDesc = makeLabel("YUiが無視されると不安になる演出", frame: NSRect(x: 210, y: 230, width: 260, height: 18))
        loneDesc.font = .systemFont(ofSize: 11)
        loneDesc.textColor = .secondaryLabelColor
        view.addSubview(loneDesc)

        // --- 相槌 ---
        let aizuchiLabel = makeLabel("相槌:", frame: NSRect(x: 20, y: 185, width: 130, height: 20))
        view.addSubview(aizuchiLabel)

        aizuchiToggle = NSSwitch(frame: NSRect(x: 160, y: 183, width: 40, height: 24))
        let aizuchiEnabled = AppDefaults.suite.object(forKey: PrefKey.aizuchiEnabled) as? Bool ?? true
        aizuchiToggle.state = aizuchiEnabled ? .on : .off
        aizuchiToggle.target = self
        aizuchiToggle.action = #selector(aizuchiToggled(_:))
        view.addSubview(aizuchiToggle)

        let aizuchiDesc = makeLabel("会話中に短い相槌を自動で打つ", frame: NSRect(x: 210, y: 185, width: 260, height: 18))
        aizuchiDesc.font = .systemFont(ofSize: 11)
        aizuchiDesc.textColor = .secondaryLabelColor
        view.addSubview(aizuchiDesc)

        // --- 記憶保持期間 ---
        let memLabel = makeLabel("記憶保持期間:", frame: NSRect(x: 20, y: 140, width: 130, height: 20))
        view.addSubview(memLabel)

        memoryPopup = NSPopUpButton(frame: NSRect(x: 160, y: 137, width: 160, height: 26), pullsDown: false)
        memoryPopup.addItems(withTitles: ["30分", "1時間", "2時間"])
        let savedMem = AppDefaults.suite.integer(forKey: PrefKey.memoryDuration)
        switch savedMem {
        case 3600:  memoryPopup.selectItem(at: 1)
        case 7200:  memoryPopup.selectItem(at: 2)
        default:    memoryPopup.selectItem(at: 0)  // 30min default
        }
        memoryPopup.target = self
        memoryPopup.action = #selector(memoryDurationChanged(_:))
        view.addSubview(memoryPopup)

        item.view = view
        return item
    }

    private func makeVoiceTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "voice")
        item.label = "音声設定"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // --- デフォルト音声 info ---
        let voiceInfo = makeLabel("デフォルト音声はメニューバーから変更してください。", frame: NSRect(x: 20, y: 280, width: 440, height: 20))
        voiceInfo.font = .systemFont(ofSize: 12)
        voiceInfo.textColor = .secondaryLabelColor
        view.addSubview(voiceInfo)

        // --- VOICEVOX URL ---
        let urlLabel = makeLabel("VOICEVOX URL:", frame: NSRect(x: 20, y: 240, width: 140, height: 20))
        view.addSubview(urlLabel)

        voicevoxURLField = NSTextField(frame: NSRect(x: 160, y: 238, width: 280, height: 24))
        let savedURL = AppDefaults.suite.string(forKey: PrefKey.voicevoxURL) ?? "http://127.0.0.1:50021"
        voicevoxURLField.stringValue = savedURL
        voicevoxURLField.placeholderString = "http://127.0.0.1:50021"
        voicevoxURLField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        voicevoxURLField.target = self
        voicevoxURLField.action = #selector(voicevoxURLChanged(_:))
        view.addSubview(voicevoxURLField)

        // --- 読み上げ速度 ---
        let rateLabel = makeLabel("読み上げ速度:", frame: NSRect(x: 20, y: 190, width: 130, height: 20))
        view.addSubview(rateLabel)

        let savedRate = AppDefaults.suite.float(forKey: PrefKey.speechRate)
        let rate: Float = savedRate > 0 ? savedRate : 0.52  // default = 0.52

        speechRateSlider = NSSlider(value: Double(rate), minValue: 0.3, maxValue: 0.7, target: self, action: #selector(speechRateChanged(_:)))
        speechRateSlider.frame = NSRect(x: 160, y: 190, width: 220, height: 20)
        speechRateSlider.isContinuous = true
        view.addSubview(speechRateSlider)

        speechRateLabel = makeLabel(String(format: "%.2f", rate), frame: NSRect(x: 390, y: 190, width: 60, height: 20))
        speechRateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.addSubview(speechRateLabel)

        let slowLabel = makeLabel("遅い", frame: NSRect(x: 160, y: 170, width: 40, height: 16))
        slowLabel.font = .systemFont(ofSize: 10)
        slowLabel.textColor = .tertiaryLabelColor
        view.addSubview(slowLabel)

        let fastLabel = makeLabel("速い", frame: NSRect(x: 350, y: 170, width: 40, height: 16))
        fastLabel.font = .systemFont(ofSize: 10)
        fastLabel.textColor = .tertiaryLabelColor
        fastLabel.alignment = .right
        view.addSubview(fastLabel)

        item.view = view
        return item
    }

    private func makeNotificationTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "notification")
        item.label = "通知設定"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        let header = makeLabel("通知フィルタルール（キーワード / ユーザー名）", frame: NSRect(x: 20, y: 300, width: 440, height: 20))
        view.addSubview(header)

        // ScrollView + TableView
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 440, height: 235))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        rulesTableView = NSTableView()
        rulesTableView.rowHeight = 22
        rulesTableView.usesAlternatingRowBackgroundColors = true
        rulesTableView.gridStyleMask = .solidHorizontalGridLineMask
        rulesTableView.dataSource = self
        rulesTableView.delegate = self

        let enabledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledCol.title = "有効"
        enabledCol.width = 40
        enabledCol.minWidth = 40
        enabledCol.maxWidth = 50
        rulesTableView.addTableColumn(enabledCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "種別"
        typeCol.width = 80
        typeCol.minWidth = 60
        rulesTableView.addTableColumn(typeCol)

        let keywordCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword"))
        keywordCol.title = "キーワード / ユーザー名"
        keywordCol.width = 280
        keywordCol.minWidth = 100
        rulesTableView.addTableColumn(keywordCol)

        scrollView.documentView = rulesTableView
        view.addSubview(scrollView)

        // Buttons
        let addBtn = NSButton(title: "＋ 追加", target: self, action: #selector(addRule(_:)))
        addBtn.frame = NSRect(x: 20, y: 22, width: 80, height: 28)
        addBtn.bezelStyle = .rounded
        view.addSubview(addBtn)

        let removeBtn = NSButton(title: "－ 削除", target: self, action: #selector(removeRule(_:)))
        removeBtn.frame = NSRect(x: 110, y: 22, width: 80, height: 28)
        removeBtn.bezelStyle = .rounded
        view.addSubview(removeBtn)

        item.view = view
        return item
    }

    private func makeDictionaryTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "dictionary")
        item.label = "読み辞書"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        let header = makeLabel("読み間違いを修正する辞書（表記 → 読み）", frame: NSRect(x: 20, y: 300, width: 440, height: 20))
        view.addSubview(header)

        // ScrollView + TableView
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 440, height: 235))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        dictTableView = NSTableView()
        dictTableView.rowHeight = 22
        dictTableView.usesAlternatingRowBackgroundColors = true
        dictTableView.gridStyleMask = .solidHorizontalGridLineMask
        dictTableView.dataSource = self
        dictTableView.delegate = self

        let wordCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        wordCol.title = "表記"
        wordCol.width = 180
        wordCol.minWidth = 80
        dictTableView.addTableColumn(wordCol)

        let readingCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reading"))
        readingCol.title = "読み"
        readingCol.width = 220
        readingCol.minWidth = 80
        dictTableView.addTableColumn(readingCol)

        scrollView.documentView = dictTableView
        view.addSubview(scrollView)

        // Buttons
        let addBtn = NSButton(title: "＋ 追加", target: self, action: #selector(addDictEntry(_:)))
        addBtn.frame = NSRect(x: 20, y: 22, width: 80, height: 28)
        addBtn.bezelStyle = .rounded
        view.addSubview(addBtn)

        let removeBtn = NSButton(title: "－ 削除", target: self, action: #selector(removeDictEntry(_:)))
        removeBtn.frame = NSRect(x: 110, y: 22, width: 80, height: 28)
        removeBtn.bezelStyle = .rounded
        view.addSubview(removeBtn)

        item.view = view
        return item
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13)
        return label
    }

    private func updateAPIKeyStatus() {
        let key = KeychainHelper.load(key: PrefKey.openAIAPIKey) ?? ""
        if key.isEmpty {
            apiKeyStatusLabel.stringValue = "状態: 未設定"
            apiKeyStatusLabel.textColor = NSColor.systemOrange
        } else {
            let masked = String(key.prefix(7)) + "..." + String(key.suffix(4))
            apiKeyStatusLabel.stringValue = "状態: 設定済み (\(masked))"
            apiKeyStatusLabel.textColor = NSColor.systemGreen
        }
    }

    // MARK: - Actions: API Tab

    @objc private func apiKeyChanged(_ sender: NSSecureTextField) {
        // Enter key in field also saves
        saveAPIKey(sender)
    }

    @objc private func saveAPIKey(_ sender: Any) {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _ = KeychainHelper.save(key: PrefKey.openAIAPIKey, value: key)
        updateAPIKeyStatus()
        onAPIKeyChanged?(key)
    }

    @objc private func modelSelected(_ sender: NSButton) {
        let useMini = sender.tag == 1
        // Keep radio buttons in sync
        modelGPT4oButton.state = useMini ? .off : .on
        modelMiniButton.state = useMini ? .on : .off
        AppDefaults.suite.set(useMini, forKey: PrefKey.useMinModel)
        onModelChanged?(useMini)
    }

    // MARK: - Actions: YUi Tab

    @objc private func frequencyChanged(_ sender: NSSegmentedControl) {
        let freq: YUiFrequency
        switch sender.selectedSegment {
        case 0: freq = .high
        case 1: freq = .medium
        case 2: freq = .low
        default: return
        }
        AppDefaults.suite.set(freq.rawValue, forKey: PrefKey.frequency)
        onFrequencyChanged?(freq)
    }

    @objc private func lonelinessToggled(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        AppDefaults.suite.set(enabled, forKey: PrefKey.lonelinessEnabled)
    }

    @objc private func aizuchiToggled(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        AppDefaults.suite.set(enabled, forKey: PrefKey.aizuchiEnabled)
    }

    @objc private func memoryDurationChanged(_ sender: NSPopUpButton) {
        let seconds: Int
        switch sender.indexOfSelectedItem {
        case 1: seconds = 3600
        case 2: seconds = 7200
        default: seconds = 1800
        }
        AppDefaults.suite.set(seconds, forKey: PrefKey.memoryDuration)
    }

    // MARK: - Actions: Voice Tab

    @objc private func voicevoxURLChanged(_ sender: NSTextField) {
        let url = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppDefaults.suite.set(url, forKey: PrefKey.voicevoxURL)
        onVoicevoxURLChanged?(url)
    }

    @objc private func speechRateChanged(_ sender: NSSlider) {
        let rate = Float(sender.doubleValue)
        speechRateLabel.stringValue = String(format: "%.2f", rate)
        AppDefaults.suite.set(rate, forKey: PrefKey.speechRate)
        onSpeechRateChanged?(rate)
    }

    // MARK: - Actions: Notification Tab

    @objc private func addRule(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "フィルタルールを追加"
        alert.informativeText = "キーワードまたはユーザー名を入力してください:"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))

        let textField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        textField.placeholderString = "キーワードまたはユーザー名"
        accessoryView.addSubview(textField)

        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24), pullsDown: false)
        typePopup.addItems(withTitles: ["キーワード", "ユーザー名"])
        accessoryView.addSubview(typePopup)

        alert.accessoryView = accessoryView
        alert.window.initialFirstResponder = textField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let keyword = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { return }
            let rule = NotificationRule(
                keyword: keyword,
                isUser: typePopup.indexOfSelectedItem == 1,
                enabled: true
            )
            self?.notificationRules.append(rule)
            self?.saveNotificationRules()
            self?.rulesTableView.reloadData()
        }
    }

    @objc private func removeRule(_ sender: Any) {
        let row = rulesTableView.selectedRow
        guard row >= 0, row < notificationRules.count else { return }
        notificationRules.remove(at: row)
        saveNotificationRules()
        rulesTableView.reloadData()
    }

    // MARK: - Notification Rule Persistence

    private func loadNotificationRules() {
        guard let data = AppDefaults.suite.data(forKey: PrefKey.notificationRules) else { return }
        if let decoded = try? JSONDecoder().decode([NotificationRule].self, from: data) {
            notificationRules = decoded
        }
    }

    private func saveNotificationRules() {
        if let data = try? JSONEncoder().encode(notificationRules) {
            AppDefaults.suite.set(data, forKey: PrefKey.notificationRules)
        }
    }

    // MARK: - Actions: Dictionary Tab

    @objc private func addDictEntry(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "読み辞書に登録"
        alert.informativeText = "表記と読みを入力してください:"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))

        let wordField = NSTextField(frame: NSRect(x: 0, y: 32, width: 140, height: 24))
        wordField.placeholderString = "表記（例: 風）"
        accessoryView.addSubview(wordField)

        let arrowLabel = NSTextField(labelWithString: "→")
        arrowLabel.frame = NSRect(x: 148, y: 34, width: 16, height: 20)
        accessoryView.addSubview(arrowLabel)

        let readingField = NSTextField(frame: NSRect(x: 168, y: 32, width: 132, height: 24))
        readingField.placeholderString = "読み（例: かぜ）"
        accessoryView.addSubview(readingField)

        alert.accessoryView = accessoryView
        alert.window.initialFirstResponder = wordField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let word = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let reading = readingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !reading.isEmpty else { return }
            self?.dictEntries.append((word: word, reading: reading))
            self?.saveDictEntries()
            self?.dictTableView.reloadData()
        }
    }

    @objc private func removeDictEntry(_ sender: Any) {
        let row = dictTableView.selectedRow
        guard row >= 0, row < dictEntries.count else { return }
        dictEntries.remove(at: row)
        saveDictEntries()
        dictTableView.reloadData()
    }

    // MARK: - Dictionary Persistence

    private func loadDictEntries() {
        guard let dict = AppDefaults.suite.dictionary(forKey: dictDefaultsKey) as? [String: String] else { return }
        dictEntries = dict.map { (word: $0.key, reading: $0.value) }.sorted { $0.word < $1.word }
    }

    private func saveDictEntries() {
        var dict: [String: String] = [:]
        for entry in dictEntries {
            dict[entry.word] = entry.reading
        }
        AppDefaults.suite.set(dict, forKey: dictDefaultsKey)
        onReadingDictChanged?(dict)
    }

    // MARK: - Show

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === dictTableView {
            return dictEntries.count
        }
        return notificationRules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue else { return nil }

        // 読み辞書テーブル
        if tableView === dictTableView {
            guard row < dictEntries.count else { return nil }
            let entry = dictEntries[row]
            switch colID {
            case "word":
                let label = NSTextField(labelWithString: entry.word)
                label.font = .systemFont(ofSize: 12)
                return label
            case "reading":
                let label = NSTextField(labelWithString: entry.reading)
                label.font = .systemFont(ofSize: 12)
                return label
            default:
                return nil
            }
        }

        // 通知フィルタテーブル
        guard row < notificationRules.count else { return nil }
        let rule = notificationRules[row]

        switch colID {
        case "enabled":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRuleEnabled(_:)))
            checkbox.state = rule.enabled ? .on : .off
            checkbox.tag = row
            return checkbox

        case "type":
            let label = NSTextField(labelWithString: rule.isUser ? "ユーザー" : "キーワード")
            label.font = .systemFont(ofSize: 12)
            return label

        case "keyword":
            let label = NSTextField(labelWithString: rule.keyword)
            label.font = .systemFont(ofSize: 12)
            return label

        default:
            return nil
        }
    }

    @objc private func toggleRuleEnabled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < notificationRules.count else { return }
        notificationRules[row].enabled = sender.state == .on
        saveNotificationRules()
    }
}
