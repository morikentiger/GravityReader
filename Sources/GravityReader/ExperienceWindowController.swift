import AppKit

/// 会話ログとは独立して、保存済みの経験を全文で読む画面。
final class ExperienceWindowController: NSWindowController {
    private let textView: NSTextView

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "YUiの経験"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("YUiExperienceWindow")
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init(window: window)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        scrollView.hasVerticalScroller = true
        let content = NSView()
        let archiveButton = NSButton(title: "旧経験のアーカイブ…", target: self, action: #selector(openArchives))
        archiveButton.bezelStyle = .rounded
        archiveButton.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(archiveButton)
        content.addSubview(scrollView)
        window.contentView = content
        NSLayoutConstraint.activate([
            archiveButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            archiveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: archiveButton.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openArchives() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GravityReader/archives")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func refresh(_ experiences: [YUiExperienceManager.Experience]) {
        let origin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        textView.string = experiences.reversed().map { experience in
            let date = experience.timestamp.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "日時不明"
            let kind = experience.kind == .ownConversation ? "自身の会話経験" : "他人から聞いた体験"
            let lesson = experience.learning.isEmpty ? "振り返り前（効果未確認）" : experience.learning
            return "\(date)　[\(kind)]\n出来事: \(experience.event)\n会話の根拠: \(experience.source)\n次の発言: \(experience.reactions.isEmpty ? "未観測" : experience.reactions.joined(separator: " / "))\n感情: \(experience.emotion)\n次回への学び: \(lesson)"
        }.joined(separator: "\n\n────────────────────\n\n")
        if experiences.isEmpty { textView.string = "経験はまだありません。会話から経験が追加されると、ここに表示されます。" }
        window?.title = "YUiの経験（\(experiences.count)件）"
        textView.enclosingScrollView?.contentView.scroll(to: origin)
    }

    func showExperiences(_ experiences: [YUiExperienceManager.Experience]) {
        refresh(experiences)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
