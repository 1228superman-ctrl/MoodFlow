# 表盘上的自动心情判断

0.3.0 提供「心绪 · 自动判断」表盘组件，支持圆形、矩形、单行文字和表盘角落。装好并打开一次手表 App 后，长按兼容的表盘，进入「编辑 → 复杂功能」，选择显示位置，再在列表中选「心绪 · 自动判断」。矩形位置同时显示判断、状态和样本时间。

有新的心率波动时，心绪会与过去由你确认过的相似波动比较。匹配样本足够、既往标签一致时，会显示「可能紧张」等自动判断。个体样本不足或不一致时，会显示「心率上升」或「心率下降」，标记待确认。结果超过 30 分钟后，表盘会回到等待数据。点表盘组件可在手表上选择心情，确认或纠正同一条波动。没有对应波动时，可以新记一次心情。

表盘刷新由 watchOS 负责，时间随 HealthKit 样本和 WidgetKit 的调度而变化。表盘从本机共享容器只读取事件标识、时间和显示文字。原始生理数据、录音和定位继续保存在各自的 App 容器。 [Apple WidgetKit 表盘说明](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications) · [Apple 刷新频率说明](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

## 签名与验收

0.3.0 需要为 iPhone App、Watch App 和 Watch WidgetKit 扩展分别签名。Watch App 与扩展必须取得同一个 App Group，Watch App 还需要原来的 HealthKit 权限。构建产物只声明需要的权限。覆盖前需核对 Apple 签发的描述文件、二进制签名、原 App 标识及配对设备。旧版已验证的签名流程只能证明 iPhone 和 Watch App 两层包能安装，新增 WidgetKit 扩展需要单独检查。

真机验收包括在表盘添加组件、抬腕查看自动结果、轻点纠正对应事件、再次查看更新、确认旧记录与 Apple 健康读取正常。息屏时采样到表盘更新的延迟另测。
