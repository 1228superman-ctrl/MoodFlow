# 表盘上的自动心情判断

0.3.0 提供「心绪 · 自动判断」表盘组件，支持圆形、矩形、单行文字和表盘角落。装好并打开一次手表 App 后，长按兼容的表盘，进入「编辑 → 复杂功能」，选择显示位置，再在列表中选「心绪 · 自动判断」。矩形位置同时显示判断、状态和样本时间。

从 0.3.1 起，表盘使用最近 30 分钟内的真实心率样本，普通心率记录也能触发判断。过去至少有三条相似的独立样本，并且确认的心情足够一致时，会显示「可能平静」等自动判断。个人记录不足或不一致时，会显示「心率平稳」「心率上升」或「心率下降」，只有一条近期样本时显示「有近期心率」。点按表盘可为对应样本确认或纠正心情。超过 30 分钟没有新样本时，表盘会回到等待数据。

表盘刷新由 watchOS 负责，时间随 HealthKit 样本和 WidgetKit 的调度而变化。表盘从本机共享容器只读取事件标识、时间和显示文字。原始生理数据、录音和定位继续保存在各自的 App 容器。 [Apple WidgetKit 表盘说明](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications) · [Apple 刷新频率说明](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

## 签名与验收

0.3.0 需要为 iPhone App、Watch App 和 Watch WidgetKit 扩展分别签名。Watch App 与扩展必须取得同一个 App Group，Watch App 还需要原来的 HealthKit 权限。构建产物只声明需要的权限。覆盖前需核对 Apple 签发的描述文件、二进制签名、原 App 标识及配对设备。旧版已验证的签名流程只能证明 iPhone 和 Watch App 两层包能安装，新增 WidgetKit 扩展需要单独检查。

真机验收包括在表盘添加组件、抬腕查看自动结果、轻点纠正对应事件、再次查看更新、确认旧记录与 Apple 健康读取正常。息屏时采样到表盘更新的延迟另测。

0.3.0 的健康版和模拟版已编译并核对包结构，五项模型行为均通过合成数据验证。双端模拟器也通过了 App 启动、确认及纠正记录保留测试。iPhone 模拟器首轮启动超时，重跑通过。 [设备构建](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/45299003979) · [双端模拟器](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/45299003994)

2026 年 11 月 24 日，已核对原手表 App 标识、配对设备、两项 HealthKit 权限，以及手表 App 和表盘组件使用同一 App Group。watchOS 已确认覆盖安装 0.3.0。配对 iPhone 保持原版本。用户确认能在真机表盘添加组件，并点按进入选心情页面。真实样本驱动的自动判断与刷新延迟待测。[真机安装日志](evidence/release-0.3/watch-face-install.log)

0.3.1 的健康版和模拟版均已通过设备构建。合成数据测试覆盖普通心率样本、单个样本、过期样本、个性化推测和同一条记录的确认或纠正。[设备构建与测试日志](https://github.com/1228superman-ctrl/MoodFlow/actions/runs/45305088683)

0.3.1 的真机验收从普通心率样本开始。打开手表 App 或使用「展示和权限 → 连接 Apple 健康」，回到表盘检查近期样本的状态及时间，确认一条心情后查看对应记录。后台更新另测。
