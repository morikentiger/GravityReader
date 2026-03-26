import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var captureManager: GravityCaptureManager?
    private var logWindowController: LogWindowController?
    private var yuiManager: YUiManager?
    private var voiceManager: VoiceTranscriptionManager?
    private var roomTranscription: RoomTranscriptionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        logWindowController = LogWindowController()
        statusBarController = StatusBarController()
        captureManager = GravityCaptureManager(statusBar: statusBarController!)
        captureManager?.logWindow = logWindowController

        yuiManager = YUiManager()
        yuiManager?.onResponse = { [weak self] response, targetUser, likability in
            self?.logWindowController?.addEntry("🤖 YUi: \(response)", isYUi: true)
            self?.speakAsYUi(response, likability: likability)
        }
        yuiManager?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        yuiManager?.onAizuchi = { [weak self] aizuchi in
            self?.logWindowController?.addEntry("🤖 YUi: \(aizuchi)", isYUi: true)
            self?.captureManager?.speakText(aizuchi)
        }

        // ルーム音声文字起こし（ScreenCaptureKit で GRAVITY の音声を直接キャプチャ）
        roomTranscription = RoomTranscriptionManager()
        roomTranscription?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        // リアルタイム途中結果 → 話者別に並列パーシャルライン更新
        roomTranscription?.onPartialResult = { [weak self] speaker, text in
            self?.logWindowController?.updatePartialEntry("\(speaker): \(text)", speaker: speaker)
        }

        // 話者のパーシャルラインをクリア
        roomTranscription?.onClearPartial = { [weak self] speaker in
            self?.logWindowController?.clearPartialEntry(speaker: speaker)
        }

        // 確定結果 → パーシャル行を白に変換（黄→白演出）+ YUiに送る
        roomTranscription?.onTranscription = { [weak self] speaker, text in
            self?.logWindowController?.confirmPartialEntry(speaker: speaker, text: text)
            self?.yuiManager?.feedMessage("\(speaker): \(text)")
        }

        // TTS読み上げ中 or 声紋登録中 → YUiは全部黙る
        yuiManager?.isSpeakingChecker = { [weak self] in
            let ttsSpeaking = self?.captureManager?.speechManager.isSpeaking ?? false
            let enrolling = self?.roomTranscription?.isEnrolling ?? false
            return ttsSpeaking || enrolling
        }

        // TTS再生状態をRoomTranscriptionに伝える（自分の声を拾わない）
        captureManager?.speechManager.onSpeakingChanged = { [weak self] isSpeaking in
            self?.roomTranscription?.isTTSPlaying = isSpeaking
        }

        captureManager?.yuiManager = yuiManager
        captureManager?.roomTranscription = roomTranscription

        // 音声文字起こし（スペースキー長押し — もりけん専用 push-to-talk）
        voiceManager = VoiceTranscriptionManager()
        voiceManager?.onTranscription = { [weak self] text in
            let entry = "🎤 もりけん: \(text)"
            self?.logWindowController?.addEntry(entry, isYUi: false)
            self?.yuiManager?.feedMessage("もりけん: \(text)")
        }
        voiceManager?.onLog = { [weak self] message in
            self?.logWindowController?.addEntry(message)
        }
        voiceManager?.onRecordingStateChanged = { [weak self] recording in
            if recording {
                self?.statusBarController?.setStatus("🎙 録音中...")
                // push-to-talk中は常時リスニングを停止（マイク競合防止）
                self?.roomTranscription?.stop()
            } else {
                self?.statusBarController?.setStatus("動作中 🔊")
                // push-to-talk終了後、常時リスニング再開
                self?.roomTranscription?.start()
            }
        }
        voiceManager?.setup()

        checkAccessibilityPermission()

        statusBarController?.onToggle = { [weak self] isRunning in
            if isRunning {
                self?.captureManager?.start()
                self?.yuiManager?.startIdleMonitoring()
                self?.roomTranscription?.start()
            } else {
                self?.captureManager?.stop()
                self?.yuiManager?.stopIdleMonitoring()
                self?.roomTranscription?.stop()
            }
        }

        statusBarController?.onTest = { [weak self] in
            self?.captureManager?.speakTest()
        }

        statusBarController?.onDumpAXTree = { [weak self] in
            self?.captureManager?.dumpAXTree()
        }

        statusBarController?.onStartEnrollment = { [weak self] user in
            guard let self = self else { return }
            self.roomTranscription?.startEnrollmentSequence(participants: [user])
        }

        statusBarController?.getRegisteredVoiceProfiles = { [weak self] in
            return self?.roomTranscription?.diarizer.registeredSpeakers ?? []
        }

        statusBarController?.onClearAllVoiceProfiles = { [weak self] in
            self?.roomTranscription?.diarizer.clearAllProfiles()
            self?.logWindowController?.addEntry("🗑 全声紋プロファイルをクリアしました。再登録してください。")
        }

        // 声紋登録: YUiに喋らせるコールバック（TTS完了通知付き）
        roomTranscription?.onSpeakRequest = { [weak self] text, completion in
            self?.logWindowController?.addEntry("🤖 YUi: \(text)", isYUi: true)
            self?.speakAsYUi(text, likability: 60)

            if let completion = completion {
                // TTS完了を監視して、終わったらコールバック
                self?.waitForTTSCompletion(completion: completion)
            }
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
            if let users = self.captureManager?.detectedUsers {
                self.statusBarController?.refreshUserList(users)
            }
        }

        statusBarController?.getUserVoice = { [weak self] user in
            self?.captureManager?.speechManager.voiceForUser(user) ?? .system
        }

        captureManager?.onUsersUpdated = { [weak self] users in
            self?.statusBarController?.refreshUserList(users)
        }

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

        logWindowController?.show()
    }

    /// 好感度に応じたYUiの声スタイルで読み上げ
    private func speakAsYUi(_ text: String, likability: Int) {
        guard let sm = captureManager?.speechManager else { return }

        let speakers = sm.cachedSpeakers
        guard !speakers.isEmpty else {
            sm.speak(text)
            return
        }

        let yuiCharacter = "四国めたん"
        let yuiStyles = speakers.filter { $0.name == yuiCharacter }

        if !yuiStyles.isEmpty {
            let style: String
            switch likability {
            case 75...:  style = "あまあま"
            case 55..<75: style = "ノーマル"
            case 35..<55: style = "ツンツン"
            default:      style = "セクシー"
            }

            if let matched = yuiStyles.first(where: { $0.style == style }) {
                sm.speak(text, withVoice: .voicevox(matched.id))
                return
            }
            if let normal = yuiStyles.first {
                sm.speak(text, withVoice: .voicevox(normal.id))
                return
            }
        }

        sm.speak(text)
    }

    /// TTS再生が完了するまでポーリングして、完了したらコールバック
    private func waitForTTSCompletion(completion: @escaping () -> Void) {
        guard let sm = captureManager?.speechManager else {
            completion()
            return
        }

        // 0.3秒ごとにチェック、喋り終わったら1秒待ってからコールバック
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard self != nil else { return }
                if sm.isSpeaking {
                    check()  // まだ喋ってる → 再チェック
                } else {
                    // 喋り終わった → 少し待ってからコールバック（残響除去）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        completion()
                    }
                }
            }
        }
        check()
    }

    func applicationWillTerminate(_ notification: Notification) {
        yuiManager?.flushAllMemory()
        roomTranscription?.stop()
    }

    private func checkAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            statusBarController?.setStatus("⚠️ アクセシビリティ許可が必要")
        }
    }
}
