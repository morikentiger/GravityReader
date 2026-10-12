import AppKit
import XCTest
@testable import GravityReader

final class ConversationPanelLayoutTests: XCTestCase {
    func testConversationControlsFitMinimumWindowWidth() throws {
        _ = NSApplication.shared
        let controller = LogWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 520, height: 440))
        let plan = YUiConversationDirector.plan(settings: YUiPersonality(), history: [(Date(), "A: ゲーム楽しい")], replyCount: 0)
        controller.updateConversationPlan(plan, activity: "新しい発言を待つ")
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            if let label = view as? NSTextField, let parent = label.superview {
                XCTAssertGreaterThanOrEqual(label.frame.minX, -1, label.stringValue)
                XCTAssertLessThanOrEqual(label.frame.maxX, parent.bounds.width + 1, label.stringValue)
            }
            if !(view is NSControl) { view.subviews.forEach(check) }
        }
        check(root)
        try render(root, name: "conversation-panel")
        window.close()
    }

    func testStatisticsContentCanScrollInSmallWindow() throws {
        _ = NSApplication.shared
        let statistics = ConversationStatistics()
        statistics.record(.voice, characters: 60)
        statistics.record(.comment, characters: 20)
        statistics.record(.reply, characters: 20)
        statistics.record(.latency, latency: 3.2)
        statistics.record(.suppressed, reason: "同じ音の反復")
        let controller = ConversationStatisticsWindow(statistics: statistics)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 480, height: 440))
        controller.refresh()
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(root.subviews.first as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        text.layoutManager?.ensureLayout(for: try XCTUnwrap(text.textContainer))
        XCTAssertGreaterThan(text.frame.height, scroll.contentSize.height)
        XCTAssertLessThanOrEqual(text.frame.width, scroll.contentSize.width + 1)
        try render(root, name: "conversation-statistics")
        window.close()
    }

    private func render(_ view: NSView, name: String) throws {
        guard ProcessInfo.processInfo.environment["GRAVITY_RENDER_PREVIEWS"] == "1" else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
