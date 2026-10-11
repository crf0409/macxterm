# MacXTerm

<img src="Assets/Brand/macxterm-logo-v1.png" alt="MacXTerm logo" width="128">

面向 macOS 26 及以上的原生 SSH 与 XRDP / RDP 工作区，使用 Swift 6、SwiftUI、AppKit、SwiftTerm、libssh2 和内置 FreeRDP。界面以简体中文为主，导航、工具栏和浮层使用系统材质，终端背景保持高对比度。

项目自有代码采用 [MIT License](LICENSE)，第三方组件保留各自许可证。欢迎查看 [参与指南](CONTRIBUTING.md)。

## 运行

需要 macOS 26+、支持 macOS 26 SDK 的 Xcode / Command Line Tools、Python 3.9+（含 venv / pip）和网络连接。首次构建会下载校验后的依赖源码和 SwiftPM 包，并在本地编译 FreeRDP；生成的第三方头文件、静态库和本机配置不提交到 Git。

```sh
git clone https://github.com/crf0409/macxterm.git
cd macxterm
./Scripts/build-app.sh
open .build/artifacts/MacXTerm.app
```

使用 `CONFIGURATION=release ./Scripts/build-app.sh` 可构建优化版。

生成的应用已启用 App Sandbox，使用本机 ad-hoc 签名供开发运行。实际输出为 `.build/artifacts/MacXTerm.app`。发布签名与商店归档请参阅 [归档说明](Docs/ARCHIVING.md)。

构建脚本通过 `Scripts/build-app-icon.sh` 将蓝紫色 `Assets/Brand/macxterm-logo-v1.png` 生成包含标准与 Retina 尺寸的 `AppIcon.icns`；SwiftPM 应用打包和生成的 Xcode 工程都包含此图标。可以将生成的应用复制到 `/Applications/MacXTerm.app`。

在仅有 Command Line Tools 的环境中，若已安装 macOS 26.5 SDK，脚本会选择该 SDK 与 SwiftPM native 构建器，兼容开发验证环境中的 CLT 27 SwiftUI 宏插件限制。完整 Xcode 环境请先执行 `./Scripts/prepare-dependencies.sh`，再打开 `MacXTerm.xcodeproj`，选择 MacXTerm Scheme。最低系统版本为 macOS 26.0。

## 已实现的工作流程

- 保存、分组、搜索主机；密码及 RSA / Ed25519 私钥认证，支持私钥口令。主机首次信任、已保存指纹变化阻断。
- 多标签终端、中文输入、右键粘贴、窗口尺寸同步、交互程序、断线重连。标签支持拖动排序和移动到另一窗格；拖到画面左/右边缘形成左右分屏，上/下边缘形成上下分屏，最多同时显示两个窗格。移动保留会话、输出和浏览位置。
- XRDP / RDP 桌面直接显示在工作区标签中：鼠标左/右/中键、滚轮、键盘及快捷键、文本输入、发送剪贴板文本、Ctrl + Alt + Delete、全屏和按比例缩放。可新建独立 RDP 主机，也可从 SSH 主机菜单打开桌面；支持独立的 SSH 安全隧道，关闭桌面标签即停止其隧道。旧 SSH 配置自动兼容。
- 原生双栏工作区：左侧主机/远程文件，右侧终端，底部传输与编辑任务。
- **窗口最底部常驻性能栏**：CPU、内存、根磁盘和主要网卡收发速率。CPU、内存、网络每秒更新；磁盘每 30 秒、静态信息连接后读取一次。复用终端的 SSH 连接，底栏和详情共享采样；切到后台暂停，错误指数退避。各指标固定宽度、数字右对齐，单位变化不会挤动相邻项目。点击查看趋势、全部磁盘、网卡、Swap、负载与运行时间。当前监控支持 Linux `/proc`，无需安装代理。设计依据见 [监控实现与性能](Docs/MONITORING.md)。
- SFTP 目录浏览、隐藏文件、拖入上传、文件选择上传、下载到用户选择的目录。文件夹递归、同名保护、取消、重试，最多 3 个并行任务；不自动遍历符号链接。
- 外部编辑 UTF-8 / UTF-16 文本（20 MB 上限）：目录和文件双重监听，500 ms 防抖，原子保存兼容，连续保存合并；远端内容哈希冲突检查、同目录临时文件及 POSIX 原子替换，保留 POSIX 模式位。
- 未完成传输与编辑副本持久保存。重启后手动恢复；传输从头开始。授权失效可重新选择来源或目标；冲突可以保留本地、备份后下载或明确覆盖。
- 本地转发、远程转发和 SOCKS5 TCP CONNECT（支持远端解析域名）。独立生命周期，不随终端标签关闭而停止；默认回环监听，SOCKS5 限制本机回环。
- 密码认证首次成功后自动保存到系统钥匙串，后续连接和应用重启后自动读取；私钥口令仍可选择是否保存。私钥、传输来源/目标、编辑工作区使用 security-scoped bookmarks。
- 本机 SSH 公钥面板：读取授权文件夹中的 `.pub` 文件，或单独选择公钥；显示文件名、算法、备注和 SHA256 指纹，一键复制完整 OpenSSH 公钥。支持 RSA、Ed25519、ECDSA 和对应的 FIDO 公钥；只保存只读文件授权，重启后可复用。

