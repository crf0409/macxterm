import AppKit
import MacXTermCore
import Observation

@MainActor @Observable final class RemoteDesktopSession: Identifiable {
    @ObservationIgnored var focusInput: (() -> Void)?
    let id = UUID()
    var host: HostProfile
    var state: ConnectionState = .disconnected
    var status = ""
    var image: CGImage?
    var desktopSize = CGSize.zero
    @ObservationIgnored private var service: RDPService?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var password = ""
    @ObservationIgnored private var tunnelTask: Task<Void, Never>?
    @ObservationIgnored private var tunnelConnection: SSHSessionService?
    @ObservationIgnored private var authenticateSSH: (@MainActor (HostProfile, SSHSessionService) async throws -> Void)?
    var displayEndpoint: String {
        let endpoint = host.remoteDesktop.endpoint(for: host)
        return host.remoteDesktop.useSSHTunnel ? "\(endpoint) · SSH \(host.hostname):\(host.port)" : endpoint
    }
    init(host: HostProfile, authenticateSSH: (@MainActor (HostProfile, SSHSessionService) async throws -> Void)? = nil) {
        self.host = host; self.authenticateSSH = authenticateSSH
    }
    func connect(password: String? = nil) {
        disconnect()
        if let password { self.password = password }
        else if self.password.isEmpty {
            let alert = NSAlert()
            alert.messageText = "输入远程桌面密码"
            alert.informativeText = host.remoteDesktop.endpoint(for: host) + "\n使用桌面账号的密码。密码仅保留在当前标签页的内存中。"
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "连接")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.password = field.stringValue
        }
        state = .connecting
        status = "正在连接桌面 \(host.remoteDesktop.endpoint(for: host))…"
        image = nil
        let token = generation
        if host.remoteDesktop.useSSHTunnel {
            guard let authenticateSSH else { state = .failed; status = "无法建立 SSH 隧道"; return }
            let connection = SSHSessionService()
            tunnelConnection = connection
            status = "正在建立 SSH 安全隧道…"
            var rule = TunnelRule(hostID: host.id)
            rule.bindPort = host.remoteDesktop.localPort
            rule.targetHost = host.remoteDesktop.address(for: host)
            rule.targetPort = host.remoteDesktop.port
            let desktopRule = rule
            tunnelTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await authenticateSSH(host, connection)
                    try Task.checkCancellation()
                    try await TunnelService(session: connection).run(desktopRule, onReady: { [weak self] port in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            var destination = self.host
                            destination.remoteDesktop.hostname = "127.0.0.1"
                            destination.remoteDesktop.port = port
                            self.startRDP(destination, token: token)
                        }
                    }, onClientError: { [weak self] text in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.status = "SSH 隧道转发失败：\(text)"
                        }
                    })
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    service?.cancel(); frameTask?.cancel()
                    state = .failed; status = "SSH 隧道启动失败：\(error.localizedDescription)"
                }
            }
        } else { startRDP(host, token: token) }
    }
    private func startRDP(_ destination: HostProfile, token: UUID) {
        let service = RDPService()
        self.service = service
        do { try service.start(host: destination, password: self.password) } catch {
            tunnelTask?.cancel(); tunnelConnection?.cancel()
            state = .failed
            status = error.localizedDescription
            return
        }
        eventTask = Task { [weak self] in
            for await event in service.events {
                guard let self, !Task.isCancelled, generation == token else {
                    if case .certificate(let request) = event { request.respond(trust: false) }
                    break
                }
                switch event {
                case .connected:
                    state = .connected
                    status = "RDP 已连接 · \(displayEndpoint)"
                case .disconnected(let text): state = .disconnected; status = text
                case .failed(let text): state = .failed; status = text
                case .certificate(let request):
                    let alert = NSAlert()
                    alert.messageText = "核对远程桌面证书"
                    alert.informativeText = "\(request.host)\n\n主题：\(request.subject)\n签发者：\(request.issuer)\n指纹：\(request.fingerprint)\n\n证书未通过自动验证，请通过可信渠道核对。信任仅对本次连接有效。"
                    alert.addButton(withTitle: "信任并连接")
                    alert.addButton(withTitle: "取消")
                    request.respond(trust: alert.runModal() == .alertFirstButtonReturn)
                }
            }
            guard let self, generation == token, !Task.isCancelled else { return }
            frameTask?.cancel()
            tunnelTask?.cancel(); tunnelConnection?.cancel()
            if state == .connected || state == .connecting {
                state = .disconnected
                status = "桌面连接已结束"
            }
        }
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == token else { break }
                if let frame = service.takeFrame(),
                    let provider = CGDataProvider(data: frame.data as CFData),
                    let image = CGImage(width: frame.width, height: frame.height,
                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                {
                    self.image = image
                    desktopSize = CGSize(width: frame.width, height: frame.height)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
    func disconnect() {
        generation = UUID()
        eventTask?.cancel(); frameTask?.cancel()
        tunnelTask?.cancel(); tunnelConnection?.cancel(); tunnelConnection = nil
        service?.cancel(); service = nil
        state = .disconnected
        status = "桌面连接已关闭"
    }
    func discardPassword() { password = "" }
    func mouse(flags: UInt16, x: UInt16, y: UInt16) {
        guard state == .connected else { return }
        service?.mouse(flags: flags, x: x, y: y)
    }
    func key(scanCode: UInt32, down: Bool) {
        guard state == .connected else { return }
        service?.key(scanCode: scanCode, down: down)
    }
    func sendText(_ text: String) {
        guard state == .connected else { return }
        do { try service?.sendText(text) } catch { status = error.localizedDescription }
    }
    func sendControlAltDelete() {
        for code: UInt32 in [0x1d, 0x38, 0x153] { key(scanCode: code, down: true) }
        for code: UInt32 in [0x153, 0x38, 0x1d] { key(scanCode: code, down: false) }
    }
}
