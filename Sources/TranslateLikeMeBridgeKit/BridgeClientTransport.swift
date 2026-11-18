import AppKit
import Darwin
import Foundation
import os

private let clientLog = Logger.app("bridge")

// Serial-queue-guarded AF_UNIX client with event-driven directory watch + backoff reconnect.
public final class BridgeConnectionClient: @unchecked Sendable {
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connected(accessibilityTrusted: Bool, version: String)
    }

    private let socketURL: URL
    private let policy: BridgePeerPolicy
    private let onStateChanged: @Sendable (ConnectionState) -> Void
    private let onEvent: @Sendable (BridgePushEvent) -> Void
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.bridge.client")
    private var running = false
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var reconnectTimer: DispatchSourceTimer?
    private var launchObserver: NSObjectProtocol?
    private var buffer = Data()
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<BridgeResponse?, Never>] = [:]
    private var currentState: ConnectionState = .disconnected

    public init(socketURL: URL, policy: BridgePeerPolicy = .production,
                onStateChanged: @escaping @Sendable (ConnectionState) -> Void = { _ in },
                onEvent: @escaping @Sendable (BridgePushEvent) -> Void = { _ in }) {
        self.socketURL = socketURL
        self.policy = policy
        self.onStateChanged = onStateChanged
        self.onEvent = onEvent
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            observeAppLaunchesLocked()
            attemptConnectLocked()
            if fd < 0 { armDiscoveryLocked() }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            disarmDiscoveryLocked()
            if let launchObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
                self.launchObserver = nil
            }
            tearDownConnectionLocked(rearmDiscovery: false)
        }
    }

    public func call(_ request: BridgeRequest, timeout: Duration = .seconds(5)) async -> BridgeResponse? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if fd < 0 && running { attemptConnectLocked() }
                guard fd >= 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let id = nextRequestID
                nextRequestID += 1
                guard let encoded = BridgeSocketIO.encodeLine(.request(id: id, request)) else {
                    continuation.resume(returning: nil)
                    return
                }
                pending[id] = continuation
                if !BridgeSocketIO.writeAll(fd: fd, data: encoded) {
                    tearDownConnectionLocked(rearmDiscovery: running)
                    return
                }
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if let expired = self?.pending.removeValue(forKey: id) {
                        expired.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func observeAppLaunchesLocked() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            guard id == BridgeConfig.bridgeBundleID || id == BridgeConfig.bridgeDevBundleID else { return }
            self?.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self, self.running, self.fd < 0 else { return }
                self.attemptConnectLocked()
                if self.fd < 0 { self.armDiscoveryLocked() }
            }
        }
    }

    private func armDiscoveryLocked() {
        guard running, fd < 0 else { return }
        if directoryWatcher == nil {
            let dirPath = socketURL.deletingLastPathComponent().path
            let dirFD = Darwin.open(dirPath, O_EVTONLY)
            if dirFD >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: dirFD, eventMask: [.write, .rename], queue: queue
                )
                watcher.setEventHandler { [weak self] in self?.attemptConnectLocked() }
                watcher.setCancelHandler { Darwin.close(dirFD) }
                directoryWatcher = watcher
                watcher.resume()
            }
        }
        if reconnectTimer == nil, directoryWatcher == nil {
            // Only when the Group Container directory does not exist yet, check slowly
            // until Bridge creates it, then cancel all timers once connected.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, self.running, self.fd < 0 else { return }
                self.attemptConnectLocked()
                if self.fd < 0 { self.armDiscoveryLocked() }
            }
            reconnectTimer = timer
            timer.resume()
        }
    }

    private func disarmDiscoveryLocked() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    private func attemptConnectLocked() {
        guard fd < 0, FileManager.default.fileExists(atPath: socketURL.path) else { return }
        let sock = BridgeSocketIO.openSocket()
        guard sock >= 0 else { return }
        guard BridgeSocketIO.connectSocket(sock, path: socketURL.path),
              BridgePeerSecurity.verifyPeer(socket: sock, policy: policy, isServerVerifyingClient: false) else {
            Darwin.close(sock)
            return
        }
        disarmDiscoveryLocked()
        fd = sock
        buffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        source.setEventHandler { [weak self] in self?.readServerLocked() }
        source.setCancelHandler { Darwin.close(sock) }
        readSource = source
        source.resume()
        Task { [weak self] in
            guard let self, let reply = await self.call(.hello, timeout: .seconds(2)),
                  case .status(let trusted, let version) = reply else {
                return
            }
            self.queue.async { [weak self] in
                guard let self, self.fd >= 0 else { return }
                self.publishStateLocked(.connected(accessibilityTrusted: trusted, version: version))
            }
        }
    }

    private func readServerLocked() {
        guard fd >= 0 else { return }
        guard let frames = BridgeSocketIO.readFrames(fd: fd, buffer: &buffer) else {
            tearDownConnectionLocked(rearmDiscovery: running)
            return
        }
        for frame in frames {
            switch frame {
            case .response(let id, let response):
                pending.removeValue(forKey: id)?.resume(returning: response)
            case .event(let event):
                if case .statusChanged(let trusted) = event,
                   case .connected(_, let version) = currentState {
                    publishStateLocked(.connected(accessibilityTrusted: trusted, version: version))
                } else {
                    onEvent(event)
                }
            case .request:
                break
            }
        }
    }

    private func tearDownConnectionLocked(rearmDiscovery: Bool) {
        readSource?.cancel()
        readSource = nil
        fd = -1
        buffer.removeAll()
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: nil) }
        publishStateLocked(.disconnected)
        if rearmDiscovery { armDiscoveryLocked() }
    }

    private func publishStateLocked(_ next: ConnectionState) {
        guard currentState != next else { return }
        currentState = next
        clientLog.notice("Bridge client state changed: \(String(describing: next), privacy: .public)")
        onStateChanged(next)
    }
}
