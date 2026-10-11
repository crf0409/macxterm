import Foundation
import RDPBridge

public struct RDPFrame: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let stride: Int
}

public final class RDPCertificateRequest: @unchecked Sendable {
    public let host: String
    public let subject: String
    public let issuer: String
    public let fingerprint: String
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var answer: Bool?
    init(host: String, subject: String, issuer: String, fingerprint: String) {
        self.host = host; self.subject = subject; self.issuer = issuer; self.fingerprint = fingerprint
    }
    public func respond(trust: Bool) {
        lock.withLock {
            guard answer == nil else { return }
            answer = trust
            semaphore.signal()
        }
    }
    fileprivate func wait(service: RDPService) -> Bool {
        while !service.isCancelled {
            if semaphore.wait(timeout: .now() + 0.1) == .success {
                return lock.withLock { answer ?? false }
            }
        }
        return false
    }
}

public enum RDPEvent: Sendable {
    case connected
    case disconnected(String)
    case failed(String)
    case certificate(RDPCertificateRequest)
}

/// One worker owns FreeRDP protocol state. The C bridge queues input and copies frames under a mutex.
public final class RDPService: @unchecked Sendable {
    public let events: AsyncStream<RDPEvent>
    private let continuation: AsyncStream<RDPEvent>.Continuation
    private let queue = DispatchQueue(label: "MacXTerm.RDP", qos: .userInitiated)
    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private var cancelled = false
    private var started = false
    public static var engineVersion: String { String(cString: mxrdp_version()) }
    public init() {
        let stream = AsyncStream<RDPEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func start(host: HostProfile, password: String) throws {
        try host.remoteDesktop.validate(for: host)
        try lock.withLock {
            guard !started, !cancelled else { throw MacXError.message("请为每次桌面连接创建独立会话。") }
            started = true
            let config = host.remoteDesktop
            pointer = mxrdp_new(config.address(for: host), Int32(config.port), config.user(for: host), password,
                config.domain, Int32(config.width), Int32(config.height), config.security == .negotiate ? 1 : 0,
                Unmanaged.passUnretained(self).toOpaque(), { user, state, message in
                    guard let user else { return }
                    let service = Unmanaged<RDPService>.fromOpaque(user).takeUnretainedValue()
                    let text = message.map { String(cString: $0) } ?? "RDP 会话已结束"
                    switch state {
                    case 1: service.continuation.yield(.connected)
                    case 2: service.continuation.yield(.failed(text))
                    default: service.continuation.yield(.disconnected(text))
                    }
                }, { user, host, subject, issuer, fingerprint in
                    guard let user else { return 0 }
                    let service = Unmanaged<RDPService>.fromOpaque(user).takeUnretainedValue()
                    let request = RDPCertificateRequest(
                        host: host.map { String(cString: $0) } ?? "",
                        subject: subject.map { String(cString: $0) } ?? "",
                        issuer: issuer.map { String(cString: $0) } ?? "",
                        fingerprint: fingerprint.map { String(cString: $0) } ?? "")
                    service.continuation.yield(.certificate(request))
                    return request.wait(service: service) ? 1 : 0
                })
            guard pointer != nil else { throw MacXError.message("无法初始化 RDP 桌面引擎。") }
        }
        queue.async { [self] in
            // The worker retains the service through teardown, including during cancellation.
            let session = lock.withLock { pointer }
            if let session { mxrdp_run(session) }
            lock.withLock {
                if let pointer { mxrdp_free(pointer) }
                pointer = nil
                cancelled = true
            }
            continuation.finish()
        }
    }
    public func cancel() {
        lock.withLock {
            cancelled = true
            if let pointer { mxrdp_stop(pointer) }
        }
    }
    public func takeFrame() -> RDPFrame? {
        lock.withLock {
            guard let pointer, !cancelled else { return nil }
            var width: Int32 = 0, height: Int32 = 0, stride: Int32 = 0
            var size = 0
            guard let bytes = mxrdp_copy_frame(pointer, &width, &height, &stride, &size) else { return nil }
            return RDPFrame(data: Data(bytesNoCopy: bytes, count: size, deallocator: .free),
                width: Int(width), height: Int(height), stride: Int(stride))
        }
    }
    public func mouse(flags: UInt16, x: UInt16, y: UInt16) {
        lock.withLock { if let pointer, !cancelled { _ = mxrdp_mouse(pointer, flags, x, y) } }
    }
    public func key(scanCode: UInt32, down: Bool) {
        lock.withLock { if let pointer, !cancelled { _ = mxrdp_key(pointer, scanCode, down ? 1 : 0) } }
    }
    /// Unicode typing, including committed IME input. Large pastes are bounded to protect the input queue.
    public func sendText(_ text: String) throws {
        let units = Array(text.utf16)
        guard units.count <= 2000 else { throw MacXError.message("每次最多发送 2000 个 UTF-16 字符，请分段发送。") }
        try lock.withLock {
            guard let pointer, !cancelled else { throw MacXError.message("桌面尚未连接。") }
            for unit in units {
                guard mxrdp_unicode(pointer, unit) != 0 else { throw MacXError.message("键盘输入队列已满，请稍后重试。") }
            }
        }
    }
    deinit { continuation.finish() }
}
