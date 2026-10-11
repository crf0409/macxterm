# 参与 MacXTerm

欢迎通过 Issue 报告问题，或提交 Pull Request。报告中请注明 macOS 版本、CPU 架构、连接类型（SSH / SFTP / RDP）和可重复的操作步骤。截图与日志请先移除服务器地址、用户名、密钥、密码、主机指纹和个人文件路径。

## 开发环境

使用 macOS 26 或更高版本，以及支持 macOS 26 SDK 的 Xcode / Command Line Tools。首次运行 `./Scripts/build-app.sh` 或 `./Scripts/test.sh` 会准备锁定版本的 FreeRDP 依赖；需要 Python 3.9 或更高版本、网络连接和可用的 Python venv / pip。

```sh
./Scripts/build-app.sh
./Scripts/test.sh
python3 Scripts/integration.py
```

协议集成脚本只启动独立的回环测试服务；可选 Docker 模式见 README。真实服务器验收请使用自己有权访问的测试环境，不要修改业务数据。针对源码变更运行相关检查；涉及输入、焦点、拖动、窗口布局或沙盒授权的变更，需要额外进行原生应用交互验证。

## 提交

从 `main` 创建功能分支。Pull Request 中说明具体问题、修改后的行为和实际验证结果；区分单元测试、隔离协议测试及真实服务器验证。保留第三方源码的许可证与版权声明。不要提交 `.build`、生成的依赖库、本地签名配置、凭据或应用容器数据。

项目自有代码采用 [MIT License](LICENSE)。提交贡献即表示你有权以该许可证提供这些改动；第三方组件继续遵循各自的许可证。
