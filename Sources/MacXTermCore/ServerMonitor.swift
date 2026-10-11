import Foundation

public struct DiskUsage: Identifiable, Sendable {
    public let device: String
    public let mount: String
    public let total: Double
    public let used: Double
    public let available: Double
    public let usedPercent: Double
    public var id: String { device + ":" + mount }
}
public struct NetworkCounter: Sendable {
    public let received: Double
    public let sent: Double
}
public struct NetworkRate: Identifiable, Sendable {
    public let name: String
    public let received: Double?
    public let sent: Double?
    public var id: String { name }
}
public struct ServerSample: Sendable {
    public let date: Date
    public let hostname: String
    public let kernel: String
    public let cpuModel: String
    public let cores: Int
    public let cpuTotal: Double
    public let cpuIdle: Double
    public let uptime: Double
    public let load: [Double]
    public let memoryTotal: Double
    public let memoryAvailable: Double
    public let swapTotal: Double
    public let swapFree: Double
    public let disks: [DiskUsage]
    public let network: [String: NetworkCounter]
    public let defaultInterface: String?
    public var memoryUsed: Double { max(0, memoryTotal - memoryAvailable) }
    public var memoryPercent: Double { memoryTotal > 0 ? memoryUsed / memoryTotal * 100 : 0 }
}
public struct ServerMetrics: Identifiable, Sendable {
    public let sample: ServerSample
    public let cpuPercent: Double?
    public let interfaces: [NetworkRate]
    public let segment: Int
    public var id: Date { sample.date }
    public init(sample: ServerSample, previous: ServerSample?, segment: Int = 0) {
        self.sample = sample
        self.segment = segment
        if let previous, sample.uptime > previous.uptime, sample.cpuTotal > previous.cpuTotal,
            sample.cpuIdle >= previous.cpuIdle
        {
            cpuPercent = max(
                0, min(100, (1 - (sample.cpuIdle - previous.cpuIdle) / (sample.cpuTotal - previous.cpuTotal)) * 100))
        } else {
            cpuPercent = nil
        }
        interfaces = sample.network.keys.sorted().map { name in
            let current = sample.network[name]!
            if let previous, let old = previous.network[name], sample.uptime > previous.uptime,
                current.received >= old.received, current.sent >= old.sent
            {
                return NetworkRate(
                    name: name, received: (current.received - old.received) / (sample.uptime - previous.uptime),
                    sent: (current.sent - old.sent) / (sample.uptime - previous.uptime))
            }
            return NetworkRate(name: name, received: nil, sent: nil)
        }
    }
}

