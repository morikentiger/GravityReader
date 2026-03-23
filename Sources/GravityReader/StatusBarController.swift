import AppKit

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
    var onSetAPIKey: ((String) -> Void)?
    var onVoiceChanged: ((VoiceMode) -> Void)?

    private var voiceSubmenu: NSMenu!
    private var voiceMenuItem: NSMenuItem!

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

        toggleMenuItem = NSMenuItem(title: "▶ 読み上げ開始", action: #selector(toggleReading), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

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

        let apiKeyItem = NSMenuItem(title: "🔑 APIキー設定", action: #selector(setAPIKey), keyEquivalent: "k")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

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

        voiceMenuItem = NSMenuItem(title: "🎤 音声選択", action: nil, keyEquivalent: "")
        voiceMenuItem.submenu = voiceSubmenu
        menu.addItem(voiceMenuItem)

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

    @objc private func setAPIKey() {
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
        let current = UserDefaults.standard.string(forKey: "YUiOpenAIAPIKey") ?? ""
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

        // Store reference so window isn't deallocated
        apiKeyWindow = window
        apiKeyInput = input
    }

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

    @objc private func toggleReading() {
        isRunning.toggle()
        if isRunning {
            toggleMenuItem.title = "⏹ 読み上げ停止"
            statusMenuItem.title = "動作中 🔊"
            statusItem.button?.title = "📖🔊"
        } else {
            toggleMenuItem.title = "▶ 読み上げ開始"
            statusMenuItem.title = "停止中"
            statusItem.button?.title = "📖"
        }
        onToggle?(isRunning)
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

    func refreshVoicevoxSpeakers(_ speakers: [VoicevoxSpeaker], currentMode: VoiceMode) {
        // "接続中..." を削除
        if let loading = voiceSubmenu.items.first(where: { $0.tag == -99 }) {
            voiceSubmenu.removeItem(loading)
        }
        // 既存のVOICEVOXアイテムを削除（tag >= 0）
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

        // 既存の未接続メッセージを削除
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

        // システム音声のチェック更新
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
