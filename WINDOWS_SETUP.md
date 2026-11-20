# Windows 编译、安装和验收

适用环境为 Windows 10 22H2 或 Windows 11 x64，使用已配对的 iPhone 与 Apple Watch，分别运行 iOS 26+ 和 watchOS 26+。准备一条支持数据传输的 USB 线。本文的登录、双重验证、开发者模式、设备信任和系统权限由测试者本人确认。

## 1. GitHub Actions

本次已完成的 [双端构建](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/44663667728) 生成两种 IPA。本地交付包的 `ipa/` 已包含两种 IPA，可直接进入下一节。以下步骤用于重新构建。

1. 将项目目录内容放在专用仓库根目录，包含隐藏目录 `.github`。公开仓库使用免费的标准 `macos-26` runner。仓库只放项目源码和已脱敏的证据。
2. 打开 **Actions → Build MoodFlow validation apps → Run workflow**。确认 `sim` 和 `health` 两项分别完成 iOS 和 watchOS 编译及 IPA 检查。下载产物 `moodflow-sim` 和 `moodflow-health`。
3. 解压 GitHub 产物 ZIP，保留内层 IPA。Windows 可使用以下两条命令比对 SHA-256。若具备 Python 3，可额外执行第三条检查 IPA 的目标平台和 companion 关系。

```powershell
Get-FileHash .\MoodFlow-sim.ipa -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
python scripts/check_ipa.py .\MoodFlow-sim.ipa
```

4. 保存运行 URL、提交 SHA、Xcode 版本、两端完整日志及产物哈希。编译产物随后由 WatchBridge 在 Windows 本地签名。

