import AVFoundation
import CoreAudio
import Foundation
import Synchronization

// Lock-free single-producer / single-consumer PCM bridge from Core Audio's
// real-time sink callback to the non-real-time WAV writer queue. Allocated and
// page-faulted once per prepared audio graph and reused across holds so shortcut
// presses and real-time callbacks never allocate, page-fault, lock, or touch ARC.
final class DictationSinkStream: @unchecked Sendable {
    private struct Segment {
        var frameOffset: Int64 = 0
        var frameCount: Int32 = 0
        var sampleTime: Int64?
        var validFormat = true
    }

    private static let segmentCapacity = 8_192 // Power of two (~87 s of 512-frame cycles).
    private static let stagingCapacity: AVAudioFrameCount = 8_192

    let channels: Int
    let rate: Double
    private let capacityFrames: Int
    private let sampleCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let segments: UnsafeMutablePointer<Segment>
    private let staging: AVAudioPCMBuffer
    private let writeFrame = Atomic<Int64>(0)
    private let readFrame = Atomic<Int64>(0)
    private let writeSegment = Atomic<Int64>(0)
    private let readSegment = Atomic<Int64>(0)
    private let accepting = Atomic(false)
    private let cancelled = Atomic(false)
    private let streamFlags = DictationAudioFile.Flags()
    private let drainQueue = DispatchQueue(label: "com.wiltodelta.translatelikeme.capture.sink", qos: .userInitiated)
    private let source: DispatchSourceUserDataAdd
    private var currentSink: DictationAudioFile?
    private var currentEnded: (@Sendable (Bool) -> Void)?
    private var reportedTerminal = false

