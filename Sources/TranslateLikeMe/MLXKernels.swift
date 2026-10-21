import Foundation
@preconcurrency import MLX

// The app bundles MLX's native Metal kernels in Contents/Resources, where MLX's
// own lookup (beside the executable) does not reach, so both local models point
// MLX at them before touching the GPU. A CLI or test host keeps that colocated
// lookup.
enum MLXKernels {
    private static let lock = NSLock()

    static func use() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let library = Bundle.main.url(forResource: "mlx", withExtension: "metallib") ?? GPU.metallib ??
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: library.path) else { return false }
        if GPU.metallib != library { GPU.metallib = library }
        return true
    }
}
