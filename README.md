# MoodFlow（心绪）第一阶段验证

这是 iPhone／Apple Watch 技术探针和独立的 Windows ChatGPT 接入探针。原生应用用中文显示测试入口和本机记录，最低版本为 iOS 26 和 watchOS 26，沿用 Pulsr 的平台基线。

- [Windows 编译、安装和验收步骤](WINDOWS_SETUP.md)
- [T01–T11 验证报告](VALIDATION_REPORT.md)
- [阻塞问题和替代方案](BLOCKERS.md)
- [正式开发需求](REQUIREMENTS.md)
- [测试日志和取证清单](evidence/README.md)

## Windows 上运行模拟验证

从项目根目录使用 Node.js 22.12 或更高版本。

```powershell
node --test ai/probe.test.mjs
node ai/probe.mjs check-dpapi
```

第一条命令注入三种错误并验证同一套分析流程的本地写入结果。第二条用虚构字符串测试 Windows 当前用户的 DPAPI 加密。两条命令均可脱网执行。

Windows 探针已使用官方 Sign in with ChatGPT 完成真实分析。iPhone 和 Apple Watch 模拟器也已分别通过启动和反馈持久化测试。 [模拟器运行](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/44704564096)

## 原生包

本地交付包的 `ipa/` 含本次实编译的 `MoodFlow-sim.ipa` 和 `MoodFlow-health.ipa`。首次安装使用模拟包。两种包均须经 WatchBridge 本地签名后尝试安装。 [GitHub Actions 构建证据](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/44704564090)

`.github/workflows/build.yml` 分别编译 HealthKit 包和模拟包。两个包分别用 Xcode 的实体 iOS、watchOS SDK 生成二进制，组装 WatchBridge 需要的双端 IPA。HealthKit 包表达所需的权限，最终权限由 Apple 签发的 profile 和用户授权决定。模拟包从编译时移除 HealthKit 入口。

探针本地日志记录样本时间、应用状态和样本值。iPhone 与 Watch 分别保存自己的日志。Windows AI 探针只接受内置虚构数据，原生应用没有网络代码。个人数据、签名材料和登录信息均应存放在仓库外。

HealthKit 查询设计源于 [Pulsr](https://github.com/0xCodez/pulsr/tree/4341fde6abf9cd16a84703a97feba939bfee5e34)，其 MIT 声明见 [LICENSE-Pulsr.txt](LICENSE-Pulsr.txt)。WatchBridge 和 OpenAI DevKit 独立下载和运行，遵从上游各自的许可。
