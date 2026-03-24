import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var captureManager: GravityCaptureManager?
    private var logWindowController: LogWindowController?
    private var yuiManager: YUiManager?
    private var voiceManager: VoiceTranscriptionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        logWindowController = LogWindowController()
        statusBarController = StatusBarController()
        captureManager = GravityCaptureManager(statusBar: statusBarController!)
        captureManager?.logWindow = logWindowController

        yuiManager = YUiManager()
        yuiManager?.onResponse = { [weak self] response in
            self?.logWindowController?.addEntry("🤖 YUi: \(response)", isYUi: true)
            self?.captureManager?.speakText(response)
        }
        yuiManager?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        captureManager?.yuiManager = yuiManager

        // 音声文字起こし（スペースキー長押し）
        voiceManager = VoiceTranscriptionManager()
        voiceManager?.onTranscription = { [weak self] text in
            let entry = "🎤 もりけん: \(text)"
            self?.logWindowController?.addEntry(entry, isYUi: false)
            self?.captureManager?.speechManager.speak(text, forUser: "もりけん")
            self?.yuiManager?.feedMessage("もりけん: \(text)")
        }
        voiceManager?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        voiceManager?.onRecordingStateChanged = { [weak self] recording in
            if recording {
                self?.statusBarController?.setStatus("🎙 録音中...")
            } else {
                self?.statusBarController?.setStatus("動作中 🔊")
            }
        }
        voiceManager?.setup()

        checkAccessibilityPermission()

        statusBarController?.onToggle = { [weak self] isRunning in
            if isRunning {
                self?.captureManager?.start()
            } else {
                self?.captureManager?.stop()
            }
        }

        statusBarController?.onTest = { [weak self] in
            self?.captureManager?.speakTest()
        }

        statusBarController?.onShowLog = { [weak self] in
            self?.logWindowController?.show()
        }

        statusBarController?.onSetAPIKey = { [weak self] key in
            self?.yuiManager?.setAPIKey(key)
            self?.logWindowController?.addEntry("✅ APIキーを設定しました")
        }

        statusBarController?.onVoiceChanged = { [weak self] mode in
            guard let self = self else { return }
            self.captureManager?.speechManager.voiceMode = mode
            switch mode {
            case .system:
                self.logWindowController?.addEntry("🔊 デフォルト音声: システム音声に切り替えました")
            case .voicevox(let id):
                let name = self.captureManager?.speechManager.cachedSpeakers.first(where: { $0.id == id })
                let label = name.map { "\($0.name)（\($0.style)）" } ?? "speaker \(id)"
                self.logWindowController?.addEntry("🔊 デフォルト音声: \(label) に切り替えました")
            }
        }

        statusBarController?.onFrequencyChanged = { [weak self] freq in
            self?.yuiManager?.frequency = freq
            self?.logWindowController?.addEntry("⏱ YUi応答頻度: \(freq.rawValue) に変更しました")
        }

        // ユーザー別音声変更コールバック（メニューから）
        statusBarController?.onUserVoiceChanged = { [weak self] user, mode in
            guard let self = self else { return }
            self.captureManager?.speechManager.setVoiceForUser(user, mode: mode)
            let label: String
            switch mode {
            case .system: label = "システム音声"
            case .voicevox(let id):
                let s = self.captureManager?.speechManager.cachedSpeakers.first(where: { $0.id == id })
                label = s.map { "\($0.name)（\($0.style)）" } ?? "VOICEVOX \(id)"
            }
            self.logWindowController?.addEntry("🎤 \(user) の声を \(label) に変更しました")
            // メニュー再描画
            if let users = self.captureManager?.detectedUsers {
                self.statusBarController?.refreshUserList(users)
            }
        }

        // ユーザーのボイス取得用
        statusBarController?.getUserVoice = { [weak self] user in
            self?.captureManager?.speechManager.voiceForUser(user) ?? .system
        }

        // ユーザー一覧が更新されたらメニューに反映
        captureManager?.onUsersUpdated = { [weak self] users in
            self?.statusBarController?.refreshUserList(users)
        }

        // VOICEVOXスピーカー一覧を取得
        captureManager?.speechManager.fetchVoicevoxSpeakers { [weak self] speakers in
            guard let self = self else { return }
            let currentMode = self.captureManager?.speechManager.voiceMode ?? .system
            self.statusBarController?.refreshVoicevoxSpeakers(speakers, currentMode: currentMode)
        }

        // Editメニュー追加（Cmd+V等を有効にする）
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        // ログウィンドウを起動時に表示
        logWindowController?.show()
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            statusBarController?.setStatus("⚠️ アクセシビリティ許可が必要")
        }
    }
}