## 操作

1. `⌘N` 新建连接，填入地址、端口和用户名；选择密码或私钥。密码在首次成功登录后自动存入系统钥匙串，以后连接同一主机无需再次输入。私钥口令可单独选择“保存在系统钥匙串”。
2. 核对首次显示的指纹后连接。主机菜单支持编辑、清除凭据、重置经核实的服务器指纹。
3. 文件栏路径输入后回车。单击文件再点“下载”；双击目录进入；双击文本文件后，下载保留原扩展名的工作副本，并自动打开该文件类型在 macOS 中关联的编辑器，切到前台。没有对应编辑器时使用 TextEdit；脚本以编辑方式打开，不交给 Shell 执行。`.command` / `.tool` 的本地工作副本追加 `.txt` 以作为文本打开，回传保留原远端名称。首次编辑选择持久工作目录；设置中可指定统一编辑器。
4. 在外部编辑器保存；底部“远程编辑”显示已同步、失败或冲突。应用退出前请先在编辑器保存修改。
5. `⌘⇧T` 管理端口转发；`⌘J` 展开任务列表；`⌘⇧I` 查看服务器状态详情；`⌘⇧W` 关闭当前终端或桌面标签。
6. 点击工具栏的钥匙按钮，或按 `⌘⇧K` 打开“本机 SSH 公钥”（菜单“连接”及设置中也有入口）。首次通过系统面板选择 `~/.ssh` 文件夹或 `.pub` 文件，选择需要的公钥后点击“复制公钥”；可将完整内容追加到目标用户的 `~/.ssh/authorized_keys`。公钥面板无需连接服务器；支持刷新、更换来源和清除保存的授权。

## 终端粘贴与分屏

终端内点击鼠标右键即可粘贴本机剪贴板文字，使用 SwiftTerm 的 bracketed paste 处理；`⌘V` 继续可用。剪贴板包含换行时，行为与普通终端粘贴一致，请在粘贴前确认内容。远程桌面仍使用 RDP 原有的右键操作。

打开至少两个会话后，拖住标签名称到另一个标签前面可调整顺序；拖到终端画面的左/右边缘可左右分屏，拖到上/下边缘可上下分屏。出现蓝色预览后松开。标签可跨窗格移动：放到画面中间会加入该窗格，放到标签上会排在其前面。每个会话只出现在一个窗格，移走或关闭某个窗格的最后一个标签会自动合并布局。

点击要操作的终端或标签后，蓝色边框标记当前窗格；文件侧栏、工具栏、性能栏和关闭标签命令跟随当前会话。拖动中间分隔线可调整大小，SSH 的 PTY 行列数随之更新。工具栏“分屏”菜单也支持左右、上下和合并；`⌘⇧D` 左右分屏，`⌘⌥D` 上下分屏。分屏及移动标签不会重新登录服务器。

## XRDP 远程桌面

点击工具栏“远程桌面”，或按 `⌘⇧N` 新建远程桌面。填写服务器地址、桌面用户名及 RDP 端口（默认 3389），选择分辨率。XRDP 默认使用 TLS，需要 NLA 的服务器可选择“自动协商”。桌面密码仅用于当前标签，不写入 JSON、日志或 SSH 钥匙串；留空连接后可直接在服务器的 XRDP 登录画面中填写。服务器需已安装并运行 XRDP 和桌面环境。

对已有 SSH 主机，右键选择“打开远程桌面…”，勾选“通过 SSH 安全隧道连接”，将“服务器内的桌面地址”留空（使用 127.0.0.1），RDP 端口设为 3389，本机端口默认 13389。隧道复用主机的认证配置，使用独立 SSH 连接，核对 SSH 指纹后再启动 RDP。此隧道随桌面标签关闭；端口转发管理器中的其他规则仍使用原有独立生命周期。

也可以在终端手动建立隧道，然后将独立 RDP 主机配置为 `127.0.0.1:13389`。将下方示例的私钥、用户名和主机名替换为自己的配置：

```sh
ssh -i ~/.ssh/id_ed25519 -N \
  -L 127.0.0.1:13389:127.0.0.1:3389 ubuntu@server.example.com
```

