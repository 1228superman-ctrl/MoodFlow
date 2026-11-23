# 心绪 0.2.0 测试版

用 WatchBridge 选择本次对应的 IPA，使用与旧版相同的 Apple Account 和最终 bundle ID 覆盖安装，再分别打开 iPhone 和 Apple Watch 上的「心绪」。应用沿用旧版本的本地日志目录，并可读取旧版日志中的录音。升级前可在 WatchBridge 查看最终 bundle ID，确认两端仍指向同一安装。

## 在设备上使用

- **今天**可以直接记下六种心情，确认或纠正波动，查看身体电量、压力、心率、HRV、睡眠以及心率趋势。身体电量和压力是本机根据现有样本估算的分数。多次确认同类波动后，应用会参考近似波动记录提供建议，最终标签由用户决定。
- **设置**里可以连接 Apple 健康，按需启用单次事件定位和后台波动提醒。系统提供样本时，应用检查心率升降；手表前台检测到波动时会请求一次轻触反馈。后台由系统决定投递时间及通知表现，位置尝试目前适用于应用在前台的场景。
- **回顾**提供情绪日历、基于本机坐标的点位地图、录音播放和中文本地转写。由用户在 iPhone 明确确认后启动录音，最长三分钟。能否锁屏持续、实际位置精度及手表的后台反馈需要在真机实测。
- **Apple Watch**的「展示和权限」有 12 个 App 内展示模板。手表可直接记录、确认或纠正心情。配对设备之间用 Apple Watch Connectivity 同步事件、标签、位置及健康摘要，录音与转写留在原设备。
- **总结**包含按日期准备、历史、重新总结和失败重试。应用在当地 23:59 尝试创建当天的待分析任务，系统未调度时重开 App 会补做有事件的日期。当前在 Windows 使用官方 ChatGPT 授权完成分析，随后导回手机。

健康版需由签名配置提供 HealthKit 相关能力，并在设备上允许读取。模拟版可在「设置 → 载入模拟数据」先体验界面和反馈；模拟指标不会作为真实生理样本送去分析。

## 用 Windows 生成总结

1. 在 iPhone 的「总结 → 历史」选择待处理日期，确认导出当天的情绪计数和可用生理指标平均值。可以选「我的 iPhone」保存在本机。导出的内容没有音频、转写、坐标、账号资料和原始样本。
2. 将导出位置选为「我的 iPhone → 心绪」。在 Windows 打开 Apple 设备，连接并选择 iPhone，在「文件 → 心绪」把申请文件保存到 Windows 本地目录。沿用第一阶段 [Windows 安装教程](WINDOWS_SETUP.md) 中的官方 DevKit 和存储目录。若授权过期，先在该目录重新完成官方登录。
3. 在项目目录执行以下命令，最后一个参数换成导出的文件路径。若需沿用系统已有代理，按安装教程使用当前终端的参数。

```powershell
node ai/probe.mjs summarize ..\siwc-devkit ..\moodflow-private 'D:\MoodFlow\moodflow-2026-11-23-request.json'
```

4. 用 Windows「Apple 设备 → 文件 → 心绪」添加结果文件。在 iPhone 的「总结 → 导入 ChatGPT 结果」从「我的 iPhone → 心绪」选中该文件。成功完成的结果会显示在对应日期，有额度、网络或授权错误时会显示可重试状态。历史事件、录音与转写保存在应用内部目录，文件共享区只有你另外保存或导入的文件。

[OpenAI 计划使用认证](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) · [Apple 后台调度](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)
