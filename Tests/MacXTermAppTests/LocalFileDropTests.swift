import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MacXTermApp

@MainActor @Suite(.serialized) struct LocalFileDropTests {
    @Test func binaryDocumentsUseOnlyTheirFileURLRepresentation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("MOCK_中文 文稿.docx")
        let binary = Data([0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0x80, 0x00])
        try binary.write(to: document)
        #expect(String(data: binary, encoding: .utf8) == nil)
        let provider = NSItemProvider(object: document as NSURL)
        let urls = try await LocalFileDrop.fileURLs(from: [provider])
        #expect(urls == [document])
        #expect(try Data(contentsOf: document) == binary)
    }

    @Test func finderStyleDataProvidersPreserveMultipleUnicodeNamesAndRejectWebURLs() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/MOCK_中文 space's.zip"), URL(fileURLWithPath: "/tmp/MOCK_文件夹", isDirectory: true)]
        let providers = urls.map { url in
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(url.dataRepresentation, nil); return nil
            }
            return provider
        }
        #expect(try await LocalFileDrop.fileURLs(from: providers) == urls)
        let web = NSItemProvider()
        web.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(Data("https://example.com/file.docx".utf8), nil); return nil
        }
        await #expect(throws: (any Error).self) { _ = try await LocalFileDrop.fileURL(from: web) }
    }
}
