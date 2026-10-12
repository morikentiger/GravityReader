import AppKit

final class JevSettingsView: NSView {
    private let keyField = NSSecureTextField()
    private let modePopup = NSPopUpButton()
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
        label("有効時はコメント本文と直近3件をTypeSafeへ送信します。名前・音声・経験ノートは送信しません。", 80)
        label("日本語での判定精度は実運用で確認が必要です。接続失敗時は既存フィルタで処理を続けます。", 34)
        let link = NSButton(title: "TypeSafeのAPIコンソール", target: self, action: #selector(openConsole))
        link.frame = NSRect(x: 20, y: 1, width: 230, height: 30)
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
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyField.stringValue = ""
        status.stringValue = "保存中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let saved = KeychainHelper.save(key: JevCommentGate.keychainKey, value: key)
            DispatchQueue.main.async { self?.status.stringValue = saved ? "APIキー保存済み" : "保存できませんでした。再入力してください" }
        }
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://console.typesafe.ai")!)
    }
}
