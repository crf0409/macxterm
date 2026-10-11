# 商店归档准备

当前交付包括可运行的沙盒开发应用、Xcode 工程、共享 Scheme、依赖锁定、权限与隐私清单。开发应用是 ad-hoc 签名，不是 App Store 分发包。

## 完整 Xcode

本机目前激活 Command Line Tools，没有完成正式 Xcode Archive。安装包含 macOS 26 SDK 的完整 Xcode，在 Xcode → Settings → Locations 选择 Command Line Tools，或对单次命令设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。无需修改源码的最低系统版本。

1. 复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`（已被 `.gitignore` 排除）。
2. 填写注册的 Bundle ID 与开发者 Team ID；在 Xcode 中选择对应的签名身份及 provisioning。
3. 打开 `MacXTerm.xcodeproj`，解析 Swift Package。校验根目录及工程共享目录中的 `Package.resolved`。
4. 运行 `./Scripts/archive.sh`，产物位于 `.build/artifacts/MacXTerm.xcarchive`。
5. 在 Xcode Organizer 中 Validate，再使用 App Store Connect 分发流程。正式提交由拥有开发者账号的发布者完成。

`python3 Scripts/generate-project.py` 可重新生成确定性的工程文件；添加 App 层源文件后运行此命令。本地 Package 管理 Core/C 桥接及库依赖，App target 管理原生界面和资源。

## 已配置权限

| 权限 | 用途 |
|---|---|
| App Sandbox | 应用容器与系统文件授权 |
| network.client | SSH、转发目标及 SFTP |
| network.server | 本地转发与 SOCKS 监听 |
| user-selected.read-write | 文件选择、下载、工作目录 |
| bookmarks.app-scope | 跨启动恢复用户授权 |
| NSLocalNetworkUsageDescription | 局域网主机及转发目标说明 |

`PrivacyInfo.xcprivacy` 声明无跟踪、无数据采集；列出文件时间戳与 UserDefaults 所需理由。提交前应对最终打包的第三方库和实际 API 再做一次清单核对，不把开发版清单视为商店审核保证。

## 提交仍需提供或验证

- 开发者签名、注册 Bundle ID、商店版本号、应用图标、截图、隐私政策 URL、支持网址和出口合规信息。
- macOS 26 真实系统及 Intel 架构验收。当前只在 macOS 27 Apple Silicon 本机验证。
- 具备正式签名的 Keychain/书签跨版本升级、App Store provisioning、Organizer 验证。
- 使用目标发布 Xcode 构建 Release 并审查二进制依赖、沙盒权限、隐私清单与许可证。

应保留入站网络权限：即使默认仅绑定回环，监听端口仍需要沙盒网络服务端能力。不要通过禁用 App Sandbox 来规避文件或网络授权问题。
