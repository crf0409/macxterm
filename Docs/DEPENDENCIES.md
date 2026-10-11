# 依赖来源

| 组件 | 版本 / 锁定方式 | 来源 |
|---|---|---|
| SwiftTerm | 1.20.0，`5d14406844143538cd8f8851d2d8a67c1fe443e5` | https://github.com/migueldeicaza/SwiftTerm |
| libssh2 | 官方 `libssh2-1.11.1` 标签，`a312b43325e3383c865a87bb1d26cb52e3292641` | https://github.com/libssh2/libssh2 |
| OpenSSL SwiftPM 包装 | 3.6.2，`9f3b525d960fe71e534482310e96cd9c4f2faa17` | https://github.com/Lakr233/openssl-spm |
| OpenSSL 二进制 | XCFramework ZIP SHA-256 `329249e8b9ce544aeb698f4adce009d963438ff0ce26a06c7ea152764d362b86` | 包装项目的 `storage.3.6.2` Release |
| FreeRDP / WinPR | 3.32.1；官方标签源码归档 SHA-256 `8803dd26ec9660550252f255cf2d672a785ddd8f544bb475834993e96807c87f` | https://github.com/FreeRDP/FreeRDP/tree/3.32.1 |

libssh2 官方源码的 `include`、`src` 和 `LICENSE` 保存在仓库中；构建使用 OpenSSL 后端和系统 zlib。该标签的头文件版本字符串带 `_DEV` 后缀，来源仍以上表的官方标签提交为准。

OpenSSL XCFramework 是第三方构建包装，不是 OpenSSL 官方 Swift Package。其二进制由 SwiftPM 校验下载完整性；正式发布团队如要求完全自建供应链，可将同版本官方 OpenSSL 源码编译为私有 XCFramework 后更新 Package 与校验值。

SwiftTerm 的传递依赖 `swift-argument-parser` 也记录在 `Package.resolved`，不会由应用调用其命令行工具。许可全文位于 `Sources/MacXTermApp/Resources/ThirdPartyNotices.txt`，打包到应用内；包含 libssh2、SwiftTerm、OpenSSL 包装及 OpenSSL 上游 Apache 2.0 许可。

FreeRDP / WinPR 从锁定的官方源码本地生成 arm64 / x86_64 通用静态库，输出到 Git 忽略的 `Vendor/FreeRDP/lib` 与 `include` 目录，最低 macOS 26.0，复用上述 OpenSSL 包装中的组合静态库。内置软件 GDI 解码器，禁用外部客户端、动态通道和音视频依赖，运行时无需 Homebrew、XQuartz 或外置 RDP 客户端。许可证已追加到应用的 ThirdPartyNotices。`Vendor/FreeRDP/manifest.json` 记录源码与最近一次本地构建的库校验值，后者可能随构建工具链变化。首次运行应用构建或测试脚本会自动准备缺失的依赖；也可执行 `./Scripts/prepare-dependencies.sh`。显式重建执行 `python3 Scripts/build-rdp-dependency.py`，脚本在 `.build` 中建立专用 Python 工具环境，校验源码后用 CMake / Ninja 构建，不安装系统软件包。静态库已验证两种架构的封装，本机 GUI 验收仅覆盖 Apple Silicon。

服务器状态口径以 [Linux `/proc` 文档](https://www.kernel.org/doc/html/latest/filesystems/proc.html) 为准：CPU 为两次计数差，扣除 idle/iowait、不重复累加 guest；内存优先采用 MemAvailable；网络按各接口字节计数差显示；磁盘来自 `df -Pk`。内存/磁盘单位在界面使用二进制容量格式化。

MacXTerm 自有代码采用仓库根目录的 MIT 许可证；第三方源码及二进制仍遵循上游许可。`swift-argument-parser` 采用 Apache 2.0；其许可全文也包含在应用的 ThirdPartyNotices 中。
