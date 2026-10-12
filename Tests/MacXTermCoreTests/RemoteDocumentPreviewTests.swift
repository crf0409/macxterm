import Foundation
import Testing
@testable import MacXTermCore

@Suite struct RemoteDocumentPreviewTests {
    private func entry(_ name: String, size: UInt64 = 1024, mode: UInt32 = 0o100600) -> RemoteEntry {
        .init(path: "/MOCK/" + name, name: name, attributes: .init(size: size, permissions: mode, modified: 0))
    }
    @Test func doubleClickRoutesWordAndPDFToPreviewWhileTextStillEdits() {
        for name in ["中文 Word.docx", "legacy.DOC", "template.dotx", "read.pdf"] {
            #expect(RemoteFileOpenAction.action(for: entry(name)) == .documentPreview)
        }
        for name in ["settings.json", "README.md", "run.command", "config", ".bashrc"] {
            #expect(RemoteFileOpenAction.action(for: entry(name)) == .textEditor)
        }
        #expect(RemoteFileOpenAction.action(for: entry("directory.docx", mode: 0o040700)) == .directory)
    }
    @Test func previewRejectsTraversalLinksAndOversizedDocumentsBeforeTransfer() throws {
        try RemoteDocumentPreview.validate(entry("中文 Word.docx"))
        #expect(throws: MacXError.self) { try RemoteDocumentPreview.validate(entry("../escape.docx")) }
        #expect(throws: MacXError.self) { try RemoteDocumentPreview.validate(entry("link.docx", mode: 0o120777)) }
        #expect(throws: MacXError.self) { try RemoteDocumentPreview.validate(entry("huge.docx", size: RemoteDocumentPreview.maximumBytes + 1)) }
    }
}
