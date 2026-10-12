import Foundation

/// 相談者ごとの長期記憶を管理する
class ConsultationMemoryManager {
    private let memoriesDir: URL

    /// 現在選択中のユーザー名
    private(set) var currentUser: String? = nil

    /// 現在のユーザーのメモリー内容
    private(set) var currentMemory: UserMemory? = nil

    struct UserMemory: Codable {
        var name: String
        var createdAt: Date
        var lastTalkedAt: Date
        /// AIが記録した重要な情報（箇条書き）
        var notes: [String]
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        memoriesDir = appSupport.appendingPathComponent("GravityReader/memories")
        try? FileManager.default.createDirectory(at: memoriesDir, withIntermediateDirectories: true)
    }

    /// 保存されている全ユーザー名を返す
    func listUsers() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: memoriesDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { $0.deletingPathExtension().lastPathComponent.removingPercentEncoding }
            .sorted()
    }

    /// ユーザーを選択（既存 or 新規作成）
    func selectUser(_ name: String) {
        currentUser = name
        currentMemory = loadMemory(for: name)
        if currentMemory == nil {
            // 新規作成
            currentMemory = UserMemory(
                name: name,
                createdAt: Date(),
                lastTalkedAt: Date(),
                notes: []
            )
            saveCurrentMemory()
        }
        NSLog("[YUiMemory] ユーザー選択: \(name) (メモ \(currentMemory?.notes.count ?? 0) 件)")
    }

    /// メモリーにノートを追加して保存
    func addNotes(_ newNotes: [String]) {
        guard var memory = currentMemory else { return }
        memory.notes.append(contentsOf: newNotes)
        // 最大30件に制限（古いものを削除）
        if memory.notes.count > 30 {
            memory.notes = Array(memory.notes.suffix(30))
        }
        memory.lastTalkedAt = Date()
        currentMemory = memory
        saveCurrentMemory()
    }

    /// メモリーのノートを完全に置き換えて保存
    func replaceNotes(_ notes: [String]) {
        guard var memory = currentMemory else { return }
        memory.notes = Array(notes.suffix(30))
        memory.lastTalkedAt = Date()
        currentMemory = memory
        saveCurrentMemory()
    }

    /// 現在のユーザーを削除
    func deleteCurrentUser() {
        guard let name = currentUser else { return }
        let url = fileURL(for: name)
        try? FileManager.default.removeItem(at: url)
        currentUser = nil
        currentMemory = nil
    }

    /// システムプロンプトに含めるメモリーテキストを生成
    func memoryPromptSection() -> String? {
        guard let memory = currentMemory, !memory.notes.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "ja_JP")

        var text = "## \(memory.name)さんについての記憶\n"
        text += "（前回の会話: \(formatter.string(from: memory.lastTalkedAt))）\n"
        for note in memory.notes {
            text += "- \(note)\n"
        }
        return text
    }

    // MARK: - Private

    private func fileURL(for name: String) -> URL {
        let safeName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return memoriesDir.appendingPathComponent("\(safeName).json")
    }

    private func loadMemory(for name: String) -> UserMemory? {
        let url = fileURL(for: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UserMemory.self, from: data)
    }

    private func saveCurrentMemory() {
        guard let memory = currentMemory, let name = currentUser else { return }
        let url = fileURL(for: name)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(memory) {
            try? data.write(to: url)
        }
    }
}