public enum ServerMonitor {
    // Fast probes use POSIX shell builtins only; static facts and df run separately.
    // There is no installed agent and no command touches the interactive shell.
    private static let metadataProbe = #"""
        export LC_ALL=C
        if [ ! -r /proc/stat ] || [ ! -r /proc/meminfo ]; then
            printf 'Server monitoring currently requires Linux /proc.\n'; exit 78
        fi
        printf '__MXT_ID__\n'; hostname; uname -sr
        printf '__MXT_MODEL__\n'; awk -F ': *' '/model name|Hardware/ {print $2; exit}' /proc/cpuinfo
        printf '__MXT_CORES__\n'; getconf _NPROCESSORS_ONLN
        """#
    private static let fastProbe = #"""
        export LC_ALL=C
        printf '__MXT_STAT__\n'; IFS= read -r line < /proc/stat; printf '%s\n' "$line"
        printf '__MXT_MEM__\n'
        while IFS= read -r line; do
            case "$line" in
                MemTotal:*|MemAvailable:*|MemFree:*|Buffers:*|Cached:*|SReclaimable:*|Shmem:*|SwapTotal:*|SwapFree:*) printf '%s\n' "$line";;
            esac
        done < /proc/meminfo
        printf '__MXT_UPTIME__\n'; IFS= read -r line < /proc/uptime; printf '%s\n' "$line"
        printf '__MXT_LOAD__\n'; IFS= read -r line < /proc/loadavg; printf '%s\n' "$line"
        printf '__MXT_NET__\n'; while IFS= read -r line; do printf '%s\n' "$line"; done < /proc/net/dev
        printf '__MXT_ROUTE__\n'; while IFS= read -r line; do printf '%s\n' "$line"; done < /proc/net/route
        """#
    private static let diskProbe = #"""
        export LC_ALL=C
        printf '__MXT_DISK__\n'
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 df -Pk -x tmpfs -x devtmpfs -x squashfs 2>/dev/null
        else
            df -Pk -x tmpfs -x devtmpfs -x squashfs 2>/dev/null
        fi
        """#
    private static func shell(_ text: String) -> String {
        "exec sh -c '" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    public static var command: String { shell(metadataProbe + "\n" + fastProbe + "\n" + diskProbe) }
    public static var metadataCommand: String { shell(metadataProbe) }
    public static var fastCommand: String { shell(fastProbe) }
    public static var diskCommand: String { shell(diskProbe) }
    public static func fetch(using session: SSHSessionService) async throws -> ServerSample {
        let data = try await session.execute(command)
        return try parse(String(decoding: data, as: UTF8.self))
    }
    public static func parse(_ text: String, date: Date = Date()) throws -> ServerSample {
        var sections = [String: [String]]()
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("__MXT_"), line.hasSuffix("__") {
                current = line
                sections[current] = []
            } else {
                sections[current, default: []].append(line)
            }
        }
        func lines(_ key: String) -> [String] { sections["__MXT_\(key)__"] ?? [] }
        func numbers(_ line: String) -> [Double] {
            line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        }
        let stat = lines("STAT")
        guard let cpuLine = stat.first(where: { $0.hasPrefix("cpu ") }) else {
            throw MacXError.message("无法读取 CPU 状态；服务器状态面板目前支持 Linux /proc。")
        }
        let cpu = numbers(cpuLine)
        guard cpu.count >= 4, cpu.allSatisfy({ $0.isFinite && $0 >= 0 }), cpu.prefix(8).reduce(0, +).isFinite,
            let uptime = lines("UPTIME").first.flatMap({ numbers($0).first }), uptime.isFinite, uptime >= 0
        else { throw MacXError.message("服务器返回了无效的系统状态。") }
        var memory = [String: Double]()
        for line in lines("MEM") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, let value = Double(fields[1]), value.isFinite, value >= 0 {
                memory[String(fields[0].dropLast())] = value * 1024
            }
        }
        guard let total = memory["MemTotal"], total > 0 else { throw MacXError.message("无法读取服务器内存状态。") }
        let available =
            memory["MemAvailable"]
            ?? ((memory["MemFree"] ?? 0) + (memory["Buffers"] ?? 0) + (memory["Cached"] ?? 0)
                + (memory["SReclaimable"] ?? 0) - (memory["Shmem"] ?? 0))
        var network = [String: NetworkCounter]()
        for line in lines("NET") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            let counts = numbers(String(pair[1]))
            if name != "lo", counts.count >= 16, counts[0].isFinite, counts[8].isFinite {
                network[name] = NetworkCounter(received: counts[0], sent: counts[8])
            }
        }
        var disks = [DiskUsage]()
        for line in lines("DISK") {
            let fields = line.split(maxSplits: 5, whereSeparator: \.isWhitespace)
            guard fields.count == 6, let capacity = Double(fields[1]), let used = Double(fields[2]),
                let free = Double(fields[3]), let percent = Double(fields[4].replacingOccurrences(of: "%", with: "")),
                capacity > 0, capacity.isFinite
            else { continue }
            disks.append(
                DiskUsage(
                    device: String(fields[0]), mount: String(fields[5]), total: capacity * 1024, used: used * 1024,
                    available: free * 1024, usedPercent: percent))
        }
        let defaultInterface = lines("ROUTE").compactMap { line -> (String, Int)? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 8, parts[1] == "00000000", let flags = Int(parts[3], radix: 16), flags & 1 == 1,
                let metric = Int(parts[6])
            else { return nil }
            return (String(parts[0]), metric)
        }.sorted { $0.1 < $1.1 }.first?.0
        let cores =
            lines("CORES").first.flatMap(Int.init)
            ?? stat.filter { $0.hasPrefix("cpu") && $0.dropFirst(3).first?.isNumber == true }.count
        let identity = lines("ID")
        return ServerSample(
            date: date, hostname: identity.first ?? "", kernel: identity.dropFirst().first ?? "",
            cpuModel: lines("MODEL").first ?? "", cores: max(1, cores), cpuTotal: cpu.prefix(8).reduce(0, +),
            cpuIdle: cpu[3] + (cpu.count > 4 ? cpu[4] : 0), uptime: uptime,
            load: Array(numbers(lines("LOAD").first ?? "").prefix(3)), memoryTotal: total,
            memoryAvailable: min(total, max(0, available)), swapTotal: memory["SwapTotal"] ?? 0,
            swapFree: memory["SwapFree"] ?? 0, disks: disks, network: network, defaultInterface: defaultInterface)
    }
}

/// One cache per observed SSH session. Disk probes are rate-limited independently.
public actor ServerSampler {
    private var metadata: String?
    private var disks = ""
    private var diskReadAt = Date.distantPast
    public private(set) var diskWarning = ""
    public init() {}
    public func sample(using session: SSHSessionService) async throws -> ServerSample {
        if metadata == nil {
            metadata = String(
                decoding: try await session.execute(ServerMonitor.metadataCommand, maximumBytes: 16384), as: UTF8.self)
        }
        if Date().timeIntervalSince(diskReadAt) >= 30 {
            diskReadAt = Date()
            do {
                disks = String(
                    decoding: try await session.execute(ServerMonitor.diskCommand, maximumBytes: 256 * 1024),
                    as: UTF8.self)
                diskWarning = ""
            } catch {
                try Task.checkCancellation()
                diskWarning = "磁盘采样失败，保留上次结果：" + error.localizedDescription
            }
        }
        let fast = String(
            decoding: try await session.execute(ServerMonitor.fastCommand, maximumBytes: 256 * 1024), as: UTF8.self)
        return try ServerMonitor.parse((metadata ?? "") + "\n" + fast + "\n" + disks)
    }
}
