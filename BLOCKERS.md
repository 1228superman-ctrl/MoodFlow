# 未解决问题及替代方案

| 涉及任务 | 当前阻塞 | 后续动作或可选替代方案 |
| --- | --- | --- |
| T11 | 模拟包已在两端安装并启动。签名有效期、覆盖续签和自然到期后的历史保留仍需实测。 | 在两端各保存带可识别编号的模拟事件，固定账号及最终 bundle ID，先测到期前覆盖续签，再测自然到期后的续签。 |
| T04、T05 | 双端签名和前台健康刷新已通过。心率、HRV、睡眠逐项读取与息屏采样频率待测。 | 逐项核对可读状态，再单独测息屏的回调时间和提醒。[核对日志](evidence/release-0.2/iphone-health-signing.log) |
| T05、T06 | 后台唤醒和 Watch 通常的触感受到系统管理。无锁屏实测记录。 | 用系统允许的本地通知试验延迟提醒，单独核对通知许可、专注模式和实际 Watch 呈现。原阶段可先验收前台轻震和手动确认。 |
| T07 | 此阶段只用使用期间权限与前台单次位置。 | 若后台无法取得位置，保留事件时间、原始生理数据和定位状态，可让用户重新打开应用后补充地点，并将补记时间与事件时间一起保存。 |
| T08 | 0.5.0 增加了手表主动开启的全天录音。降腕、退出页面、跨片段接续、音频打断恢复以及传输仍待配对真机验证。 | 先用短片段完成麦克风授权和同步测试，再降腕录制超过 15 分钟，检查边界、断连补传和原声播放。继续在普通佩戴场景测半天或一天的续航和实际录制覆盖。 |
| 原生 ChatGPT 接入 | Windows 独立探针已完成实际官方推理。iPhone 尚无原生登录和推理联调。 | 后续再评估原生接入。当前 Windows 探针可用合成数据独立复测。失败时保留原始数据和失败状态，等待服务可用后手动重试。 |
| 正式需求 23:59 | iOS 系统决定后台任务时机。 | 用本地日期记录应总结日期，在系统给到执行机会或应用重开时补做。按日期和版本去重，等待正式开发时验证跨时区、跨日和重试。 |

[Apple 免费开发账号约束](https://developer.apple.com/help/account/basics/about-your-developer-account) · [后台任务调度](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler) · [OpenAI 错误与恢复](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)

## iPhone HealthKit 复测候选

独立的「心绪授权测试」已由 Impactor 2.7.3 通过免费团队签名，并经 USB 装到 iPhone。用户确认授权弹窗出现并读到真实样本。原版后来也在保持 App 标识的情况下完成双端覆盖，用户确认 iPhone 旧记录仍在，Apple Watch 正常刷新健康数据。 [Impactor 能力请求代码](https://github.com/claration/impactor/blob/v2.7.3/crates/plume_core/src/developer/v1/capabilities.rs)
