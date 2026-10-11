import Darwin
import Foundation

public struct SOCKS5Parser: Sendable {
    public enum Event: Equatable, Sendable {
        case reply(Data)
        case connect(String, Int)
        case reject(Data)
    }
    private enum Stage: Sendable { case greeting, request, finished }
    private var stage: Stage = .greeting
    private var buffer = Data()
    public init() {}
    public mutating func receive(_ data: Data) throws -> [Event] {
        buffer.append(data)
        guard buffer.count <= 65536 else { throw MacXError.message("SOCKS5 请求过大。") }
        var events = [Event]()
        if stage == .greeting {
            guard buffer.count >= 2 else { return events }
            guard buffer[0] == 5 else { throw MacXError.message("仅支持 SOCKS5。") }
            let count = Int(buffer[1])
            guard buffer.count >= count + 2 else { return events }
            guard count > 0, buffer[2..<count + 2].contains(0) else {
                stage = .finished
                return [.reject(Data([5, 255]))]
            }
            buffer = Data(buffer.dropFirst(count + 2))
            stage = .request
            events.append(.reply(Data([5, 0])))
        }
        if stage == .request {
            guard buffer.count >= 4 else { return events }
            guard buffer[0] == 5, buffer[1] == 1, buffer[2] == 0 else {
                stage = .finished
                events.append(.reject(Self.response(7)))
                return events
            }
            let type = buffer[3]
            let host: String
            let end: Int
            switch type {
            case 1:
                guard buffer.count >= 10 else { return events }
                host = buffer[4..<8].map(String.init).joined(separator: ".")
                end = 8
            case 3:
                guard buffer.count >= 5 else { return events }
                let count = Int(buffer[4])
                guard count > 0 else { throw MacXError.message("SOCKS5 域名为空。") }
                guard buffer.count >= 7 + count else { return events }
                guard let name = String(data: buffer[5..<5 + count], encoding: .utf8), !name.contains("\0") else {
                    throw MacXError.message("SOCKS5 域名无效。")
                }
                host = name
                end = 5 + count
            case 4:
                guard buffer.count >= 22 else { return events }
                var address = Array(buffer[4..<20])
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else {
                    throw MacXError.message("IPv6 地址无效。")
                }
                host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                end = 20
            default:
                stage = .finished
                events.append(.reject(Self.response(8)))
                return events
            }
            let port = Int(buffer[end]) * 256 + Int(buffer[end + 1])
            guard port > 0 else { throw MacXError.message("SOCKS5 目标端口无效。") }
            buffer = Data(buffer.dropFirst(end + 2))
            stage = .finished
            events.append(.connect(host, port))
        }
        return events
    }
    public mutating func takeRemainder() -> Data {
        let data = buffer
        buffer.removeAll()
        return data
    }
    public static func response(_ code: UInt8) -> Data { Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]) }
}
