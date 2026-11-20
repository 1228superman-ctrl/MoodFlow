# MoodFlow 第一阶段技术验证报告

日期为 2026-11-20，时区 Asia/Shanghai。基线为 Windows x64、Node.js 24.22.2、Pulsr 提交 `4341fde6abf9cd16a84703a97feba939bfee5e34`、WatchBridge 0.1.6、OpenAI DevKit 提交 `0a36fefeb913055c8c7a1a29b63d82b96b2e841a`。

## 验收状态

| 编号 | 状态 | 实际证据与待验收条件 |
| --- | --- | --- |
| T01 源码审查 | **通过** | 核对 MIT 原文、工程配置、平台依赖与主要 Swift 模块。复用了 Pulsr 的只读查询方式并保留版权。下文列出边界。 |
| T02 云端编译 | **部分通过** | 双端设备编译、IPA 校验、日志上传工作流已写入项目。YAML、plist、Swift 文法通过 Windows 静态检查。公开仓库已创建，实际 macOS runner 编译仍待确认。 |
| T03 真机安装 | **待真机验证** | Windows 已识别 iPhone USB 设备且 Apple Mobile Device Service 正在运行。尚无 IPA，WatchBridge 安装、Apple Account 登录和双端启动均未执行。 |
| T04 健康数据 | **待真机验证** | HealthKit 包申请心率、HRV SDNN、睡眠三组读权限，并查询和记录最近样本。官方能力表在 iOS、watchOS 均为免费 Apple Developer 标记 HealthKit 支持。还需验证 WatchBridge 取得的 profile、实际签名、系统授权和各类型真实样本。 |
| T05 后台监测 | **待真机验证** | 实现两端启动时注册观察者、请求后台投递、记录回调时间／应用状态／最新样本时间，并调用系统完成回调。尚无锁屏或降腕数据。 |
| T06 震动与反馈 | **待真机验证** | 模拟波动触发 Watch 前台 `.click`，手动确认和纠正关联到本地事件 ID。未测佩戴时的触感或真机反馈持久化。 |
| T07 自动定位 | **待真机验证** | 开启定位且获得使用期间授权后，前台波动事件触发单次定位，结果与事件 ID 关联。内置模拟波动用于复现。后台触发会记录跳过，锁屏自动定位链路尚无验证实现。 |
| T08 录音 | **待真机验证** | iPhone 有逐次确认、麦克风授权、手动停止、180 秒录音及可读时长记录。待验证锁屏连续录音及中断。Watch 自动启动与 Watch 后台录音仍未验证。 |
| T09 会员接入 | **失败** | Windows 成功构建官方 DevKit 并通过 DPAPI 本机往返测试。真实登录两次在 OpenID discovery 收到 HTTP 403，独立用 curl 和 Node 复测也为 403。未出现浏览器授权页，未获取授权或完成推理。此结果只说明当前环境的请求被拒绝。 |
| T10 异常处理 | **通过** | Windows 实际运行三项模拟用例。注入计划额度不足、断网、401 授权失效，均验证请求前保存的原始文件逐字节保留，失败结果中无摘要。真实服务错误和设备应用属于后续联调。 |
| T11 签名续期 | **待真机验证** | Apple 官方给出 Personal Team profile 7 天有效期。WatchBridge 提供续签功能，需实测同账号和最终 bundle ID 覆盖，比较到期前后双端启动与历史记录。 |

## Pulsr 可复用模块

| 源码 | 发现 |
| --- | --- |
| `Shared/HealthKitSource.swift` | 包含读取权限、查询描述符、单位转换、睡眠阶段聚合，并用多个查询构建日数据。探针沿用查询模式，权限缩减为三类。上游的日聚合可供后续复用。 |
| `Shared/Models.swift`、`ScoreEngine.swift`、`Insights.swift` | 提供个人基线、恢复、活动负荷、睡眠、压力估算和趋势文案。可为正式版压力／身体电量建模提供输入。心率绝对变化只作为本阶段测试触发器，正式情绪标签由用户确认。 |
| `Shared/DemoSource.swift`、`MetricsStore.swift` | 已有合成日数据与切换机制，可用于正式版演示。首阶段采用两条固定的虚构心率样本，便于复现触发和错误。 |
| `iOS/Views/CoachView.swift`、双端工程 | Pulsr Coach 用 Apple Foundation Models 及本地逻辑。工程以 Swift 5 语言模式为基线，用到 SwiftUI、HealthKit、Observation、Charts、Foundation Models 和 Metal shader。已核查的 Xcode 工程没有 SPM/CocoaPods 依赖。XcodeGen 用于生成工程。 |
| `iOS/Views/JournalView.swift`、`Watch/PulsrWatchApp.swift` | 可参考本地日志、手表状态展示与日分数。当前上游没有可直接验收的情绪反馈、事件定位、锁屏录音或 ChatGPT 计划接入。 |

[固定版本源码](https://github.com/0xCodez/pulsr/tree/4341fde6abf9cd16a84703a97feba939bfee5e34) · [MIT 许可](LICENSE-Pulsr.txt)

## 关键约束

- WatchBridge 以 Apple 签发的 profile 权限构建签名。源码中的默认签名路径按 profile 读取权限，也分别获取手表 profile。上游实现中未见专门启用 HealthKit 的逻辑，必须验证实际签名。Apple 健康读权限遭拒时，查询也可能只返回空结果。 [WatchBridge 签名代码](https://github.com/AdminZachary/WatchBridge/blob/e8403df07d0e51c0bdebe8684974f6f22f33e340/vendor/isideload/isideload/src/sideload/sign.rs) · [iOS 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios) · [watchOS 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-watchos) · [HealthKit 授权规则](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- Apple 说明 watchOS 普通样本的观察后台频率通常受每小时上限和系统预算约束。当前探针没有实时传感会话或常驻能力。手表的前台 `.click` 与锁屏提醒需要分开测。 [后台投递](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)) · [WatchKit 触感](https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:))
- 录音方案以用户前台主动启动为起点。是否能稳定持续 180 秒，由真实音频文件时长和异常场景决定。 [Apple 录音与锁屏](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
- T09 复用官方 Windows 可运行的 Node SDK。目前 T09 独立于原生应用，用合成数据验证计划授权和 Responses API。原生 iPhone 接入仍属于后续工作。 [OpenAI DevKit](https://github.com/openai/sign-in-with-chatgpt-devkit) · [官方模型及推理步骤](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)

详细证据见 [evidence](evidence/README.md)。本阶段没有开通付费服务或更改 Windows 代理、网络设置。
