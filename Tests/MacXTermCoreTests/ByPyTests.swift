import Foundation
import Testing
@testable import MacXTermCore

@Suite struct ByPyTests {
    @Test func cloudPathsAndCopyCommandPreserveUnicodeAndQuotes() throws {
        #expect(try ByPyPath.normalize("/apps/bypy/训练 数据/model.bin") == "/训练 数据/model.bin")
        #expect(try ByPyPath.normalize("/apps/bypy") == "/")
        #expect(try ByPyPath.join("/训练 数据", "John's $(echo nope).bin") == "/训练 数据/John's $(echo nope).bin")
        let command = try ByPyPath.downloadCommand("/训练 数据/John's $(echo nope).bin")
        #expect(command == "bypy download '训练 数据/John'\\''s $(echo nope).bin'")
        #expect(throws: MacXError.self) { try ByPyPath.normalize("/../outside") }
        #expect(throws: MacXError.self) { try ByPyPath.join("/", "../outside") }
        #expect(throws: MacXError.self) { try ByPyPath.normalize("/line\nname") }
    }
    @Test func splitProtocolPacketsKeepLargeByteCountsAndPrivateResults() throws {
        let parser = ByPyEventParser()
        let progress = Data("{\"kind\":\"progress\",\"completed\":9000000000000,\"total\":18000000000000}\n".utf8)
        for byte in progress { parser.receive(Data([byte])) }
        let result = Data("{\"kind\":\"result\",\"result\":{\"ok\":true,\"authorized\":true,\"needsAuthorization\":false,\"version\":\"MOCK\",\"entries\":[{\"name\":\"中文.tar\",\"path\":\"/中文.tar\",\"isDirectory\":false,\"size\":9000000000000,\"modified\":0}]}}\n".utf8)
        for start in stride(from: 0, to: result.count, by: 7) { parser.receive(result.subdata(in: start..<min(start + 7, result.count))) }
        #expect(try parser.response().entries?.first?.size == 9_000_000_000_000)
        #expect(try parser.response().entries?.first?.name == "中文.tar")
    }
    @Test func localRuntimeStartsWithoutInteractiveLoginOrPlaintextToken() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = ByPyRuntime(root: root.appendingPathComponent(".build/bypy"))
        guard FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent("bridge.py").path) else {
            throw MacXError.message("Run Scripts/prepare-bypy-runtime.py before the bypy tests")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bypy-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var request = ByPyRequest(operation: "list"); request.configDirectory = folder.path
        let result = try await runtime.run(request)
        #expect(result.version == "1.8.9")
        #expect(result.needsAuthorization)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("bypy.json").path))
        #expect(URL(string: result.authURL ?? "")?.host == "openapi.baidu.com")
    }
    @Test func cancellationTerminatesTheLocalHelperPromptly() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bypy-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("python"), withDestinationURL: root.appendingPathComponent(".build/bypy/python"))
        try Data("import sys,time\nsys.stdin.readline()\ntime.sleep(30)\n".utf8).write(to: fixture.appendingPathComponent("bridge.py"))
        let runtime = ByPyRuntime(root: fixture)
        let task = Task { try await runtime.run(ByPyRequest(operation: "status")) }
        try await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now; task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
