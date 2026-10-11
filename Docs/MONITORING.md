# 实时服务器状态：实现依据与开销

调研与实现日期：2026-09-29。

## 参考项目

| 项目 | 从官方资料或源码确认的处理方式 | 对本项目的意义 |
|---|---|---|
| Electerm | 28 px 小条、共享同一 SSH 会话的 exec 通道；CPU/内存/网络 5 秒，磁盘 10 秒，静态信息一次；界面共享一个采样器 | 避免重复 SSH 握手和重复采样，按指标变化频率拆分 |
| MobaXterm | 官方功能说明确认 SSH 下方的小条连续显示 CPU、RAM、NET、磁盘 | 采用相似的信息层级；公开资料没有给出可核实的内部采样周期或完整实现，不能据此声称已复刻其内部算法 |
| WindTerm | 官方仓库/发布记录描述 Sysmon 和异步 SSH；仓库说明只有部分源码公开 | 参考交互和异步设计，不能将其 Sysmon 当作已完整审阅的开源实现 |

来源：[Electerm 官方说明](https://electerm.org/blogs/monitor-bar-and-info-panel/)、[采样定义源码（固定提交）](https://github.com/electerm/electerm/blob/5c8ac89ce85dbdeb5c99ed065fd9e4571271c466/src/client/components/remote-monitor/monitor-model.js)、[共享会话监控源码](https://github.com/electerm/electerm/blob/5c8ac89ce85dbdeb5c99ed065fd9e4571271c466/src/client/components/remote-monitor/session-monitor.js)、[MobaXterm 官方功能](https://mobaxterm.mobatek.net/download-home-edition.html)、[WindTerm 官方仓库](https://github.com/kingToolbox/WindTerm)。

## MacXTerm 的实际实现

| 数据 | 正常前台周期 | 读取方式 |
|---|---|---|
| CPU / RAM / Swap / 网络 / 负载 / uptime | 1 秒 | 一次固定 POSIX shell 探针，使用 shell 内建 read/printf 读取 `/proc` |
| 磁盘空间 | 30 秒 | 独立 `df -Pk` 探针，缓存结果 |
| 内核 / CPU 型号 / 核心数 | 每个连接首次 | 静态元数据探针 |

- 只监控当前可见的连接。底栏与详情页共享 `ServerMonitorState`，打开详情不会再开连接或重复采样。
- 使用终端已认证的 SSH 传输；命令在单独 exec 通道中运行，不写入交互终端及 shell 历史。
- 高频探针不执行 `top`、`ps`、`cat`、`grep` 等额外进程。仍有 SSH exec 和 shell 启动开销，不能称为零成本。
- CPU 和网卡速率使用前后累计计数差；首个样本显示空值，计数回退或重启后重新建立基线。内存优先使用 MemAvailable。网卡按默认路由选择，不相加虚拟接口。
- 前台正常情况下每秒采样；响应超过周期时不堆积请求。进入后台暂停，失败后按 2、4、8…秒退避，最多 60 秒。磁盘失败保留旧值并显示提示。
- exec 默认 5 秒超时；超时发送 TERM，并非阻塞地释放通道。服务器拒绝信号或网络异常时清理可继续一段时间，但每次 EAGAIN 都让出执行队列，终端仍可处理输入。
- 历史最多 301 个样本（约 5 分钟），采样间断在图上断开。
- 底栏高 30 pt。CPU/内存/磁盘/下行/上行各有固定宽度，边界和两侧留白，等宽数字右对齐；数据未知时保留占位，变换单位不改变邻项位置。

实现位于 `Sources/MacXTermCore/ServerMonitor.swift`、`SSHSessionService.swift`、`Sources/MacXTermApp/ServerMonitorState.swift` 和 `ServerStatusBar.swift`。指标定义参考 [Linux /proc 官方文档](https://www.kernel.org/doc/html/latest/filesystems/proc.html)。

## 已测数据及适用范围

在用户授权的 Linux 测试主机中，用单个 `sh` 连续执行 100 次实际高频探针（输出重定向 `/dev/null`），`time -p` 返回：

```text
real 0.07
user 0.02
sys  0.04
```

合计约 0.06 CPU 秒，即平均约 0.6 ms/次。按每秒一次折算，**仅这一段探针计算约占单核 0.06%**。该结果不包含每次 SSH exec、shell 启动、加密、磁盘探针或客户端界面，不能作为整个监控系统的 CPU 占用，也不能直接与 MobaXterm 横向比较。脚本位于本机 `.build/monitor-benchmark-command.txt`。

本机早期 Debug 沙盒版本：一个已连接终端、实时底栏和一个已同步编辑任务，在前台空闲 30 秒时测得进程平均 3.5% 单核 CPU、RSS 128.78 MiB。这是整个应用的单次观察，不是监控的增量开销，也不是 Release 性能承诺。原始结果位于 `.build/monitor-local-performance.json`。

慢命令和超时清理另有真实 OpenSSH 回归测试：执行 `sleep` 的同时发送终端标记，要求 1 秒内收到；采样超时后终端连接继续可用。

随后用 Release 沙盒版本保持一个终端、一个已同步编辑任务，底栏可见、详情关闭，各观察 30 秒：

| 状态 | 整个应用平均 CPU（单核口径） | 观察结束 RSS |
|---|---|---|
| 性能采样开启 | 2.399% | 116.34 MiB |
| 暂停性能采样，终端仍连接 | 2.166% | 126.23 MiB |

这两次顺序观察的 CPU 差约 0.23 个百分点，说明当前样本下主要 CPU 基线来自应用其他活动。它不是严格受控的监控成本测量：第二轮前曾打开详情图表，RSS 不可用于归因或认为暂停导致增量内存。应在同一系统、相同连接/前台状态下多轮对比后再设性能预算。可用 `Scripts/measure-app.py` 重复只读进程观测；原始结果位于 `.build/performance-release-active-monitor.json` 和 `.build/performance-release-paused-monitor.json`。
