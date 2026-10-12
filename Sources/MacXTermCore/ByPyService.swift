import CryptoKit
import Foundation

public final class ByPyEventParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var result: ByPyResponse?
    private let progress: TransferProgress
    public init(progress: @escaping TransferProgress = { _, _ in }) { self.progress = progress }
    public func receive(_ data: Data) {
        lock.lock()
        pending.append(data)
        var events = [ByPyEvent]()
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            if let event = try? JSONDecoder().decode(ByPyEvent.self, from: line) {
                if event.kind == "result" { result = event.result }
                else if event.kind == "progress" { events.append(event) }
            }
            pending.removeSubrange(...newline)
        }
        if pending.count > 16 * 1024 * 1024 { pending.removeAll() }
        lock.unlock()
        for event in events { progress(event.completed ?? 0, event.total ?? 0) }
    }
    public func response() throws -> ByPyResponse {
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw MacXError.message("bypy 未返回有效结果，请检查运行环境。") }
        return result
    }
}

private final class ByPyProcessOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
    func run(root: URL, input: Data, parser: ByPyEventParser) throws -> ByPyResponse {
        let output = Pipe(); let standardInput = Pipe()
        process.executableURL = root.appendingPathComponent("python/bin/python3")
        process.arguments = ["-I", "-B", "-X", "utf8", "-u", root.appendingPathComponent("bridge.py").path]
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUTF8": "1",
            "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        process.standardOutput = output; process.standardError = output; process.standardInput = standardInput
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        defer { if process.isRunning { process.terminate() } }
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        while true {
            let data = output.fileHandleForReading.readData(ofLength: 16384)
            if data.isEmpty { break }
            parser.receive(data)
        }
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw MacXError.message("bypy 运行环境退出（\(process.terminationStatus)）。") }
        return try parser.response()
    }
}

public struct ByPyRuntime: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func run(_ request: ByPyRequest, progress: @escaping TransferProgress = { _, _ in }) async throws -> ByPyResponse {
        var data = try JSONEncoder().encode(request); data.append(10)
        let input = data
        let operation = ByPyProcessOperation()
        let parser = ByPyEventParser(progress: progress)
        return try await withTaskCancellationHandler {
            try await Task.detached { try operation.run(root: root, input: input, parser: parser) }.value
        } onCancel: { operation.cancel() }
    }

    /// Install only project-owned helper files, without requiring pip or changing server Python.
    public func prepareServer(_ connection: SSHSessionService, installationDirectory: String? = nil) async throws -> String {
        let homeData = try await connection.execute("python3 -c 'import json,os,sys; assert sys.version_info >= (3,9), \"Python 3.9+ required\"; print(json.dumps(os.path.expanduser(\"~/.local/share/macxterm/bypy\")))'", timeout: .seconds(15))
        let directory = try installationDirectory ?? JSONDecoder().decode(String.self, from: homeData)
        let archive = root.appendingPathComponent("packages.zip")
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let bridge = root.appendingPathComponent("bridge.py")
        let bridgeDigest = SHA256.hash(data: try Data(contentsOf: bridge)).map { String(format: "%02x", $0) }.joined()
        let versionDirectory = directory + "/runtime-" + String(digest.prefix(16)) + "-" + String(bridgeDigest.prefix(12))
        let quoted = ByPyPath.quote(versionDirectory)
        let check = try await connection.execute("test -f \(quoted)/ready && printf yes || printf no")
        if String(decoding: check, as: UTF8.self) != "yes" {
            _ = try await connection.execute("umask 077; mkdir -p \(quoted)")
            let sftp = try await connection.openSFTP()
            try await sftp.upload(archive, to: versionDirectory + "/packages.zip", policy: .replace)
            try await sftp.upload(bridge, to: versionDirectory + "/bridge.py", policy: .replace)
            let installer = "import hashlib,pathlib,zipfile; p=pathlib.Path(\(String(reflecting: versionDirectory))); z=p/'packages.zip'; assert hashlib.sha256(z.read_bytes()).hexdigest()==\(String(reflecting: digest)); a=zipfile.ZipFile(z); assert all(not n.startswith('/') and '..' not in pathlib.PurePosixPath(n).parts for n in a.namelist()); a.extractall(p/'packages'); (p/'ready').write_text('1')"
            _ = try await connection.execute("umask 077; python3 -c " + ByPyPath.quote(installer), timeout: .seconds(60))
        }
        let launcher = "#!/bin/sh\nexec python3 -I -B -X utf8 -u " + ByPyPath.quote(versionDirectory + "/bridge.py") + " \"$@\"\n"
        let makeLauncher = "import pathlib; p=pathlib.Path(\(String(reflecting: versionDirectory + "/bypy"))); p.write_text(\(String(reflecting: launcher))); p.chmod(0o700)"
        _ = try await connection.execute("python3 -c " + ByPyPath.quote(makeLauncher))
        return versionDirectory
    }
    public func runOnServer(_ request: ByPyRequest, directory: String, connection: SSHSessionService,
        progress: @escaping TransferProgress = { _, _ in }) async throws -> ByPyResponse {
        var request = request
        request.persistToken = true
        request.token = nil
        request.configDirectory = (directory as NSString).deletingLastPathComponent + "/account"
        var input = try JSONEncoder().encode(request); input.append(10)
        let parser = ByPyEventParser(progress: progress)
        _ = try await connection.execute("python3 -I -B -X utf8 -u " + ByPyPath.quote(directory + "/bridge.py"),
            maximumBytes: 64 * 1024 * 1024, timeout: .seconds(7 * 24 * 60 * 60), standardInput: input,
            onOutput: { parser.receive($0) }, collectOutput: false)
        return try parser.response()
    }
}
