# 未解决问题及替代方案

| 涉及任务 | 当前阻塞 | 后续动作或可选替代方案 |
| --- | --- | --- |
| T03、T11 | 两种 IPA 已生成。仍需本人进行 Apple Account 登录、2FA、设备信任和开发者模式确认。T11 的自然到期还需要等待。 | 先用模拟包测双端安装和手动续签，固定账号及最终 bundle ID，先测到期前再测自然到期后。Wi‑Fi／自动续签仅在手动流程成功后再按需要检查。 |
| T04、T05 | 免费账号一栏有 HealthKit 基础能力。WatchBridge 本次实际 profile 和后台 entitlement 仍未知。 | 若 profile 未取得所需权限，保留错误及权限名，并向上游核实是否支持通过 Apple 正常开通能力。先用模拟包推进其它测试。真实健康读权限通过、后台投递缺失时，可在前台拉取最近样本并按批次回顾。 |
| T05、T06 | 后台唤醒和 Watch 通常的触感受到系统管理。无锁屏实测记录。 | 用系统允许的本地通知试验延迟提醒，单独核对通知许可、专注模式和实际 Watch 呈现。原阶段可先验收前台轻震和手动确认。 |
| T07 | 此阶段只用使用期间权限与前台单次位置。 | 若后台无法取得位置，保留事件时间、原始生理数据和定位状态，可让用户重新打开应用后补充地点，并将补记时间与事件时间一起保存。 |
| T08 | 后台自动开始录音与 Apple Watch 连续录音缺少已验证路径。 | 先验收 iPhone 前台确认后锁屏连续录音。波动发生时可由用户打开 iPhone 手动开始。 |
| 原生 ChatGPT 接入 | Windows 独立探针已完成实际官方推理。iPhone 尚无原生登录和推理联调。 | 后续再评估原生接入。当前 Windows 探针可用合成数据独立复测。失败时保留原始数据和失败状态，等待服务可用后手动重试。 |
| 正式需求 23:59 | iOS 系统决定后台任务时机。 | 用本地日期记录应总结日期，在系统给到执行机会或应用重开时补做。按日期和版本去重，等待正式开发时验证跨时区、跨日和重试。 |

[Apple 免费开发账号约束](https://developer.apple.com/help/account/basics/about-your-developer-account) · [后台任务调度](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler) · [OpenAI 错误与恢复](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
