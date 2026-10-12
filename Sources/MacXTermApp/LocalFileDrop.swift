import AppKit
import MacXTermCore
import UniformTypeIdentifiers

@MainActor enum LocalFileDrop {
    static func fileURL(from provider: NSItemProvider) async throws -> URL {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            throw MacXError.message("请拖入本机文件或文件夹。")
        }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? MacXError.message("未能读取拖入的文件地址。")) }
            }
        }
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
            throw MacXError.message("拖入的项目没有有效的本机文件地址，请用上传按钮重新选择。")
        }
        return url
    }

    static func fileURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls = [URL]()
        for provider in providers {
            urls.append(try await fileURL(from: provider))
        }
        return urls
    }
}
