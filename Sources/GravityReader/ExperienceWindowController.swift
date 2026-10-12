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
        window.contentView = scrollView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ experiences: [YUiExperienceManager.Experience]) {
        let origin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        textView.string = experiences.reversed().map { experience in
            let date = experience.timestamp.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "日時不明"
            return "\(date)\n出来事: \(experience.event)\n感情: \(experience.emotion)\n学び: \(experience.learning)"
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