首次遇到无法自动验证的证书会显示主题、签发者和 SHA-256 指纹，必须核对后接受；接受仅对本次连接有效。通过 SSH 隧道连接时，证书的主机名可能与回环地址不匹配，应通过已验证的 SSH 连接读取服务器证书指纹再核对。

首版支持画面和交互，采用连接时选择的分辨率，窗口变化只缩放画面。`⌘V` 或“发送剪贴板文本”以键盘文本事件发送本机文字，每次上限 2000 个 UTF-16 字符；未接入双向剪贴板、音频、磁盘/打印机重定向、动态分辨率、多显示器或 RDP 网关。中文输入走 macOS 输入法提交事件，仍需补充各输入法的人工验收。

公钥面板读取现有公钥，不生成新密钥。它只打开普通 `.pub` 文件，不扫描子目录或跟随符号链接；误选改成 `.pub` 后缀的私钥、损坏或不支持的格式时显示原因。未找到公钥时，可选择其他位置中已有的 `.pub` 文件。

普通上传遇到重名会保留已有文件并报告错误，“重试”会明确确认替换。同名目录合并，不删除目录中无关文件。远程编辑结束后，本地副本继续保留；再次打开会创建新的工作副本。

## 源码结构

| 目录 | 内容 |
|---|---|
| `Sources/MacXTermApp` | SwiftUI/AppKit 窗口、终端、状态栏、文件和转发界面 |
| `Sources/MacXTermCore` | SSH/SFTP、SOCKS、转发、编辑协调、采样解析、凭据与持久化 |
| `Sources/SSHBridge` | 非阻塞 libssh2 C 桥接、BSD socket |
| `Sources/RDPBridge` | FreeRDP C 桥接、连接工作线程、输入队列与画面快照 |
| `Vendor/FreeRDP` | FreeRDP 许可证与版本/校验清单；头文件和静态库由锁定源码本地生成 |
| `Sources/CLibSSH2` | libssh2 1.11.1 官方标签源码及许可证 |
| `Tests/MacXTermCoreTests` | Swift Testing 单元与真实 OpenSSH 集成测试 |
| `Tests/MacXTermAppTests` | 原生终端视图与重连输入回归测试 |
| `IntegrationTest` | 本地/容器测试服务 |
| `Config` | 沙盒、Info.plist、签名及归档配置 |

SSH 句柄各自由专用串行执行队列管理。终端、文件浏览、传输、编辑和转发使用独立连接，避免大文件或慢目标阻塞终端；因此服务器需允许同一用户多个 SSH 连接。性能采样复用终端连接中的独立 exec 通道，打开、读写、超时清理都在 EAGAIN 时让出队列。SwiftUI 不接触底层句柄。

## 测试

```sh
./Scripts/test.sh                         # 单元测试；跳过需要服务的集成项
python3 Scripts/integration.py            # 启动独立的本机 OpenSSH 测试服务并清理
python3 Scripts/integration.py --docker   # 可选：Linux OpenSSH 容器（需要 Docker）
```

脚本仅使用回环测试端口 22337–22341，生成专用测试密钥，结束后停止自己启动的服务，不修改系统 SSH 配置。容器镜像中的固定密码只用于该隔离测试夹具，不得复用于真实主机。实测结果和未覆盖项目见 [验收记录](Docs/VALIDATION.md)。

## 依赖与边界

SwiftTerm **1.20.0**、OpenSSL **3.6.2** 的 SwiftPM revision 和二进制校验值已锁定；libssh2 **1.11.1** 源码 vendored。OpenSSL 通过 `Lakr233/openssl-spm` 的 XCFramework 包装分发；许可证和来源见 [依赖说明](Docs/DEPENDENCIES.md)。

暂不包含 X11、VNC、云同步、跳板链、SSH Agent、PuTTY PPK 或内置编辑器。RDP 首版边界见上文。传输恢复是重新开始任务，不是按字节断点续传。SFTP 不提供跨客户端的比较并交换原语：编辑回传在提交前核对内容并原子替换，但最后一次核对与替换之间仍存在很短的远端并发写入窗口；要求严格跨工具协作锁的场景应使用服务器侧版本控制或锁协议。

主机配置、指纹和任务记录保存在应用容器的 `Library/Application Support/MacXTerm`。配置损坏时保留原文件并禁止覆盖。真实账号和服务器密码不包含在源码或测试夹具中。

## 许可证

MacXTerm 自有代码使用 [MIT License](LICENSE)。libssh2、SwiftTerm、OpenSSL、FreeRDP / WinPR 和其他依赖继续使用各自的许可证；版权与许可全文见 [ThirdPartyNotices.txt](Sources/MacXTermApp/Resources/ThirdPartyNotices.txt) 和 [依赖来源](Docs/DEPENDENCIES.md)。品牌图标的生成来源记录在 `Assets/Brand/macxterm-logo-v1.prompt.txt`。
