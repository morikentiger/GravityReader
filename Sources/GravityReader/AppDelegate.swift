import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var captureManager: GravityCaptureManager?
    private var logWindowController: LogWindowController?
    private var yuiManager: YUiManager?
    private var voiceManager: VoiceTranscriptionManager?
    private var audioLevelMonitor: AudioLevelMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        logWindowController = LogWindowController()
        statusBarController = StatusBarController()
        captureManager = GravityCaptureManager(statusBar: statusBarController!)
        captureManager?.logWindow = logWindowController

        yuiManager = YUiManager()
        yuiManager?.onResponse = { [weak self] response, targetUser, likability in
            self?.logWindowController?.addEntry("🤖 YUi: \(response)", isYUi: true)
            // 好感度に応じてYUiの声スタイルを変える
            self?.speakAsYUi(response, likability: likability)
        }
        yuiManager?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        yuiManager?.onAizuchi = { [weak self] aizuchi in
            self?.logWindowController?.addEntry("🤖 YUi: \(aizuchi)", isYUi: true)
            self?.captureManager?.speakText(aizuchi)
        }
        // 音声レベル監視（GRAVITYの音声出力を監視）
        audioLevelMonitor = AudioLevelMonitor()
        audioLevelMonitor?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }

        // 誰かが喋っている or TTS読み上げ中 → YUiは黙る
        yuiManager?.isSpeakingChecker = { [weak self] in
            let ttsSpeaking = self?.captureManager?.speechManager.isSpeaking ?? false
            let someoneSpeaking = self?.audioLevelMonitor?.isSomeoneSpeaking ?? false
            return ttsSpeaking || someoneSpeaking
        }
        captureManager?.yuiManager = yuiManager

        // 音声文字起こし（スペースキー長押し）
        voiceManager = VoiceTranscriptionManager()
        voiceManager?.onTranscription = { [weak self] text in
            let entry = "🎤 もりけん: \(text)"
            self?.logWindowController?.addEntry(entry, isYUi: false)
            // もりけんは音声で喋ってるので読み上げ不要
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
                self?.yuiManager?.startIdleMonitoring()
                self?.audioLevelMonitor?.start()
            } else {
                self?.captureManager?.stop()
                self?.yuiManager?.stopIdleMonitoring()
                self?.audioLevelMonitor?.stop()
            }
        }

        statusBarController?.onTest = { [weak self] in
            self?.captureManager?.speakTest()
        }

        statusBarController?.onDumpAXTree = { [weak self] in
            self?.captureManager?.dumpAXTree()
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

        statusBarController?.onModelToggle = { [weak self] in
            guard let self = self, let yui = self.yuiManager else { return false }
            let newVal = !yui.isUsingMinModel
            yui.setUseMinModel(newVal)
            let msg = newVal ? "🧠 モデル: gpt-4o-mini（節約モード）" : "🧠 モデル: gpt-4o（高品質）"
            self.logWindowController?.addEntry(msg)
            return newVal
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

    /// 好感度に応じたYUiの声スタイルで読み上げ
    private func speakAsYUi(_ text: String, likability: Int) {
        guard let sm = captureManager?.speechManager else { return }

        // VOICEVOXのスタイルを好感度で選ぶ
        // 好感度が高い → 明るい・嬉しそうな声、低い → 落ち着いた・クールな声
        let speakers = sm.cachedSpeakers
        guard !speakers.isEmpty else {
            sm.speak(text)
            return
        }

        // YUi用のキャラクター名（四国めたんをベースに、スタイルを変える）
        let yuiCharacter = "四国めたん"
        let yuiStyles = speakers.filter { $0.name == yuiCharacter }

        if !yuiStyles.isEmpty {
            let style: String
            switch likability {
            case 75...:  style = "あまあま"    // 好感度高い → 甘い声
            case 55..<75: style = "ノーマル"   // 普通
            case 35..<55: style = "ツンツン"   // 微妙 → ツンツン
            default:      style = "セクシー"   // 低い → クール
            }

            if let matched = yuiStyles.first(where: { $0.style == style }) {
                sm.speak(text, withVoice: .voicevox(matched.id))
                return
            }
            // スタイルが見つからなければノーマル
            if let normal = yuiStyles.first {
                sm.speak(text, withVoice: .voicevox(normal.id))
                return
            }
        }

        // 四国めたんがなければデフォルト
        sm.speak(text)
    }

    func applicationWillTerminate(_ notification: Notification) {
        yuiManager?.flushAllMemory()
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            statusBarController?.setStatus("⚠️ アクセシビリティ許可が必要")
        }
    }
}
