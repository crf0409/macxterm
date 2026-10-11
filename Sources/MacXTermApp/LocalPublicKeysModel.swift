import AppKit
import Foundation
import MacXTermCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class LocalPublicKeysModel {
    var keys = [LocalPublicKey]()
    var selectedID: String?
    var issues = [String]()
    var error = ""
    var loading = false
    private(set) var sourceDescription = "尚未选择公钥位置"
    @ObservationIgnored private var locations = PublicKeyLocations()
    @ObservationIgnored private var store: JSONStore<PublicKeyLocations>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loader: Task<Void, Never>?
    var selected: LocalPublicKey? { keys.first { $0.id == selectedID } }
    var hasSources: Bool { !locations.sources.isEmpty }
    var canSaveAuthorization: Bool { store != nil }

    init() {
        do {
            let store = JSONStore<PublicKeyLocations>(
                url: try JSONStore<PublicKeyLocations>.applicationURL("public-key-locations.json"))
            let saved = try store.load(default: PublicKeyLocations())
            guard saved.version == 1 else { throw MacXError.message("公钥授权记录来自更新版本，请升级后打开。") }
            self.store = store
            locations = saved
            updateDescription()
        } catch { self.error = "公钥授权记录未载入，原文件已保留：" + error.localizedDescription }
    }
    func chooseFolder() {
        let panel = panel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "读取公钥"
        panel.message = "选择 ~/.ssh 文件夹，只读访问其中的 .pub 公钥文件。授权会保留供下次使用。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save([url], directory: true)
    }
    func chooseFiles() {
        let panel = panel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pub") ?? .data]
        panel.prompt = "查看公钥"
        panel.message = "选择本机已有的 .pub 公钥文件。"
        guard panel.runModal() == .OK else { return }
        save(panel.urls, directory: false)
    }
    func refresh() {
        guard hasSources else { return }
        loader?.cancel()
        let token = UUID()
        generation = token
        loading = true
        error = ""
        issues = []
        keys = []
        let snapshot = locations
        loader = Task { [weak self] in
            let work = Task.detached(priority: .utility) { Self.load(snapshot) }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            keys = result.scan.keys
            issues = result.scan.issues
            locations = result.locations
            if !keys.contains(where: { $0.id == selectedID }) { selectedID = keys.first?.id }
            loading = false
            if result.updatedBookmarks {
                do { try store?.save(locations) } catch { self.error = "更新文件授权失败：" + error.localizedDescription }
            }
        }
    }
    func clearLocations() {
        guard let store else { return }
        do {
            try store.save(PublicKeyLocations())
            generation = UUID()
            loader?.cancel()
            locations = PublicKeyLocations()
            keys = []
            issues = []
            selectedID = nil
            loading = false
            error = ""
            updateDescription()
        } catch { self.error = error.localizedDescription }
    }
    private func panel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        panel.directoryURL = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(
            ".ssh", isDirectory: true)
        return panel
    }
    private func save(_ urls: [URL], directory: Bool) {
        guard let store else { return }
        do {
            let sources = try urls.map { url -> PublicKeyLocation in
                let lease = SecurityScopedResource(url)
                defer { withExtendedLifetime(lease) {} }
                return PublicKeyLocation(
                    bookmark: try BookmarkStore.create(url, readOnly: true), directory: directory, name: url.path)
            }
            let updated = PublicKeyLocations(sources: sources)
            try store.save(updated)
            locations = updated
            selectedID = nil
            updateDescription()
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func updateDescription() {
        sourceDescription =
            locations.sources.count == 1
            ? locations.sources[0].name
            : locations.sources.isEmpty ? "尚未选择公钥位置" : "已选择 \(locations.sources.count) 个公钥文件"
    }
    nonisolated private static func load(_ saved: PublicKeyLocations) -> LoadedPublicKeys {
        var result = LoadedPublicKeys(locations: saved)
        for index in saved.sources.indices {
            if Task.isCancelled { break }
            let source = saved.sources[index]
            do {
                let (url, updated) = try BookmarkStore.resolve(source.bookmark, readOnly: true)
                let lease = SecurityScopedResource(url)
                defer { withExtendedLifetime(lease) {} }
                if let updated {
                    result.locations.sources[index].bookmark = updated
                    result.updatedBookmarks = true
                }
                if source.directory {
                    let scan = try LocalPublicKeyReader.scan(url)
                    result.scan.keys += scan.keys
                    result.scan.issues += scan.issues
                } else {
                    result.scan.keys.append(try LocalPublicKeyReader.read(url))
                }
            } catch {
                result.scan.issues.append(
                    URL(fileURLWithPath: source.name).lastPathComponent + "：" + error.localizedDescription
                        + " 可重新选择以更新授权。")
            }
        }
        var seen = Set<String>()
        result.scan.keys = result.scan.keys.filter { seen.insert($0.id).inserted }
        return result
    }
}

private struct PublicKeyLocation: Codable, Sendable {
    var bookmark: Data
    let directory: Bool
    let name: String
}
private struct PublicKeyLocations: Codable, Sendable {
    var version = 1
    var sources: [PublicKeyLocation] = []
}
private struct LoadedPublicKeys: Sendable {
    var locations: PublicKeyLocations
    var scan = PublicKeyScan()
    var updatedBookmarks = false
}