[GitHub 免费 runner 与用量](https://docs.github.com/en/actions/concepts/billing-and-usage) · [macOS 26 runner 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)

## 2. WatchBridge 安装和签名

1. 使用官方 Apple Devices 应用或 Apple 提供的 iTunes 安装 Apple Mobile Device Service。检查服务正在运行，并确认 Windows 可识别已解锁的 iPhone。需要 WebView2。
2. 从 [WatchBridge 0.1.6 发布页](https://github.com/AdminZachary/WatchBridge/releases/tag/v0.1.6) 获取 `watchbridge-windows.zip`。解压、核对发布来源及包内 `SHA256SUMS.txt`。该版本的 Windows EXE 未签名，由测试者判断是否接受运行；确认来源前先停在提示页面。
3. USB 连接已与手表配对的 iPhone。在 iPhone 选择信任，WatchBridge 选择设备并为手表准备开发者模式。按设备提示在 iPhone／Watch 开启开发者模式、重启并确认。再次检查状态。
4. 在 WatchBridge 登录 Apple Account 并亲自完成 2FA。首次用 `MoodFlow-sim.ipa` 验证手机和手表安装链路。在两端分别手动打开应用并记录结果。
5. 使用同一账号和设备安装 `MoodFlow-health.ipa`。记录 WatchBridge 最终 bundle ID、安装时间、profile 到期时间，以及两端 profile／签名是否包含 `com.apple.developer.healthkit` 和 `com.apple.developer.healthkit.background-delivery`。保留足以判断状态的本机证据。若工具界面无法查到能力，记录未知并继续用实际授权及样本验证。
6. 若失败，记录失败阶段和错误域／代码。保留当时装好的版本与数据，避免为诊断而删除 App、重置设备或撤销可能被其他应用使用的证书。两种包使用同一原始 bundle ID；复测前记下当前安装的版本及关键证据，WatchBridge 改写后的实际 ID 以工具结果为准。

[WatchBridge 工作方式](https://github.com/AdminZachary/WatchBridge#how-it-works) · [Apple 开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 3. 真机测量

| 项目 | 操作和合格证据 |
| --- | --- |
| T03 | 双端手动冷启动。记录系统、设备型号、构建版本和双端界面，隐藏序列号、UDID 与账号。 |
| T04 | 先在 Apple 健康中确认最近 7 天确有三类样本。打开健康版，选择「授权并读取健康样本」，逐类同意并比对最近心率 bpm、HRV SDNN ms 和睡眠阶段／时间。分别记录手机和 Watch。空查询也可能表示拒绝、时间范围不足或样本未同步。 |
| T05 | 两端点「注册后台观察」，逐类记录结果。先记录 15 分钟前台基线，再锁屏／降腕并退离应用观察至少两小时，睡眠类型可加测一夜。保留普通佩戴场景。记录每小时不同样本数、回调次数、样本到回调的延迟及最大间隔。样本时间用于测量，收到回调的系统时间用于核对延迟。通知可能批量到达，重复或启动后才返回的记录要单独标记。 |
| T06 | 用模拟包在手表前台注入波动，戴在腕上确认感到一次轻震。两次注入分别提交「确认愉快」和「纠正为紧张」，重开后查找对应事件编号及反馈。锁屏时的震动单独记录，当前探针提供前台轻震。 |
| T07 | 先开「前台事件定位」并同意，再注入模拟波动。用事件编号核对位置结果、误差和 25 秒超时，分别测试同意与拒绝。若健康版实测出现真实心率变化事件，再复测一次真实触发。锁屏时记下跳过或未发生回调的实际结果，后台定位仍是单独待验证项。 |
| T08 | 在 iPhone 前台确认测试者与在场者同意，点击「同意并开始录音」，首次在系统弹窗允许麦克风。开始约 10 秒后锁屏，全程提供持续的无隐私测试音源。180 秒后查看本机日志记录的文件可读时长，目标约 180 秒。另测手动停止、麦克风拒绝和系统中断。当前探针使用 iPhone 麦克风。 |
| T10 | 运行 Windows 模拟测试。T09 成功后可单独在受控测试场景复测授权撤销和网络不可用，保留原始样本文件、失败状态与无摘要的证据。使用本机现有网络配置，无需消耗实际额度来制造限额错误。 |
| T11 | 用模拟包在两端生成几条易识别的事件和反馈并记下编号。到期前先测试同 Apple Account、相同最终 bundle ID 的覆盖续签，记录新旧到期日期及双端编号。再在一次自然到期后重复验证。通过条件为续签前后两端都能打开，且先前的数据仍在。 |

[HealthKit 读权限](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) · [后台投递频率](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))

## 4. 官方 ChatGPT 计划试验

准备 Node.js 22.12+、npm、Git，安装位置选在 MoodFlow 仓库外。官方 SDK 通过浏览器登录、IPv4 回环回调和本人授权使用合资格的 ChatGPT 计划，使用 Windows DPAPI 当前用户保护 OAuth 凭据。

```powershell
# 从 MoodFlow 项目根目录执行
git clone https://github.com/openai/sign-in-with-chatgpt-devkit.git ..\siwc-devkit
git -C ..\siwc-devkit checkout --detach 0a36fefeb913055c8c7a1a29b63d82b96b2e841a
npm.cmd --prefix ..\siwc-devkit ci --ignore-scripts --no-audit --no-fund
npm.cmd --prefix ..\siwc-devkit run build -w @siwc/local
node ai/probe.mjs check-dpapi
node ai/probe.mjs sign-in ..\siwc-devkit ..\moodflow-private
node ai/probe.mjs analyze ..\siwc-devkit ..\moodflow-private
```

若 Git 克隆受阻，可从 [同一提交的 GitHub ZIP](https://github.com/openai/sign-in-with-chatgpt-devkit/archive/0a36fefeb913055c8c7a1a29b63d82b96b2e841a.zip) 提取，并把各命令的 DevKit 路径改为所解压的目录。

登录成功且 `sharing:true` 后执行分析。只有官方 SDK 等到流完成、返回非空分析，并且结果写入本地时，T09 才通过。Windows 探针每次发送固定的虚构数据，使用官方 Responses API。若登录发现端点返回 403、账号不合资格或额度不足，保留失败证据并停止本次分析。需要断开时运行 `node ai/probe.mjs disconnect ..\siwc-devkit ..\moodflow-private`，同时可从 ChatGPT 设置管理授权。

[OpenAI 官方接入示例](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt) · [注册及回调](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) · [模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
