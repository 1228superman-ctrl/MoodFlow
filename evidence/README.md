# 验证证据

- [windows-t10.log](windows-t10.log) 记录 Windows 实际运行的三个异常注入和 DPAPI 测试。
- [windows-static.log](windows-static.log) 记录配置、语法、设备 USB 识别与原生编译前置检查。
- [windows-t09.log](windows-t09.log) 记录初次登录尝试的 HTTP 403 和独立连通性检查。
- [windows-t09-followup.log](windows-t09-followup.log) 记录复测访问成功、用户授权及官方推理完成。分析输入为合成数据，日志省略账号、凭据和请求标识。
- [device-t03-2026-11-23.log](device-t03-2026-11-23.log) 记录 WatchBridge 真机连接、手表开发者模式及用户确认的双端安装与启动结果。
- [package-verification.log](ci/package-verification.log) 记录最终 IPA 的 SHA-256 及结构复核。两种包的 Xcode 与打包原始日志随本地交付包提供，也可在 [GitHub Actions 成功运行](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/44704564090) 查看。
- 本地交付包含 iPhone 重开后截图、Apple Watch 启动截图、两端测试日志和合成记录。watchOS 测试的两张截图相同，交付包仅保留启动截图，持久化证据见合成记录。 [双端模拟运行](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/44704564096)

编译以可复核的 GitHub 运行记录和 Xcode 原始日志取证。待补真机截图包括 WatchBridge 双端安装结果、两端启动画面、定位同意／拒绝、录音时长，以及续签前后事件 ID。将截图原件留在本机，对外分享前遮挡身份、健康值、坐标和设备 ID。
