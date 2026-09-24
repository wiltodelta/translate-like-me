import AppKit
import XCTest
@testable import TranslateLikeMe

// A private named pasteboard, so the tests never touch the user's clipboard.
final class ClipboardTests: XCTestCase {
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: NSPasteboard.Name("TranslateLikeMeTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        board.releaseGlobally()
        super.tearDown()
    }

    func testRestoreBringsBackEveryType() {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data("{\\\\rtf1 rich}".utf8), forType: .rtf)
        board.writeObjects([item])
        let snapshot = SelectionService.snapshot(of: board)

        board.clearContents()
        board.setString("translation", forType: .string)
        SelectionService.restore(snapshot, ifUnchangedSince: board.changeCount, on: board)

        XCTAssertEqual(board.string(forType: .string), "plain")
        XCTAssertEqual(board.data(forType: .rtf), Data("{\\\\rtf1 rich}".utf8))
    }

    func testAnEmptyClipboardIsRestoredEmpty() {
        board.clearContents()
        let snapshot = SelectionService.snapshot(of: board)
        board.setString("translation", forType: .string)
        SelectionService.restore(snapshot, ifUnchangedSince: board.changeCount, on: board)
        XCTAssertNil(board.string(forType: .string))
    }

    func testANewerCopyIsNotOverwritten() {
        board.clearContents()
        board.setString("original", forType: .string)
        let snapshot = SelectionService.snapshot(of: board)
        let mark = board.changeCount
        board.clearContents()
        board.setString("copied by the user meanwhile", forType: .string)
        SelectionService.restore(snapshot, ifUnchangedSince: mark, on: board)
        XCTAssertEqual(board.string(forType: .string), "copied by the user meanwhile")
    }
}
