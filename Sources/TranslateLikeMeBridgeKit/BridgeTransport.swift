import Darwin
import Foundation
import os

private let transportLog = Logger.app("bridge")
private let maxFrameBytes = 262_144

enum BridgeSocketIO {
    static func makeAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in utf8.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func openSocket() -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 { configureNoSigPipe(fd) }
        return fd
    }

    static func configureNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func bindSocket(_ fd: Int32, path: String) -> Bool {
        guard var addr = makeAddress(path: path) else { return false }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func connectSocket(_ fd: Int32, path: String) -> Bool {
        guard var addr = makeAddress(path: path) else { return false }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func encodeLine(_ frame: BridgeWireFrame) -> Data? {
        guard var data = try? JSONEncoder().encode(frame) else { return nil }
        data.append(0x0A)
        return data
    }

    // Returns decoded frames, or nil on EOF, read error, or frame overflow.
    static func readFrames(fd: Int32, buffer: inout Data) -> [BridgeWireFrame]? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { return nil }
        buffer.append(contentsOf: chunk.prefix(count))
        if buffer.count > maxFrameBytes { return nil }
        var frames: [BridgeWireFrame] = []
        let decoder = JSONDecoder()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty, let frame = try? decoder.decode(BridgeWireFrame.self, from: line) {
                frames.append(frame)
            }
        }
        return frames
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

// Serial-queue-guarded AF_UNIX server hosting the Bridge IPC endpoint.
public final class BridgeServer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (UUID, BridgeRequest) async -> BridgeResponse

    private let socketURL: URL
    private let policy: BridgePeerPolicy
    private let onRequest: RequestHandler
    private let onClientCountChanged: @Sendable (Int) -> Void
    private let onClientDisconnected: @Sendable (UUID) -> Void
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.bridge.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [UUID: ClientChannel] = [:]

    private struct ClientChannel {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
    }

    public init(socketURL: URL, policy: BridgePeerPolicy = .production,
                onClientCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
                onClientDisconnected: @escaping @Sendable (UUID) -> Void = { _ in },
                onRequest: @escaping RequestHandler) {
        self.socketURL = socketURL
        self.policy = policy
        self.onClientCountChanged = onClientCountChanged
        self.onClientDisconnected = onClientDisconnected
        self.onRequest = onRequest
    }

    @discardableResult
    public func start() -> Bool {
        queue.sync { startLocked() }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    public func broadcast(_ event: BridgePushEvent) {
        guard let payload = BridgeSocketIO.encodeLine(.event(event)) else { return }
        queue.async { [self] in
            for id in Array(clients.keys) {
                guard let client = clients[id] else { continue }
                if !BridgeSocketIO.writeAll(fd: client.fd, data: payload) {
                    disconnectLocked(id: id)
                }
            }
        }
    }

    private func startLocked() -> Bool {
        guard listenFD < 0 else { return true }
        let directory = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            let desc = error.localizedDescription
            transportLog.error("Bridge server could not create directory: \(desc, privacy: .public)")
            return false
        }
        unlink(socketURL.path)
        let fd = BridgeSocketIO.openSocket()
        guard fd >= 0 else { return false }
        guard BridgeSocketIO.bindSocket(fd, path: socketURL.path),
              chmod(socketURL.path, 0o600) == 0,
              Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            unlink(socketURL.path)
            transportLog.error("Bridge server bind/listen failed, errno \(errno)")
            return false
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingLocked() }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
        return true
    }

    private func stopLocked() {
        for id in Array(clients.keys) { disconnectLocked(id: id) }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
            unlink(socketURL.path)
        }
    }

    private func acceptPendingLocked() {
        guard listenFD >= 0 else { return }
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &len) }
        }
        guard clientFD >= 0 else { return }
        BridgeSocketIO.configureNoSigPipe(clientFD)
        guard BridgePeerSecurity.verifyPeer(socket: clientFD, policy: policy) else {
            Darwin.close(clientFD)
            return
        }
        let id = UUID()
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readClientLocked(id: id) }
        source.setCancelHandler { Darwin.close(clientFD) }
        clients[id] = ClientChannel(fd: clientFD, source: source)
        source.resume()
        onClientCountChanged(clients.count)
    }

    private func readClientLocked(id: UUID) {
        guard var channel = clients[id] else { return }
        guard let frames = BridgeSocketIO.readFrames(fd: channel.fd, buffer: &channel.buffer) else {
            disconnectLocked(id: id)
            return
        }
        clients[id] = channel
        let handler = onRequest
        for case .request(let requestID, let request) in frames {
            Task { [weak self] in
                let response = await handler(id, request)
                guard let data = BridgeSocketIO.encodeLine(.response(id: requestID, response)) else { return }
                self?.sendReply(data, to: id)
            }
        }
    }

    private func sendReply(_ data: Data, to clientID: UUID) {
        queue.async { [self] in
            guard let client = clients[clientID] else { return }
            if !BridgeSocketIO.writeAll(fd: client.fd, data: data) {
                disconnectLocked(id: clientID)
            }
        }
    }

    private func disconnectLocked(id: UUID) {
        guard let removed = clients.removeValue(forKey: id) else { return }
        removed.source.cancel()
        onClientDisconnected(id)
        onClientCountChanged(clients.count)
    }
}
