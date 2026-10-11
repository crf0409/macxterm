import AppKit
import SwiftUI

@main struct MacXTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        Window("MacXTerm", id: "workspace") {
            WorkspaceView().environment(model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建连接") { NotificationCenter.default.post(name: .newHost, object: nil) }.keyboardShortcut(
                    "n")
                Button("新建远程桌面") { NotificationCenter.default.post(name: .newDesktopHost, object: nil) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("连接") {
                Button("重新连接") {
                    if let desktop = model.activeDesktop { desktop.connect() }
                    else if let tab = model.active { model.reconnect(tab) }
                }.disabled(model.activeHost == nil)
                Button("断开连接") {
                    if let desktop = model.activeDesktop { desktop.disconnect() } else { model.active?.disconnect() }
                }.disabled(model.activeHost == nil)
                Button("打开远程桌面…") { if let host = model.activeHost { model.configureDesktop(host) } }.disabled(model.activeHost == nil)
                Divider()
                Button("本机 SSH 公钥…") { model.showPublicKeys = true }.keyboardShortcut(
                    "k", modifiers: [.command, .shift])
                Button("服务器状态…") { if let host = model.active?.host { model.monitoringHost = host } }.keyboardShortcut(
                    "i", modifiers: [.command, .shift]
                ).disabled(model.active == nil)
                Button("端口转发…") { model.showTunnels = true }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("传输与编辑") { model.showTransfers.toggle() }.keyboardShortcut("j", modifiers: [.command])
                Divider()
                Button("左右分屏") { model.splitWorkspace(.horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.layout.tabCount < 2)
                Button("上下分屏") { model.splitWorkspace(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .option]).disabled(model.layout.tabCount < 2)
                Button("合并分屏") { model.layout.merge() }.disabled(model.layout.panes.count < 2)
                Divider()
                Button("关闭当前标签") {
                    if let id = model.activeDesktopID { model.closeDesktop(id) }
                    else if let id = model.activeID { model.closeTab(id) }
                }.keyboardShortcut(
                    "w", modifiers: [.command, .shift]
                ).disabled(model.activeHost == nil)
            }
        }
        Settings { SettingsView().environment(model) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "workspace" }?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy {
            let alert = NSAlert()
            alert.messageText = "退出 MacXTerm？"
            alert.informativeText = "连接、转发和传输将停止。已保存的编辑副本会保留，下次启动可恢复。请先在外部编辑器中保存修改。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "保留副本并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
