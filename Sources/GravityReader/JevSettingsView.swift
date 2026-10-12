import AppKit

final class JevSettingsView: NSView {
    private let keyField = NSSecureTextField()
    private let modePopup = NSPopUpButton()
    private let connectionStatus = NSTextField(wrappingLabelWithString: "まだ接続テストしていません")
    private let testButton = NSButton(title: "保存して接続テスト", target: nil, action: nil)
    private var statusObserver: NSObjectProtocol?
    private var testGeneration = UUID()
    private let status = NSTextField(labelWithString: "キーの状態を確認中…")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 340))
        func label(_ text: String, _ y: CGFloat) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.frame = NSRect(x: 20, y: y, width: 440, height: 44)
            field.font = .systemFont(ofSize: 12)
            addSubview(field)
        }
        label("Jevでコメント内容を判定します。まず観察モードで、通常の会話が誤判定されないか確認できます。", 282)
        modePopup.frame = NSRect(x: 20, y: 241, width: 430, height: 30)
        modePopup.addItems(withTitles: ["オフ（既存フィルタのみ）", "観察（判定を記録・抑制しない）", "抑制（確度の高いスパムを読み上げ・返答から除外）"])
        modePopup.selectItem(at: min(2, max(0, AppDefaults.suite.integer(forKey: "GR_JevMode"))))
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        addSubview(modePopup)
        label("TypeSafe APIキー（OpenAI・Fish Audioとは別）", 187)
        keyField.frame = NSRect(x: 20, y: 170, width: 340, height: 24)
        keyField.placeholderString = "キーを入力。空欄で保存すると既存キーを維持"
        addSubview(keyField)
        let save = NSButton(title: "保存", target: self, action: #selector(saveKey))
        save.frame = NSRect(x: 370, y: 167, width: 80, height: 30)
        save.bezelStyle = .rounded
        addSubview(save)
        status.frame = NSRect(x: 20, y: 140, width: 440, height: 24)
        status.font = .systemFont(ofSize: 12)
        addSubview(status)
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testButton.frame = NSRect(x: 20, y: 105, width: 205, height: 30)
        addSubview(testButton)
        connectionStatus.frame = NSRect(x: 20, y: 50, width: 440, height: 52)
        connectionStatus.font = .systemFont(ofSize: 12)
        addSubview(connectionStatus)
        refreshConnectionStatus()
        statusObserver = NotificationCenter.default.addObserver(forName: JevConnection.statusChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshConnectionStatus() }
        label("有効時は原文・読み方・直近3件をTypeSafeへ送信。接続テストは固定の挨拶文を送信します。失敗時は既存フィルタを使います。", 3)
        let link = NSButton(title: "TypeSafeのAPIコンソール", target: self, action: #selector(openConsole))
        link.frame = NSRect(x: 230, y: 105, width: 225, height: 30)
        link.bezelStyle = .rounded
        addSubview(link)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = !(KeychainHelper.load(key: JevCommentGate.keychainKey) ?? "").isEmpty
            DispatchQueue.main.async { self?.status.stringValue = exists ? "APIキー保存済み" : "APIキー未設定" }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func modeChanged() {
        AppDefaults.suite.set(modePopup.indexOfSelectedItem, forKey: "GR_JevMode")
        NotificationCenter.default.post(name: JevConnection.configurationChanged, object: nil)
    }

    deinit {
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshConnectionStatus() {
        connectionStatus.stringValue = AppDefaults.suite.string(forKey: "GR_JevLastStatus") ?? "接続未確認。キー保存だけではAPIの利用可否は分かりません。"
    }

    @objc private func saveKey() { persist(test: false) }
    @objc private func testConnection() { persist(test: true) }

    private func persist(test: Bool) {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { if test { runConnectionTest() }; return }
        keyField.stringValue = ""
        status.stringValue = "保存中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let saved = KeychainHelper.save(key: JevCommentGate.keychainKey, value: key)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status.stringValue = saved ? "APIキー保存済み" : "保存できませんでした。再入力してください"
                if saved {
                    NotificationCenter.default.post(name: JevConnection.configurationChanged, object: nil)
                    if test { self.runConnectionTest() }
                }
            }
        }
    }

    private func runConnectionTest() {
        testButton.isEnabled = false
        connectionStatus.stringValue = "固定の挨拶文で接続確認中…"
        let generation = UUID()
        testGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.testGeneration == generation, !self.testButton.isEnabled else { return }
            self.testGeneration = UUID()
            self.testButton.isEnabled = true
            self.connectionStatus.stringValue = "キー取得待ち。macOSのキーチェーン許可画面を確認し、再試行してください。"
        }
        JevConnection.check { [weak self] verdict, detail in
            guard let self = self, self.testGeneration == generation else { return }
            self.testButton.isEnabled = true
            JevConnection.publish(detail)
            if verdict != .unavailable {
                NotificationCenter.default.post(name: JevConnection.configurationChanged, object: nil)
            }
        }
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.typesafe.ai")!)
    }
}
