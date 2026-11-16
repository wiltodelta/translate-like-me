import Foundation
import os
@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXNN
@preconcurrency import WhisperKit

// Own the non-Sendable MLX Parakeet runtime and Fluid Speech Pro's subsampling
// frame cleaner in one actor, freeing Metal buffers on unload.
actor DictationFluidSpeech {
    static let source = ModelDownloadConfig(modelRepo: "FluidVoice-Labs/fluid-speech-pro-mlx",
                                            revision: "aeb1d4e43487586b15d86c0a1dd4511e1cf6b7a0")
    static let files = ["config.json", "model.8bit.safetensors"]
    private static let cleanerPrefix = "encoder.pre_encode.fv_insert."
    private var model: ParakeetModel?
    private var subsamplingState: FluidSubsamplingState?

    init(root: URL) async throws {
        guard MLXKernels.use() else { throw DictationError.notReady }
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-fluid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }

        do {
            let spec = try Self.stageRuntimeConfig(from: root.appendingPathComponent("config.json"),
                                                   to: runtime.appendingPathComponent("config.json"))
            try Task.checkCancellation()
            let allWeights = try MLX.loadArrays(url: root.appendingPathComponent("model.8bit.safetensors"))
            let split = try Self.splitWeights(allWeights)
            try MLX.save(arrays: split.base, url: runtime.appendingPathComponent("model.safetensors"))
            try Task.checkCancellation()

            let loaded = try ParakeetModel.fromDirectory(runtime, computeDType: .bfloat16)
            let state = FluidSubsamplingState(hopLength: loaded.preprocessConfig.hopLength)
            try Self.installFrameCleaner(on: loaded, spec: spec, weights: split.cleaner, state: state)
            try Task.checkCancellation()
            Self.warmUp(loaded, state: state)
            model = loaded
            subsamplingState = state
        } catch {
            Self.clearGPUCache()
            throw error
        }
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard let model, let subsamplingState else { throw DictationError.notReady }
        defer { Self.clearGPUCache() }
        let sampleRate = model.preprocessConfig.sampleRate
        let minimumSamples = max(2 * model.preprocessConfig.hopLength, 1)
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: sampleRate, chunkDuration: 30)
        var transcripts: [String] = []
        for (chunk, _) in chunks {
            try Task.checkCancellation()
            var input = chunk
            let count = input.shape[0]
            if count < minimumSamples {
                input = MLX.concatenated([input, MLXArray.zeros([minimumSamples - count])], axis: 0)
            }
            subsamplingState.setInputSamples(input.shape[0])
            let output = model.generate(audio: input)
            let trimmed = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { transcripts.append(trimmed) }
        }
        return DictationTextSpacing.joinChunks(transcripts)
    }

    func unload() {
        model = nil
        subsamplingState = nil
        Self.clearGPUCache()
    }

    private struct CleanerSpec {
        let width: Int
        let insertDim: Int
        let insertKernel: Int
    }

    private static func stageRuntimeConfig(from source: URL, to destination: URL) throws -> CleanerSpec {
        let rawData = try Data(contentsOf: source)
        guard var root = try JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              var preprocessor = root["preprocessor"] as? [String: Any],
              var encoder = root["encoder"] as? [String: Any],
              let dModel = encoder["d_model"] as? Int,
              let fluid = root["fluid_speech"] as? [String: Any],
              fluid["insert"] as? String == "pre",
              let insertDim = fluid["insert_dim"] as? Int,
              let insertKernel = fluid["insert_kernel"] as? Int else {
            throw DictationError.notReady
        }
        preprocessor["normalize_valid_frames"] = true
        encoder["mask_padding"] = true
        root["preprocessor"] = preprocessor
        root["encoder"] = encoder
        root["quantization"] = ["group_size": 64, "bits": 8]
        let serialized = try JSONSerialization.data(withJSONObject: root)
        try serialized.write(to: destination, options: .atomic)
        return CleanerSpec(width: dModel, insertDim: insertDim, insertKernel: insertKernel)
    }

    private static func splitWeights(
        _ allWeights: [String: MLXArray]
    ) throws -> (base: [String: MLXArray], cleaner: [String: MLXArray]) {
        var base: [String: MLXArray] = [:]
        var cleaner: [String: MLXArray] = [:]
        for (name, tensor) in allWeights {
            if name.hasPrefix(cleanerPrefix) {
                cleaner[String(name.dropFirst(cleanerPrefix.count))] = tensor
            } else {
                base[name] = tensor
            }
        }
        guard !cleaner.isEmpty else { throw DictationError.notReady }
        return (base, cleaner)
    }

    private static func installFrameCleaner(on loaded: ParakeetModel, spec: CleanerSpec,
                                            weights: [String: MLXArray],
                                            state: FluidSubsamplingState) throws {
        let cleaner = FluidFrameCleaner(width: spec.width, dim: spec.insertDim, kernel: spec.insertKernel)
        quantize(model: cleaner, groupSize: 64, bits: 8)
        try cleaner.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        cleaner.apply { $0.dtype.isFloatingPoint && $0.dtype != .bfloat16 ? $0.asType(.bfloat16) : $0 }

        let leaves = Dictionary(uniqueKeysWithValues: loaded.leafModules().flattened())
        guard let pointwise0 = leaves["encoder.pre_encode.pointwise_layers.0"] as? Conv2d,
              let pointwise1 = leaves["encoder.pre_encode.pointwise_layers.1"] as? Conv2d,
              let baseOut = leaves["encoder.pre_encode.out"] as? Linear else {
            throw DictationError.notReady
        }
        let replacements: [(String, Module)] = [
            ("encoder.pre_encode.pointwise_layers.0",
             MaskedPointwiseConv2d(base: pointwise0, stage: 2, state: state)),
            ("encoder.pre_encode.pointwise_layers.1",
             MaskedPointwiseConv2d(base: pointwise1, stage: 3, state: state)),
            ("encoder.pre_encode.out", FluidOutWithFrameCleaner(base: baseOut, cleaner: cleaner))
        ]
        try loaded.update(modules: ModuleChildren.unflattened(replacements), verify: .noUnusedKeys)
        loaded.train(false)
        eval(loaded)
    }

    private static func warmUp(_ model: ParakeetModel, state: FluidSubsamplingState) {
        state.setInputSamples(16_000)
        _ = model.generate(audio: MLXArray.zeros([16_000]))
        clearGPUCache()
    }

    private static func clearGPUCache() {
        Stream.gpu.synchronize()
        Memory.clearCache()
    }
}

