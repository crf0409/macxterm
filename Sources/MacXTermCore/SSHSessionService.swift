import Foundation
import SSHBridge

// All libssh2 handles belong to this queue. Only its cancellation flag is shared.
final class SSHWorker: @unchecked Sendable {
    let handle: OpaquePointer
    let queue = DispatchQueue(label: "app.macxterm.ssh.\(UUID())", qos: .userInitiated)
    var terminal: UnsafeMutableRawPointer?
    var commands: [UUID: OpaquePointer] = [:]
    init() { handle = mx_create()! }
    deinit { mx_destroy(handle) }
    func error() -> MacXError { .message(String(cString: mx_error(handle))) }
    func run<T: Sendable>(_ body: @escaping @Sendable (SSHWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try body(self) }) }
        }
    }
}
public struct SessionCredentials: Sendable {
    public let secret: String
    public let keyURL: URL?
    public init(secret: String, keyURL: URL? = nil) {
        self.secret = secret
        self.keyURL = keyURL
    }
}
public final class SSHSessionService: Sendable {
    let worker = SSHWorker()
    public init() {}
    public func cancel() { mx_cancel(worker.handle) }
    public func handshake(host: HostProfile) async throws -> ServerIdentity {
        try await worker.run { w in
            guard mx_connect(w.handle, host.hostname, Int32(host.port)) == 0 else { throw w.error() }
            var length = 0
            var type: Int32 = 0
            guard let key = mx_hostkey(w.handle, &length, &type), length > 0 else {
                throw MacXError.message("服务器未提供主机密钥。")
            }
            return ServerIdentity(hostname: host.hostname, port: host.port, key: Data(bytes: key, count: length))
        }
    }
    public func authenticate(host: HostProfile, credentials: SessionCredentials) async throws {
        try await worker.run { w in
            let result: Int32
            switch host.authentication {
            case .password: result = mx_auth_password(w.handle, host.username, credentials.secret)
            case .privateKey:
                guard let url = credentials.keyURL else { throw MacXError.message("私钥授权已失效，请重新选择。") }
                let lease = SecurityScopedResource(url)
                defer { withExtendedLifetime(lease) {} }
                result = mx_auth_key(w.handle, host.username, url.path, credentials.secret)
            }
            guard result == 0 else { throw w.error() }
        }
    }
    public func openTerminal(columns: Int = 100, rows: Int = 30) async throws {
        try await worker.run { w in
            guard let channel = mx_terminal(w.handle, Int32(columns), Int32(rows)) else { throw w.error() }
            w.terminal = channel
        }
    }
    public func readTerminal() async throws -> (Data, Bool) {
        try await worker.run { w in
            guard let c = w.terminal else { throw MacXError.message("终端尚未连接。") }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = mx_read(w.handle, c, &bytes, bytes.count)
            if count == -1 { throw w.error() }
            return (count > 0 ? Data(bytes.prefix(count)) : Data(), mx_eof(c) != 0)
        }
    }
    public func writeTerminal(_ data: Data) async throws {
        try await worker.run { w in
            guard let c = w.terminal else { throw MacXError.message("终端尚未连接。") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = mx_write(w.handle, c, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard n > 0 else { throw w.error() }
                    offset += n
                }
            }
        }
    }
    public func resize(columns: Int, rows: Int) async throws {
        try await worker.run { w in
            if let c = w.terminal, mx_resize(w.handle, c, Int32(max(1, columns)), Int32(max(1, rows))) != 0 {
                throw w.error()
            }
        }
    }
    public func keepalive() async throws {
        try await worker.run { w in if mx_keepalive(w.handle) != 0 { throw w.error() } }
    }
    /// Exec channels share the authenticated SSH transport with the terminal.
    /// Each EAGAIN yields the worker queue so a slow probe cannot block keystrokes.
    public func execute(_ command: String, maximumBytes: Int = 2 * 1024 * 1024, timeout: Duration = .seconds(5))
        async throws -> Data
    {
        let id = UUID()
        do {
            try Task.checkCancellation()
            try await worker.run { w in
                guard w.commands.isEmpty else { throw MacXError.message("此连接已有正在读取的状态命令。") }
                guard let state = mx_command_create() else { throw MacXError.message("无法创建命令通道。") }
                w.commands[id] = state
            }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            var result = Data()
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw MacXError.message("读取服务器状态超时。") }
                let (bytes, done, exitCode) = try await worker.run { w -> (Data, Bool, Int32) in
                    guard let state = w.commands[id] else { throw MacXError.cancelled }
                    let status = mx_command_step(w.handle, state, command)
                    guard status >= 0 else { throw w.error() }
                    guard status == 0, let channel = mx_command_channel(state) else { return (Data(), false, 0) }
                    var buffer = [UInt8](repeating: 0, count: 32768)
                    let count = mx_read(w.handle, channel, &buffer, buffer.count)
                    guard count != -1 else { throw w.error() }
                    return (
                        count > 0 ? Data(buffer.prefix(count)) : Data(), count <= 0 && mx_eof(channel) != 0,
                        mx_exit_status(channel)
                    )
                }
                guard result.count + bytes.count <= maximumBytes else { throw MacXError.message("远端命令输出超出限制。") }
                result.append(bytes)
                if done {
                    guard exitCode == 0 else {
                        throw MacXError.message("远端命令未成功完成：\(String(decoding:result.suffix(2048),as:UTF8.self))")
                    }
                    break
                }
                try await Task.sleep(for: .milliseconds(bytes.isEmpty ? 20 : 1))
            }
            await closeCommand(id, terminate: false)
            return result
        } catch {
            await closeCommand(id, terminate: true)
            throw error
        }
    }
    private func closeCommand(_ id: UUID, terminate: Bool) async {
        // Cleanup must also yield between EAGAIN retries. In particular, a
        // timed-out probe must never monopolize the terminal's transport queue.
        let worker = worker
        let cleanup = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                let done =
                    (try? await worker.run { w in
                        guard let state = w.commands[id] else { return true }
                        if mx_command_free_step(w.handle, state, terminate ? 1 : 0) == 0 {
                            w.commands.removeValue(forKey: id)
                            return true
                        }
                        return false
                    }) ?? true
                if done { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await worker.run { w in
                if let state = w.commands.removeValue(forKey: id) { mx_command_abandon(state) }
            }
        }
        await cleanup.value
    }
    public func openSFTP() async throws -> SFTPService {
        try await worker.run { w in if mx_sftp_start(w.handle) != 0 { throw w.error() } }
        return SFTPService(worker: worker)
    }
}
