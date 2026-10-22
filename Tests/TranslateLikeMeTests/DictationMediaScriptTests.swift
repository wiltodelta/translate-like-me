import JavaScriptCore
import XCTest
@testable import TranslateLikeMe

final class DictationMediaScriptTests: XCTestCase {
    private let playing = #"{path:'route/player (123)',item:'track-1',rate:1,position:10,stamp:1}"#
    private let paused = #"{path:'route/player (123)',item:'track-1',rate:0,position:10.1,stamp:2}"#

    func testPauseIsExplicitAndRequiresAConfirmedStateChange() throws {
        let result = try execute("pause", snapshots: [playing, playing, paused])
        XCTAssertEqual(result.status, "paused")
        XCTAssertEqual(result.commands, [1])
        XCTAssertEqual(result.reads, 3)
        XCTAssertEqual(result.receipt?["stamp"] as? Int, 2)
    }

    func testAlreadyPausedMissingAndMalformedStatesNeverStartPlayback() throws {
        for state in [paused, "null", "{}", playing.replacingOccurrences(of: "rate:1", with: "rate:null"),
                      playing.replacingOccurrences(of: "stamp:1", with: "stamp:null"),
                      playing.replacingOccurrences(of: "item:'track-1'", with: "item:''")] {
            let result = try execute("pause", snapshots: [state])
            XCTAssertEqual(result.status, "ignored", state)
            XCTAssertTrue(result.commands.isEmpty, state)
        }
    }

    func testFailedPauseHasNoRestorationReceipt() throws {
        let result = try execute("pause", snapshots: [playing])
        XCTAssertEqual(result.status, "unconfirmed")
        XCTAssertEqual(result.commands, [1])
        XCTAssertNil(result.receipt)
    }

    func testPauseWithNoNewTimestampIsNotOwned() throws {
        let result = try execute("pause", snapshots: [playing,
            paused.replacingOccurrences(of: "stamp:2", with: "stamp:1")])
        XCTAssertEqual(result.status, "unconfirmed")
        XCTAssertNil(result.receipt)
    }

    func testResumeOnlyTheSameConfirmedPause() throws {
        let result = try execute("resume", snapshots: [paused, playing], receipt: paused)
        XCTAssertEqual(result.status, "resumed")
        XCTAssertEqual(result.commands, [0])
    }

    func testUserActionsAndChangedOrRestartedPlayersPreventResume() throws {
        for changed in [playing, "null", paused.replacingOccurrences(of: "stamp:2", with: "stamp:3"),
                        paused.replacingOccurrences(of: "10.1", with: "20"),
                        paused.replacingOccurrences(of: "track-1", with: "track-2"),
                        paused.replacingOccurrences(of: "(123)", with: "(456)"),
                        paused.replacingOccurrences(of: "route/player", with: "route/other")] {
            let result = try execute("resume", snapshots: [changed], receipt: paused)
            XCTAssertEqual(result.status, "changed", changed)
            XCTAssertTrue(result.commands.isEmpty, changed)
        }
    }

    func testPlayerChangeDuringPauseIsNotOwned() throws {
        let changed = paused.replacingOccurrences(of: "track-1", with: "track-2")
        let result = try execute("pause", snapshots: [playing, changed])
        XCTAssertEqual(result.status, "changed")
        XCTAssertNil(result.receipt)
    }

    func testUnavailableBridgeFailsClosed() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(DictationMediaScript.source)
        context.evaluateScript("setup = function() { throw new Error('unavailable'); };")
        let output = try XCTUnwrap(context.evaluateScript("run(['pause'])")?.toString())
        XCTAssertEqual(output, #"{"status":"unavailable"}"#)
        XCTAssertNil(context.exception)
    }

    private struct Result {
        let status: String?
        let commands: [Int]
        let reads: Int
        let receipt: [String: Any]?
    }

    private func execute(_ action: String, snapshots: [String], receipt: String = "null") throws -> Result {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(DictationMediaScript.source)
        // Exercise the shipping script, replacing only native I/O and its clock.
        context.evaluateScript("""
            setup = function() {};
            var samples = [\(snapshots.joined(separator: ","))];
            var commands = [], reads = 0;
            snapshot = function() { reads++; return samples.length > 1 ? samples.shift() : samples[0]; };
            send = function(command) { commands.push(command); };
            wait = function() {};
            var result = JSON.parse(run(['\(action)', JSON.stringify(\(receipt))]));
            """)
        XCTAssertNil(context.exception)
        return Result(status: context.objectForKeyedSubscript("result")?.forProperty("status")?.toString(),
                      commands: context.objectForKeyedSubscript("commands")?.toArray() as? [Int] ?? [],
                      reads: Int(context.objectForKeyedSubscript("reads")?.toInt32() ?? 0),
                      receipt: context.objectForKeyedSubscript("result")?.forProperty("receipt")?
                        .toDictionary() as? [String: Any])
    }
}
