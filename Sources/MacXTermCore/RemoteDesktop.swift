import Foundation

public enum RDPSecurity: String, Codable, CaseIterable, Sendable {
    case tls, negotiate
    public var title: String { self == .tls ? "TLS（XRDP）" : "自动协商（TLS / NLA）" }
}

public struct RemoteDesktopConfiguration: Codable, Hashable, Sendable {
    public var hostname = ""
    public var port = 3389
    public var username = ""
    public var domain = ""
    public var width = 1440
    public var height = 900
    public var security: RDPSecurity = .tls
    public var useSSHTunnel = false
    public var localPort = 13389
    public init() {}
    public func address(for host: HostProfile) -> String {
        hostname.isEmpty ? (useSSHTunnel ? "127.0.0.1" : host.hostname) : hostname
    }
    public func user(for host: HostProfile) -> String { username.isEmpty ? host.username : username }
    public func endpoint(for host: HostProfile) -> String {
        let address = address(for: host)
        return "\(user(for: host))@\(address.contains(":") ? "[\(address)]" : address):\(port)"
    }
    public func validate(for host: HostProfile) throws {
        let address = address(for: host)
        let user = user(for: host)
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            ![address, user, domain].contains(where: { $0.contains(where: { $0.isNewline || $0 == "\0" }) }),
            (1...65535).contains(port)
        else { throw MacXError.message("请填写有效的 RDP 地址、桌面用户名与端口（1–65535）。") }
        guard (640...3840).contains(width), (480...2160).contains(height) else {
            throw MacXError.message("桌面分辨率应为 640×480 至 3840×2160。")
        }
        if useSSHTunnel && (!(1...65535).contains(localPort) || host.connectionType != .ssh) {
            throw MacXError.message("SSH 隧道需要 SSH 主机和有效的本机端口（1–65535）。")
        }
    }
}

/// AppKit virtual key codes mapped to IBM PC scan codes; bit 8 is the extended flag.
public enum RDPKeyboard {
    public static func scanCode(for key: UInt16) -> UInt32? {
        let codes: [UInt16: UInt32] = [
            0:0x1e, 1:0x1f, 2:0x20, 3:0x21, 4:0x23, 5:0x22, 6:0x2c, 7:0x2d,
            8:0x2e, 9:0x2f, 11:0x30, 12:0x10, 13:0x11, 14:0x12, 15:0x13,
            16:0x15, 17:0x14, 18:0x02, 19:0x03, 20:0x04, 21:0x05, 22:0x07,
            23:0x06, 24:0x0d, 25:0x0a, 26:0x08, 27:0x0c, 28:0x09, 29:0x0b,
            30:0x1b, 31:0x18, 32:0x16, 33:0x1a, 34:0x17, 35:0x19, 36:0x1c,
            37:0x26, 38:0x24, 39:0x28, 40:0x25, 41:0x27, 42:0x2b, 43:0x33,
            44:0x35, 45:0x31, 46:0x32, 47:0x34, 48:0x0f, 49:0x39, 50:0x29,
            51:0x0e, 53:0x01, 54:0x15c, 55:0x15b, 56:0x2a, 57:0x3a,
            58:0x38, 59:0x1d, 60:0x36, 61:0x138, 62:0x11d, 65:0x53,
            67:0x37, 69:0x4e, 71:0x45, 75:0x135, 76:0x11c, 78:0x4a,
            82:0x52, 83:0x4f, 84:0x50, 85:0x51, 86:0x4b, 87:0x4c,
            88:0x4d, 89:0x47, 91:0x48, 92:0x49,
            96:0x3f, 97:0x40, 98:0x41, 99:0x3d, 100:0x42, 101:0x43,
            103:0x57, 109:0x44, 111:0x58, 114:0x152, 115:0x147, 116:0x149,
            117:0x153, 118:0x3e, 119:0x14f, 120:0x3c, 121:0x151, 122:0x3b,
            123:0x14b, 124:0x14d, 125:0x150, 126:0x148,
        ]
        return codes[key]
    }
}