    init?(format: AVAudioFormat) {
        let channels = Int(format.channelCount)
        let rate = format.sampleRate
        guard channels > 0, rate > 0,
              let staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.stagingCapacity) else {
            return nil
        }
        self.channels = channels
        self.rate = rate
        self.staging = staging
        capacityFrames = max(Int(Self.stagingCapacity) * 2, Int(rate * 4))
        sampleCount = channels * capacityFrames
        samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        samples.initialize(repeating: 0, count: sampleCount)
        segments = UnsafeMutablePointer<Segment>.allocate(capacity: Self.segmentCapacity)
        segments.initialize(repeating: Segment(), count: Self.segmentCapacity)
        source = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        source.setEventHandler { [weak self] in self?.drainPending() }
        source.resume()
    }

    deinit {
        source.cancel()
        segments.deinitialize(count: Self.segmentCapacity)
        segments.deallocate()
        samples.deinitialize(count: sampleCount)
        samples.deallocate()
    }

    func attach(_ sink: DictationAudioFile, ended: @escaping @Sendable (Bool) -> Void) {
        accepting.store(false, ordering: .releasing)
        cancelled.store(true, ordering: .releasing)
        drainQueue.sync {
            currentSink?.detachStreamFlags()
            streamFlags.reset()
            readSegment.store(writeSegment.load(ordering: .acquiring), ordering: .releasing)
            readFrame.store(writeFrame.load(ordering: .acquiring), ordering: .releasing)
            currentSink = sink
            currentEnded = ended
            reportedTerminal = false
            cancelled.store(false, ordering: .releasing)
            sink.attachStreamFlags(streamFlags)
        }
        accepting.store(true, ordering: .releasing)
    }

    func detach(flush: Bool) {
        accepting.store(false, ordering: .releasing)
        if !flush { cancelled.store(true, ordering: .releasing) }
        drainQueue.sync {
            if flush { drainPending() }
            currentSink?.detachStreamFlags()
            readSegment.store(writeSegment.load(ordering: .acquiring), ordering: .releasing)
            readFrame.store(writeFrame.load(ordering: .acquiring), ordering: .releasing)
            currentSink = nil
            currentEnded = nil
        }
    }

    func enqueue(_ timestamp: UnsafePointer<AudioTimeStamp>?, frames frameCount: AVAudioFrameCount,
                 audio: UnsafePointer<AudioBufferList>) {
        guard accepting.load(ordering: .acquiring), frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audio))
        let byteRequirement = Int(frameCount) * MemoryLayout<Float>.size
        let formatOK = buffers.count == channels && buffers.allSatisfy {
            $0.mNumberChannels == 1 && $0.mData != nil && Int($0.mDataByteSize) >= byteRequirement
        }
        let nextSeg = writeSegment.load(ordering: .relaxed)
        let consumedSeg = readSegment.load(ordering: .acquiring)
        guard nextSeg - consumedSeg < Int64(Self.segmentCapacity) else { return }
        guard formatOK else {
            segments[Int(nextSeg & Int64(Self.segmentCapacity - 1))] = Segment(validFormat: false)
            writeSegment.store(nextSeg + 1, ordering: .releasing)
            accepting.store(false, ordering: .relaxed)
            source.add(data: 1)
            return
        }
        let count = Int(frameCount)
        let nextFrame = writeFrame.load(ordering: .relaxed)
        let consumedFrame = readFrame.load(ordering: .acquiring)
        guard Int(nextFrame - consumedFrame) + count <= capacityFrames else { return }
        streamFlags.markDelivered()
        copyInput(buffers, count: count, frameOffset: nextFrame)
        let sampleTime: Int64? = if let stamp = timestamp?.pointee,
                                    stamp.mFlags.contains(.sampleTimeValid),
                                    stamp.mSampleTime.isFinite {
            Int64(stamp.mSampleTime.rounded())
        } else {
            nil
        }
        segments[Int(nextSeg & Int64(Self.segmentCapacity - 1))] = Segment(
            frameOffset: nextFrame, frameCount: Int32(count), sampleTime: sampleTime, validFormat: true
        )
        writeFrame.store(nextFrame + Int64(count), ordering: .releasing)
        writeSegment.store(nextSeg + 1, ordering: .releasing)
        source.add(data: 1)
    }

    private func copyInput(_ buffers: UnsafeMutableAudioBufferListPointer, count: Int, frameOffset: Int64) {
        let start = Int(frameOffset % Int64(capacityFrames))
        let firstPart = min(count, capacityFrames - start)
        let secondPart = count - firstPart
        var foundSignal = false
        let needsSignalCheck = !streamFlags.signal.load(ordering: .relaxed)
        for channel in 0..<channels {
            guard let input = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            if needsSignalCheck && !foundSignal {
                for index in 0..<count where input[index] != 0 {
                    foundSignal = true
                    break
                }
            }
            let destination = samples + channel * capacityFrames
            UnsafeMutableRawPointer(destination + start)
                .copyMemory(from: input, byteCount: firstPart * MemoryLayout<Float>.stride)
            if secondPart > 0 {
                UnsafeMutableRawPointer(destination)
                    .copyMemory(from: input + firstPart, byteCount: secondPart * MemoryLayout<Float>.stride)
            }
        }
        if foundSignal { streamFlags.markSignal() }
    }

    private func drainPending() {
        guard let sink = currentSink, let channelData = staging.floatChannelData else { return }
        var currentSeg = readSegment.load(ordering: .relaxed)
        let availableSeg = writeSegment.load(ordering: .acquiring)
        while currentSeg < availableSeg, !cancelled.load(ordering: .acquiring) {
            let segment = segments[Int(currentSeg & Int64(Self.segmentCapacity - 1))]
            guard segment.validFormat else {
                currentSeg += 1
                readSegment.store(currentSeg, ordering: .releasing)
                if sink.failFormat() { finishOnce(false) }
                return
            }
            writeSegmentFrames(segment, to: sink, into: channelData)
            readFrame.store(segment.frameOffset + Int64(segment.frameCount), ordering: .releasing)
            currentSeg += 1
            readSegment.store(currentSeg, ordering: .releasing)
        }
    }

    private func writeSegmentFrames(_ segment: Segment, to sink: DictationAudioFile,
                                    into channelData: UnsafePointer<UnsafeMutablePointer<Float>>) {
        var remaining = Int(segment.frameCount)
        var offset = segment.frameOffset
        var sampleTime = segment.sampleTime
        while remaining > 0 {
            let chunk = min(remaining, Int(Self.stagingCapacity))
            let start = Int(offset % Int64(capacityFrames))
            let firstPart = min(chunk, capacityFrames - start)
            let secondPart = chunk - firstPart
            for channel in 0..<channels {
                let sourcePtr = samples + channel * capacityFrames
                UnsafeMutableRawPointer(channelData[channel])
                    .copyMemory(from: sourcePtr + start, byteCount: firstPart * MemoryLayout<Float>.stride)
                if secondPart > 0 {
                    UnsafeMutableRawPointer(channelData[channel] + firstPart)
                        .copyMemory(from: sourcePtr, byteCount: secondPart * MemoryLayout<Float>.stride)
                }
            }
            staging.frameLength = AVAudioFrameCount(chunk)
            let time = sampleTime.map { AVAudioTime(sampleTime: $0, atRate: rate) }
            if let terminal = sink.append(staging, at: time) {
                finishOnce(terminal)
            }
            offset += Int64(chunk)
            if let current = sampleTime { sampleTime = current + Int64(chunk) }
            remaining -= chunk
        }
    }

    private func finishOnce(_ success: Bool) {
        guard !reportedTerminal else { return }
        reportedTerminal = true
        accepting.store(false, ordering: .relaxed)
        currentEnded?(success)
    }
}
