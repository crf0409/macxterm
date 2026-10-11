import Darwin
import Foundation
import SSHBridge

public final class TunnelService: Sendable {
    private let session: SSHSessionService
    public init(session: SSHSessionService) { self.session = session }
    public func stop() { session.cancel() }
    public func run(
        _ rule: TunnelRule, onReady: @escaping @Sendable (Int) -> Void,
        onClientError: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        try rule.validate()
        let pump = TunnelPump(worker: session.worker, rule: rule, onClientError: onClientError)
        do {
            let port = try await session.worker.run { _ in try pump.start() }
            onReady(port)
            while !Task.isCancelled {
                try await session.worker.run { _ in try pump.tick() }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            _ = try? await session.worker.run { _ in pump.close() }
            session.cancel()
            throw error
        }
        _ = try? await session.worker.run { _ in pump.close() }
        session.cancel()
    }
}
private final class TunnelPump: @unchecked Sendable {
    private final class Pipe {
        let fd: Int32
        var channel: UnsafeMutableRawPointer?
        var parser = SOCKS5Parser()
        var toRemote = Data(), toLocal = Data()
        var localEOF = false, remoteEOF = false, sentEOF = false, sentShutdown = false
        var reject = false
        let created = Date()
        init(fd: Int32, channel: UnsafeMutableRawPointer? = nil) {
            self.fd = fd
            self.channel = channel
        }
    }
    let worker: SSHWorker
    let rule: TunnelRule
    let onClientError: @Sendable (String) -> Void
    var listener: Int32 = -1
    var remoteListener: UnsafeMutableRawPointer?
    private var pipes = [Pipe]()
    var lastKeepalive = Date()
    init(worker: SSHWorker, rule: TunnelRule, onClientError: @escaping @Sendable (String) -> Void) {
        self.worker = worker
        self.rule = rule
        self.onClientError = onClientError
    }
    func start() throws -> Int {
        var bound: Int32 = 0
        if rule.kind == .remote {
            guard let r = mx_forward_listen(worker.handle, rule.bindHost, Int32(rule.bindPort), &bound) else {
                throw worker.error()
            }
            remoteListener = r
        } else {
            listener = mx_socket_listen(rule.bindHost, Int32(rule.bindPort), &bound)
            guard listener >= 0 else {
                throw MacXError.message("无法监听 \(rule.bindHost):\(rule.bindPort)：\(String(cString:strerror(errno)))")
            }
        }
        return Int(bound)
    }
    func tick() throws {
        if Date().timeIntervalSince(lastKeepalive) > 15 {
            guard mx_keepalive(worker.handle) == 0 else { throw worker.error() }
            lastKeepalive = Date()
        }
        if pipes.count < 128 {
            if let remoteListener, let channel = mx_forward_accept(worker.handle, remoteListener) {
                let fd = mx_socket_connect(rule.targetHost, Int32(rule.targetPort))
                if fd < 0 {
                    mx_channel_free(worker.handle, channel)
                    onClientError("本地目标不可达：\(rule.targetHost):\(rule.targetPort)")
                } else {
                    pipes.append(Pipe(fd: fd, channel: channel))
                }
            } else if listener >= 0 {
                let fd = mx_socket_accept(listener)
                if fd >= 0 {
                    if rule.kind == .socks5 {
                        pipes.append(Pipe(fd: fd))
                    } else if let c = mx_direct(worker.handle, rule.targetHost, Int32(rule.targetPort)) {
                        pipes.append(Pipe(fd: fd, channel: c))
                    } else {
                        mx_socket_close(fd)
                        onClientError(worker.error().localizedDescription)
                    }
                }
            }
        }
        var keep = [Pipe]()
        for pipe in pipes {
            do { if try tick(pipe) { keep.append(pipe) } else { close(pipe) } } catch {
                onClientError(error.localizedDescription)
                close(pipe)
            }
        }
        pipes = keep
    }
    private func tick(_ pipe: Pipe) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32768)
        if !pipe.localEOF && !pipe.reject && pipe.toRemote.count < 1024 * 1024 {
            let n = mx_socket_read(pipe.fd, &bytes, bytes.count)
            if n == -1 { return false }
            if n == 0 { pipe.localEOF = true }
            if n > 0 {
                let data = Data(bytes.prefix(n))
                if pipe.channel == nil {
                    for event in try pipe.parser.receive(data) {
                        switch event {
                        case .reply(let response): pipe.toLocal.append(response)
                        case .reject(let response):
                            pipe.toLocal.append(response)
                            pipe.reject = true
                        case .connect(let host, let port):
                            if let c = mx_direct(worker.handle, host, Int32(port)) {
                                pipe.channel = c
                                pipe.toLocal.append(SOCKS5Parser.response(0))
                                pipe.toRemote.append(pipe.parser.takeRemainder())
                            } else {
                                pipe.toLocal.append(SOCKS5Parser.response(5))
                                pipe.reject = true
                                onClientError(worker.error().localizedDescription)
                            }
                        }
                    }
                } else {
                    pipe.toRemote.append(data)
                }
            }
        }
        if let channel = pipe.channel {
            if !pipe.toRemote.isEmpty {
                let n = pipe.toRemote.withUnsafeBytes { mx_write(worker.handle, channel, $0.baseAddress, $0.count) }
                if n < 0 { throw worker.error() }
                if n > 0 { pipe.toRemote.removeFirst(n) }
            }
            if pipe.localEOF && pipe.toRemote.isEmpty && !pipe.sentEOF {
                guard mx_send_eof(worker.handle, channel) == 0 else { throw worker.error() }
                pipe.sentEOF = true
            }
            if !pipe.remoteEOF && pipe.toLocal.count < 1024 * 1024 {
                let n = mx_read(worker.handle, channel, &bytes, bytes.count)
                if n == -1 { throw worker.error() }
                if n > 0 { pipe.toLocal.append(contentsOf: bytes.prefix(n)) }
                if mx_eof(channel) != 0 { pipe.remoteEOF = true }
            }
        } else if pipe.localEOF || Date().timeIntervalSince(pipe.created) > 15 {
            return false
        }
        if !pipe.toLocal.isEmpty {
            let n = pipe.toLocal.withUnsafeBytes { mx_socket_write(pipe.fd, $0.baseAddress, $0.count) }
            if n == -1 { return false }
            if n > 0 { pipe.toLocal.removeFirst(n) }
        }
        if pipe.reject && pipe.toLocal.isEmpty { return false }
        if pipe.remoteEOF && pipe.toLocal.isEmpty && !pipe.sentShutdown {
            mx_socket_shutdown_write(pipe.fd)
            pipe.sentShutdown = true
        }
        return !(pipe.localEOF && pipe.remoteEOF && pipe.toLocal.isEmpty && pipe.toRemote.isEmpty)
    }
    private func close(_ pipe: Pipe) {
        mx_socket_close(pipe.fd)
        if let c = pipe.channel {
            mx_channel_free(worker.handle, c)
            pipe.channel = nil
        }
    }
    func close() {
        for pipe in pipes { close(pipe) }
        pipes = []
        if listener >= 0 {
            mx_socket_close(listener)
            listener = -1
        }
        if let l = remoteListener {
            mx_forward_cancel(worker.handle, l)
            remoteListener = nil
        }
    }
}