// Tracks the current chunk's valid frame count at each strided subsampling stage.
final class FluidSubsamplingState: Sendable {
    private let hopLength: Int
    private let sampleCount = OSAllocatedUnfairLock(initialState: 16_000)

    init(hopLength: Int) { self.hopLength = max(hopLength, 1) }

    func setInputSamples(_ count: Int) {
        sampleCount.withLock { $0 = count }
    }

    func validFrames(stage: Int) -> Int {
        var frames = sampleCount.withLock { $0 } / hopLength
        for _ in 0..<stage { frames = (frames + 1) / 2 }
        return frames
    }
}

private final class FluidFrameCleaner: Module, UnaryLayer {
    @ModuleInfo(key: "ln") var layerNorm: LayerNorm
    @ModuleInfo(key: "down") var down: Linear
    @ModuleInfo(key: "mix") var mix: Conv1d
    @ModuleInfo(key: "up") var up: Linear

    init(width: Int, dim: Int, kernel: Int) {
        self._layerNorm.wrappedValue = LayerNorm(dimensions: width)
        self._down.wrappedValue = Linear(width, dim)
        self._mix.wrappedValue = Conv1d(inputChannels: dim, outputChannels: dim, kernelSize: kernel,
                                        padding: kernel / 2, groups: dim)
        self._up.wrappedValue = Linear(dim, width)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        x + up(gelu(mix(down(layerNorm(x)))))
    }
}

// NeMo zeroes frames past the valid length after pointwise subsampling layers too,
// so their biases never leak into the next convolution or projection.
private final class MaskedPointwiseConv2d: Conv2d {
    @ModuleInfo(key: "base") var base: Conv2d
    private let stage: Int
    private let state: FluidSubsamplingState

    init(base: Conv2d, stage: Int, state: FluidSubsamplingState) {
        self._base.wrappedValue = base
        self.stage = stage
        self.state = state
        super.init(inputChannels: 1, outputChannels: 1, kernelSize: 1, bias: false)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let output = base(x)
        let limit = state.validFrames(stage: stage)
        guard limit < output.dim(1) else { return output }
        let valid = (MLXArray(0..<output.dim(1)) .< Int32(limit)).reshaped([1, output.dim(1), 1, 1])
        return MLX.where(valid, output, MLXArray(Float(0)).asType(output.dtype))
    }
}

private final class FluidOutWithFrameCleaner: Linear {
    @ModuleInfo(key: "base") var base: Linear
    @ModuleInfo(key: "cleaner") var cleaner: FluidFrameCleaner

    init(base: Linear, cleaner: FluidFrameCleaner) {
        self._base.wrappedValue = base
        self._cleaner.wrappedValue = cleaner
        super.init(weight: MLXArray.zeros([1, 1]))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        cleaner(base(x))
    }
}
