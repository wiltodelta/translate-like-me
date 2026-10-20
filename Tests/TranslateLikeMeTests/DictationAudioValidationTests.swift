import AVFoundation
import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationAudioValidationTests: XCTestCase {
    private struct Sample: Decodable {
        let id: String
        let file: String
        let terms: [String]
        let expectEmpty: Bool
    }

    // No microphone, speakers or downloads. This checks the path after voice
    // processing, not preservation of a physical voice by the echo canceller.
    func testSyntheticAudioThroughCaptureFileAndRecognition() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TLM_AUDIO_CHECK"] else {
            throw XCTSkip("Run python3 scripts/check-dictation-audio.py for unattended synthetic validation")
        }
        let root = URL(fileURLWithPath: directory)
        let samples = try JSONDecoder().decode([Sample].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        XCTAssertFalse(samples.isEmpty)
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let engine = DictationEngine(directory: cache)
        let modelName = ProcessInfo.processInfo.environment["TLM_AUDIO_CHECK_MODEL"] ?? DictationModel.turbo.rawValue
        let model = try XCTUnwrap(DictationModel(rawValue: modelName))
        try await engine.prepare(model: model, download: false) { _ in }
        let loadedModel = await engine.loadedModel
        XCTAssertEqual(loadedModel, model)
        var report: [[String: Any]] = []
        for sample in samples {
            XCTAssertEqual(sample.file, URL(fileURLWithPath: sample.file).lastPathComponent)
            let audio = try capturedFile(root.appendingPathComponent(sample.file), root: root, id: sample.id)
            for repetition in 1...3 {
                let text = try await engine.transcribe(audio)
                let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                               locale: Locale(identifier: "ru_RU"))
                let matches = sample.terms.filter { normalized.contains($0) }.count
                XCTAssertEqual(text.isEmpty, sample.expectEmpty, "Unexpected emptiness for \(sample.id)")
                XCTAssertEqual(matches, sample.terms.count, "Missing synthetic terms for \(sample.id)")
                report.append(["id": sample.id, "repetition": repetition, "empty": text.isEmpty,
                               "matchedTerms": matches, "requiredTerms": sample.terms.count])
            }
        }
        await engine.unload()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("recognition.json"))
    }

    private func capturedFile(_ source: URL, root: URL, id: String) throws -> URL {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(input.processingFormat.channelCount, 1)
        XCTAssertEqual(input.processingFormat.sampleRate, 48_000)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 7))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  interleaved: false, channelLayout: layout)
        let original = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_024))
        let native = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let output = root.appendingPathComponent("captured-\(id).wav")
        let capture = try DictationAudioFile(url: output, format: format)
        while input.framePosition < input.length {
            try input.read(into: original)
            native.frameLength = original.frameLength
            let from = try XCTUnwrap(original.floatChannelData)[0]
            let channels = try XCTUnwrap(native.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(from: from, count: Int(original.frameLength))
            }
            XCTAssertNil(capture.append(native), "Synthetic fixture must fit within the recording limit")
        }
        XCTAssertTrue(capture.isDeliveringAudio)
        try capture.finish()
        let finalized = try AVAudioFile(forReading: output)
        XCTAssertEqual(finalized.length, input.length)
        XCTAssertEqual(finalized.fileFormat.channelCount, format.channelCount)
        return output
    }
}
