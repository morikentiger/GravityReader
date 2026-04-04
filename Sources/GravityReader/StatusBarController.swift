import AppKit

/// NSMenuItemのrepresentedObject用（ユーザー名+VoiceMode）
class UserVoiceSelection: NSObject {
    let user: String
    let mode: VoiceMode
    init(user: String, mode: VoiceMode) {
        self.user = user
        self.mode = mode
    }
}

class StatusBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var isRunning = false
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var lastReadMenuItem: NSMenuItem!

    var onToggle: ((Bool) -> Void)?
    var onTest: (() -> Void)?
    var onShowLog: (() -> Void)?
    var onDumpAXTree: (() -> Void)?
    var onSetAPIKey: ((String) -> Void)?
    var onVoiceChanged: ((VoiceMode) -> Void)?
    var onFrequencyChanged: ((YUiFrequency) -> Void)?
    var onUserVoiceChanged: ((String, VoiceMode) -> Void)?
    var onModelToggle: (() -> Bool)?  // returns new isMinModel value
    var onStartEnrollment: ((String) -> Void)?  // 指定ユーザー1人の声紋登録
    var onClearAllVoiceProfiles: (() -> Void)?  // 全声紋クリア
    var onShowPreferences: (() -> Void)?
    var onCatchUp: (() -> Void)?
    var onTTSToggle: ((Bool) -> Void)?      // 読み上げオン/オフ
    var onYUiToggle: ((Bool) -> Void)?       // YUiコメントオン/オフ

    private(set) var isTTSEnabled = true
    private(set) var isYUiEnabled = true
    private var ttsToggleMenuItem: NSMenuItem!
    private var yuiToggleMenuItem: NSMenuItem!

    private var voiceSubmenu: NSMenu!
    private var voiceMenuItem: NSMenuItem!
    private var frequencySubmenu: NSMenu!
    private var userVoiceMenuItem: NSMenuItem!
    private var userVoiceSubmenu: NSMenu!
    private var enrollSubmenu: NSMenu!

    /// VOICEVOX スピーカー一覧のキャッシュ
    private var speakersCache: [VoicevoxSpeaker] = []
    /// 現在のユーザー別ボイス割り当て取得用
    var getUserVoice: ((String) -> VoiceMode)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        setupUI()
    }

    private func setupUI() {
        if let button = statusItem.button {
            button.title = "📖"
            button.toolTip = "GravityReader"
        }

        statusMenuItem = NSMenuItem(title: "停止中", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "▶ 開始", action: #selector(toggleReading), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        // 読み上げ / YUiコメント 独立トグル
        ttsToggleMenuItem = NSMenuItem(title: "🔊 読み上げ: ON", action: #selector(toggleTTS), keyEquivalent: "")
        ttsToggleMenuItem.target = self
        menu.addItem(ttsToggleMenuItem)

        yuiToggleMenuItem = NSMenuItem(title: "💬 YUiコメント: ON", action: #selector(toggleYUi), keyEquivalent: "")
        yuiToggleMenuItem.target = self
        menu.addItem(yuiToggleMenuItem)

        menu.addItem(.separator())

        lastReadMenuItem = NSMenuItem(title: "最後に読み上げ: なし", action: nil, keyEquivalent: "")
        lastReadMenuItem.isEnabled = false
        menu.addItem(lastReadMenuItem)

        menu.addItem(.separator())

        let showLogItem = NSMenuItem(title: "📋 ログを表示", action: #selector(showLog), keyEquivalent: "l")
        showLogItem.target = self
        menu.addItem(showLogItem)

        let testItem = NSMenuItem(title: "🔊 テスト読み上げ", action: #selector(testSpeech), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        let dumpItem = NSMenuItem(title: "🔍 AXツリー ダンプ", action: #selector(dumpAXTree), keyEquivalent: "d")
        dumpItem.target = self
        menu.addItem(dumpItem)

        // 声紋登録サブメニュー（参加者一覧から個別に選択）
        enrollSubmenu = NSMenu()
        let noEnrollItem = NSMenuItem(title: "（読み上げ開始後にユーザーが表示されます）", action: nil, keyEquivalent: "")
        noEnrollItem.isEnabled = false
        enrollSubmenu.addItem(noEnrollItem)
        enrollSubmenu.addItem(.separator())
        let manualEnrollItem = NSMenuItem(title: "✏️ 名前を入力して登録...", action: #selector(manualEnrollment), keyEquivalent: "")
        manualEnrollItem.target = self
        enrollSubmenu.addItem(manualEnrollItem)
        enrollSubmenu.addItem(.separator())
        let clearAllItem = NSMenuItem(title: "🗑 全声紋をクリア", action: #selector(clearAllVoiceProfiles), keyEquivalent: "")
        clearAllItem.target = self
        enrollSubmenu.addItem(clearAllItem)
        let enrollMenuItem = NSMenuItem(title: "🎤 声紋登録", action: nil, keyEquivalent: "")
        enrollMenuItem.submenu = enrollSubmenu
        menu.addItem(enrollMenuItem)

        let apiKeyItem = NSMenuItem(title: "🔑 APIキー設定", action: #selector(setAPIKey), keyEquivalent: "k")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        // モデル切替
        let isMin = AppDefaults.suite.bool(forKey: "YUiUseMinModel")
        let modelItem = NSMenuItem(title: isMin ? "✓ gpt-4o-mini（節約）" : "  gpt-4o-mini（節約）", action: #selector(toggleModel), keyEquivalent: "")
        modelItem.target = self
        modelItem.tag = 999
        menu.addItem(modelItem)

        // YUi応答頻度サブメニュー
        frequencySubmenu = NSMenu()
        let currentFreq = YUiFrequency(rawValue: AppDefaults.suite.string(forKey: "YUiFrequency") ?? "") ?? .high
        for freq in YUiFrequency.allCases {
            let prefix = freq == currentFreq ? "✓ " : "  "
            let item = NSMenuItem(title: "\(prefix)\(freq.rawValue)", action: #selector(selectFrequency(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = freq
            frequencySubmenu.addItem(item)
        }
        let freqMenuItem = NSMenuItem(title: "⏱ YUi応答頻度", action: nil, keyEquivalent: "")
        freqMenuItem.submenu = frequencySubmenu
        menu.addItem(freqMenuItem)

        // 音声選択サブメニュー
        voiceSubmenu = NSMenu()
        let systemItem = NSMenuItem(title: "✓ システム音声（デフォルト）", action: #selector(selectSystemVoice), keyEquivalent: "")
        systemItem.target = self
        systemItem.tag = -1
        voiceSubmenu.addItem(systemItem)
        voiceSubmenu.addItem(.separator())
        let voicevoxHeader = NSMenuItem(title: "── VOICEVOX ──", action: nil, keyEquivalent: "")
        voicevoxHeader.isEnabled = false
        voiceSubmenu.addItem(voicevoxHeader)
        let loadingItem = NSMenuItem(title: "接続中...", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        loadingItem.tag = -99
        voiceSubmenu.addItem(loadingItem)

        voiceMenuItem = NSMenuItem(title: "🎤 デフォルト音声", action: nil, keyEquivalent: "")
        voiceMenuItem.submenu = voiceSubmenu
        menu.addItem(voiceMenuItem)

        // ユーザー別音声サブメニュー
        userVoiceSubmenu = NSMenu()
        let noUsersItem = NSMenuItem(title: "（読み上げ開始後にユーザーが表示されます）", action: nil, keyEquivalent: "")
        noUsersItem.isEnabled = false
        noUsersItem.tag = -100
        userVoiceSubmenu.addItem(noUsersItem)
        userVoiceMenuItem = NSMenuItem(title: "👥 ユーザー別音声", action: nil, keyEquivalent: "")
        userVoiceMenuItem.submenu = userVoiceSubmenu
        menu.addItem(userVoiceMenuItem)

        menu.addItem(.separator())

        let catchUpItem = NSMenuItem(title: "📝 会話キャッチアップ", action: #selector(requestCatchUp), keyEquivalent: "")
        catchUpItem.target = self
        menu.addItem(catchUpItem)

        let prefsItem = NSMenuItem(title: "⚙ 設定...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showLog() {
        onShowLog?()
    }

    @objc private func testSpeech() {
        onTest?()
    }

    @objc private func dumpAXTree() {
        onDumpAXTree?()
    }

    @objc private func startEnrollmentForUser(_ sender: NSMenuItem) {
        guard let user = sender.representedObject as? String else { return }
        onStartEnrollment?(user)
    }

    @objc private func clearAllVoiceProfiles() {
        onClearAllVoiceProfiles?()
    }

    @objc private func manualEnrollment() {
        // メニューのトラッキングループ完了後にモーダルを表示（フリーズ防止）
        DispatchQueue.main.async { [weak self] in
            self?.showManualEnrollmentDialog()
        }
    }

    private func showManualEnrollmentDialog() {
        let alert = NSAlert()
        alert.messageText = "声紋登録"
        alert.informativeText = "登録するユーザー名を入力してください:"
        alert.addButton(withTitle: "登録開始")
        alert.addButton(withTitle: "キャンセル")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.placeholderString = "ユーザー名"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                onStartEnrollment?(name)
            }
        }
    }

    @objc private func setAPIKey() {
        // メニューのトラッキングループ完了後にウィンドウを表示（フリーズ防止）
        DispatchQueue.main.async { [weak self] in
            self?.showAPIKeyWindow()
        }
    }

    private func showAPIKeyWindow() {
        // 既に開いている場合は前面に出すだけ
        if let existing = apiKeyWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenAI APIキー設定"
        window.level = .floating
        window.center()

        let contentView = window.contentView!

        let label = NSTextField(labelWithString: "YUiが使用するOpenAI APIキーを入力してください:")
        label.frame = NSRect(x: 20, y: 110, width: 380, height: 20)
        contentView.addSubview(label)

        let input = NSTextField(frame: NSRect(x: 20, y: 70, width: 380, height: 28))
        input.placeholderString = "sk-..."
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let current = KeychainHelper.load(key: "YUiOpenAIAPIKey") ?? ""
        if !current.isEmpty {
            input.stringValue = current
        }
        contentView.addSubview(input)

        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        saveButton.frame = NSRect(x: 310, y: 20, width: 90, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 210, y: 20, width: 90, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        saveButton.target = self
        saveButton.action = #selector(apiKeySave(_:))
        cancelButton.target = self
        cancelButton.action = #selector(apiKeyCancel(_:))

        window.initialFirstResponder = input
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        apiKeyWindow = window
        apiKeyInput = input
    }  // end showAPIKeyWindow

    private var apiKeyWindow: NSWindow?
    private var apiKeyInput: NSTextField?

    @objc private func apiKeySave(_ sender: Any) {
        let key = apiKeyInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        apiKeyWindow?.close()
        apiKeyWindow = nil
        apiKeyInput = nil
        if !key.isEmpty {
            onSetAPIKey?(key)
        }
    }

    @objc private func apiKeyCancel(_ sender: Any) {
        apiKeyWindow?.close()
        apiKeyWindow = nil
        apiKeyInput = nil
    }

    @objc private func showPreferences() {
        onShowPreferences?()
    }

    @objc private func requestCatchUp() {
        onCatchUp?()
    }

    @objc private func toggleReading() {
        isRunning.toggle()
        if isRunning {
            toggleMenuItem.title = "⏹ 停止"
            updateStatusDisplay()
        } else {
            toggleMenuItem.title = "▶ 開始"
            statusMenuItem.title = "停止中"
            statusItem.button?.title = "📖"
        }
        onToggle?(isRunning)
    }

    @objc private func toggleTTS() {
        isTTSEnabled.toggle()
        ttsToggleMenuItem.title = isTTSEnabled ? "🔊 読み上げ: ON" : "🔇 読み上げ: OFF"
        updateStatusDisplay()
        onTTSToggle?(isTTSEnabled)
    }

    @objc private func toggleYUi() {
        isYUiEnabled.toggle()
        yuiToggleMenuItem.title = isYUiEnabled ? "💬 YUiコメント: ON" : "🙊 YUiコメント: OFF"
        updateStatusDisplay()
        onYUiToggle?(isYUiEnabled)
    }

    private func updateStatusDisplay() {
        guard isRunning else { return }
        let ttsIcon = isTTSEnabled ? "🔊" : "🔇"
        let yuiIcon = isYUiEnabled ? "💬" : ""
        statusMenuItem.title = "動作中 \(ttsIcon)\(yuiIcon)"
        statusItem.button?.title = "📖\(ttsIcon)"
    }

    // MARK: - Frequency selection

    @objc private func selectFrequency(_ sender: NSMenuItem) {
        guard let freq = sender.representedObject as? YUiFrequency else { return }
        // チェックマーク更新
        for item in frequencySubmenu.items {
            if let itemFreq = item.representedObject as? YUiFrequency {
                let prefix = itemFreq == freq ? "✓ " : "  "
                item.title = "\(prefix)\(itemFreq.rawValue)"
            }
        }
        onFrequencyChanged?(freq)
    }

    @objc private func toggleModel() {
        guard let newVal = onModelToggle?() else { return }
        // メニュー項目のチェック更新
        if let menu = statusItem.menu {
            for item in menu.items where item.tag == 999 {
                item.title = newVal ? "✓ gpt-4o-mini（節約）" : "  gpt-4o-mini（節約）"
            }
        }
    }

    // MARK: - Voice selection

    @objc private func selectSystemVoice() {
        updateVoiceCheckmark(tag: -1)
        onVoiceChanged?(.system)
    }

    @objc private func selectVoicevoxSpeaker(_ sender: NSMenuItem) {
        let speakerID = sender.tag
        updateVoiceCheckmark(tag: speakerID)
        onVoiceChanged?(.voicevox(speakerID))
    }

    private func updateVoiceCheckmark(tag: Int) {
        for item in voiceSubmenu.items {
            if item.tag == -1 {
                item.title = tag == -1 ? "✓ システム音声（デフォルト）" : "  システム音声（デフォルト）"
            } else if item.tag >= 0 {
                let base = item.representedObject as? String ?? item.title
                item.title = item.tag == tag ? "✓ \(base)" : "  \(base)"
            }
        }
    }

    // MARK: - User voice menu

    /// 登録済み声紋の名前リスト取得用
    var getRegisteredVoiceProfiles: (() -> [String])?

    /// 検出済みユーザー一覧でメニューを更新
    func refreshUserList(_ users: [String]) {
        userVoiceSubmenu.removeAllItems()
        enrollSubmenu.removeAllItems()

        // 手動登録は常に表示
        let manualItem = NSMenuItem(title: "✏️ 名前を入力して登録...", action: #selector(manualEnrollment), keyEquivalent: "")
        manualItem.target = self
        enrollSubmenu.addItem(manualItem)
        enrollSubmenu.addItem(.separator())

        if users.isEmpty {
            let noUsersItem = NSMenuItem(title: "（読み上げ開始後にユーザーが表示されます）", action: nil, keyEquivalent: "")
            noUsersItem.isEnabled = false
            userVoiceSubmenu.addItem(noUsersItem)

            let noEnrollItem = NSMenuItem(title: "（読み上げ開始後にユーザーが表示されます）", action: nil, keyEquivalent: "")
            noEnrollItem.isEnabled = false
            enrollSubmenu.addItem(noEnrollItem)

            enrollSubmenu.addItem(.separator())
            let clearAllItem = NSMenuItem(title: "🗑 全声紋をクリア", action: #selector(clearAllVoiceProfiles), keyEquivalent: "")
            clearAllItem.target = self
            enrollSubmenu.addItem(clearAllItem)
            return
        }

        let registered = Set(getRegisteredVoiceProfiles?() ?? [])

        // もりけん（ホスト）を先頭に追加
        let morickenItem = NSMenuItem(title: "もりけん", action: nil, keyEquivalent: "")
        let morickenSub = buildVoicePickerSubmenu(forUser: "もりけん")
        morickenItem.submenu = morickenSub
        userVoiceSubmenu.addItem(morickenItem)
        userVoiceSubmenu.addItem(.separator())

        // 声紋登録メニュー: もりけん
        let morickenEnroll = NSMenuItem(
            title: registered.contains("もりけん") ? "✅ もりけん（登録済み）" : "🎤 もりけん",
            action: #selector(startEnrollmentForUser(_:)),
            keyEquivalent: ""
        )
        morickenEnroll.target = self
        morickenEnroll.representedObject = "もりけん"
        enrollSubmenu.addItem(morickenEnroll)
        enrollSubmenu.addItem(.separator())

        for user in users {
            // ユーザー別音声
            let currentVoice = getUserVoice?(user) ?? .system
            let voiceLabel = voiceLabelFor(currentVoice)
            let item = NSMenuItem(title: "\(user)  [\(voiceLabel)]", action: nil, keyEquivalent: "")
            let sub = buildVoicePickerSubmenu(forUser: user)
            item.submenu = sub
            userVoiceSubmenu.addItem(item)

            // 声紋登録
            let enrollItem = NSMenuItem(
                title: registered.contains(user) ? "✅ \(user)（登録済み）" : "🎤 \(user)",
                action: #selector(startEnrollmentForUser(_:)),
                keyEquivalent: ""
            )
            enrollItem.target = self
            enrollItem.representedObject = user
            enrollSubmenu.addItem(enrollItem)
        }

        enrollSubmenu.addItem(.separator())
        let clearAllItem = NSMenuItem(title: "🗑 全声紋をクリア", action: #selector(clearAllVoiceProfiles), keyEquivalent: "")
        clearAllItem.target = self
        enrollSubmenu.addItem(clearAllItem)
    }

    private func buildVoicePickerSubmenu(forUser user: String) -> NSMenu {
        let sub = NSMenu()
        let currentVoice = getUserVoice?(user) ?? .system

        // システム音声
        let sysPrefix = currentVoice == .system ? "✓ " : "  "
        let sysItem = NSMenuItem(title: "\(sysPrefix)システム音声", action: #selector(selectUserVoice(_:)), keyEquivalent: "")
        sysItem.target = self
        sysItem.representedObject = UserVoiceSelection(user: user, mode: .system)
        sub.addItem(sysItem)

        sub.addItem(.separator())

        // VOICEVOXスピーカー
        for speaker in speakersCache {
            let label = "\(speaker.name)（\(speaker.style)）"
            let isSelected = currentVoice == .voicevox(speaker.id)
            let prefix = isSelected ? "✓ " : "  "
            let item = NSMenuItem(title: "\(prefix)\(label)", action: #selector(selectUserVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = UserVoiceSelection(user: user, mode: .voicevox(speaker.id))
            sub.addItem(item)
        }

        return sub
    }

    private func voiceLabelFor(_ mode: VoiceMode) -> String {
        switch mode {
        case .system: return "システム"
        case .voicevox(let id):
            if let s = speakersCache.first(where: { $0.id == id }) {
                return "\(s.name)"
            }
            return "VOICEVOX \(id)"
        }
    }

    @objc private func selectUserVoice(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? UserVoiceSelection else { return }
        onUserVoiceChanged?(sel.user, sel.mode)
    }

    // MARK: - VOICEVOX speakers

    func refreshVoicevoxSpeakers(_ speakers: [VoicevoxSpeaker], currentMode: VoiceMode) {
        speakersCache = speakers
        if let loading = voiceSubmenu.items.first(where: { $0.tag == -99 }) {
            voiceSubmenu.removeItem(loading)
        }
        for item in voiceSubmenu.items.reversed() {
            if item.tag >= 0 { voiceSubmenu.removeItem(item) }
        }

        if speakers.isEmpty {
            let noConn = NSMenuItem(title: "未接続（VOICEVOXを起動してください）", action: nil, keyEquivalent: "")
            noConn.isEnabled = false
            noConn.tag = -98
            voiceSubmenu.addItem(noConn)
            return
        }

        if let noConn = voiceSubmenu.items.first(where: { $0.tag == -98 }) {
            voiceSubmenu.removeItem(noConn)
        }

        let currentTag: Int
        if case .voicevox(let id) = currentMode { currentTag = id } else { currentTag = -1 }

        for speaker in speakers {
            let label = "\(speaker.name)（\(speaker.style)）"
            let prefix = speaker.id == currentTag ? "✓ " : "  "
            let item = NSMenuItem(title: "\(prefix)\(label)", action: #selector(selectVoicevoxSpeaker(_:)), keyEquivalent: "")
            item.target = self
            item.tag = speaker.id
            item.representedObject = label
            voiceSubmenu.addItem(item)
        }

        if let sysItem = voiceSubmenu.items.first(where: { $0.tag == -1 }) {
            sysItem.title = currentTag == -1 ? "✓ システム音声（デフォルト）" : "  システム音声（デフォルト）"
        }
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMenuItem.title = text
        }
    }

    func setLastRead(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            let display = text.count > 30 ? String(text.prefix(30)) + "…" : text
            self?.lastReadMenuItem.title = "最後に読み上げ: \(display)"
        }
    }
}
