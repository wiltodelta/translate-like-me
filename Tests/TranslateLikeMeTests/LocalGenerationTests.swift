import Foundation
import MLXLMCommon
import os
import XCTest
@testable import TranslateLikeMe

final class LocalGenerationTests: XCTestCase {
    func testCancelledConsumerWaitsForTheProducerToDrain() async {
        let gate = TestGate()
        let completed = OSAllocatedUnfairLock(initialState: (producer: false, consumer: false))
        let cancelled = expectation(description: "Cancellation reached the SDK producer")
        let stream = AsyncStream<Generation> { _ in }
        let producer = Task {
            await withTaskCancellationHandler {
                await gate.wait()
                completed.withLock { $0.producer = true }
            } onCancel: {
                cancelled.fulfill()
            }
        }
        let consumer = Task {
            defer { completed.withLock { $0.consumer = true } }
            return try await LocalGeneration.collect(stream, producer: producer)
        }
        consumer.cancel()
        // Wait for the cancellation event, not a fixed number of scheduler turns.
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertTrue(producer.isCancelled, "Cancellation must reach the SDK producer")
        XCTAssertFalse(completed.withLock { $0.consumer }, "A cancelled consumer must still drain GPU work")
        await gate.open()
        do {
            _ = try await consumer.value
            XCTFail("Cancellation must propagate after draining")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(completed.withLock { $0.producer })
    }

    func testCompletedAnswerIsCollectedAfterTheProducerFinishes() async throws {
        let stream = AsyncStream<Generation> { continuation in
            continuation.yield(.chunk("Hello"))
            continuation.yield(.chunk(" world"))
            continuation.yield(.info(GenerateCompletionInfo(promptTokenCount: 1, generationTokenCount: 2,
                promptTime: 0, generationTime: 0)))
            continuation.finish()
        }
        let text = try await LocalGeneration.collect(stream, producer: Task {})
        XCTAssertEqual(text, "Hello world")
    }

    func testLengthLimitCannotReturnPartialTranslation() async throws {
        let stream = AsyncStream<Generation> { continuation in
            continuation.yield(.chunk("unfinished translation"))
            continuation.yield(.info(GenerateCompletionInfo(promptTokenCount: 1, generationTokenCount: 256,
                promptTime: 0, generationTime: 0, stopReason: .length)))
            continuation.finish()
        }
        do {
            _ = try await LocalGeneration.collect(stream, producer: Task {})
            XCTFail("A bounded partial answer must not replace the selection")
        } catch LocalModelError.outputLimit { }
    }
}
