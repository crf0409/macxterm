import AppKit
import Foundation
import MacXTermCore
import Testing
import UniformTypeIdentifiers
@testable import MacXTermApp

@MainActor @Suite(.serialized) struct ByPyDriveTests {
    private func result(entries: Bool = false) throws -> ByPyResponse {
        let json = "{\"ok\":true,\"authorized\":true,\"needsAuthorization\":false,\"version\":\"MOCK\",\"entries\":\(entries ? "[{\"path\":\"/data/中文 file's.bin\",\"name\":\"中文 file's.bin\",\"isDirectory\":false,\"size\":5000000000000,\"modified\":0}]" : "[]")}"
        return try JSONDecoder().decode(ByPyResponse.self, from: Data(json.utf8))
    }
    private func finish(_ drive: ByPyDriveModel) async {
        for _ in 0..<200 where drive.busy { try? await Task.sleep(for: .milliseconds(5)) }
    }
    @Test func authorizationLoadsListAndCopyActionsPreserveNames() async throws {
        var operations = [String](); var clipboard = [String]()
        let drive = ByPyDriveModel(operation: { request, _, _ in
            operations.append(request.operation)
            return try result(entries: request.operation == "list")
        }, clipboard: { clipboard.append($0) })
        drive.authorizationCode = "MOCK_AUTHORIZATION_CODE_12345678"; drive.authorize()
        #expect(drive.authorizationCode.isEmpty)
        await finish(drive)
        #expect(!drive.busy); #expect(operations == ["authorize", "list"])
        #expect(drive.entries.count == 1)
        drive.selection = drive.entries.first?.id
        drive.copyName(); drive.copyPath(); drive.copyCommand()
        #expect(clipboard == ["中文 file's.bin", "data/中文 file's.bin", "bypy download 'data/中文 file'\\''s.bin'"])
    }
    @Test func multipleDroppedFilesRunSeriallyWithIndependentPaths() async throws {
        var paths = [String](); var active = 0; var peak = 0
        let drive = ByPyDriveModel(operation: { request, _, progress in
            active += 1; peak = max(peak, active); paths.append(request.path)
            progress(5_000_000_000_000, 10_000_000_000_000)
            try await Task.sleep(for: .milliseconds(15)); active -= 1
            return try result()
        })
        drive.authorized = true; drive.path = "/models"
        drive.uploadLocal([URL(fileURLWithPath: "/tmp/MOCK_one.bin"), URL(fileURLWithPath: "/tmp/MOCK_中文 two.bin")])
        await finish(drive)
        #expect(peak == 1)
        #expect(paths == ["/models/MOCK_one.bin", "/models/MOCK_中文 two.bin"])
        #expect(drive.jobs.allSatisfy { $0.task.state == .completed })
        #expect(drive.jobs.first?.task.totalBytes == 10_000_000_000_000)
    }
    @Test func cancelStopsJobAndRejectsSourceFromAnotherServer() async throws {
        let drive = ByPyDriveModel(operation: { _, _, _ in
            try await Task.sleep(for: .seconds(30)); return try result()
        })
        drive.authorized = true; drive.uploadLocal([URL(fileURLWithPath: "/tmp/MOCK_cancel.bin")])
        let id = try #require(drive.jobs.first?.id)
        drive.cancel(id); await finish(drive)
        #expect(drive.jobs.first?.task.state == .cancelled)
        drive.target = UUID().uuidString
        drive.uploadRemote(.init(hostID: UUID(), path: "/tmp/MOCK_other.bin", isDirectory: false))
        #expect(drive.error.contains("文件所属的 SSH 服务器"))
        #expect(drive.jobs.count == 1)
    }
    @Test func nativeFileURLDragRepresentationReachesUploadQueue() async throws {
        let url = URL(fileURLWithPath: "/tmp/MOCK_拖入 file's.bin")
        let provider = NSItemProvider(object: url as NSURL)
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? MacXError.message("File URL drag representation missing")) }
            }
        }
        let decoded = try #require(URL(dataRepresentation: data, relativeTo: nil))
        #expect(decoded == url)
        var received: String?
        let drive = ByPyDriveModel(operation: { request, _, _ in received = request.localPath; return try result() })
        drive.authorized = true; drive.uploadLocal([decoded]); await finish(drive)
        #expect(received == url.path)
        #expect(drive.jobs.first?.task.state == .completed)
    }
}
