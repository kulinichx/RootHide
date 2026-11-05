# RC9 每日低电量模式计划

日期：2026-11-05（Asia/Shanghai）。

## 范围

按用户提出的 Activator「计划事件」用法独立实现每日低电量模式计划，
不是把 Activator 的手势系统、注入库或未取得的源码整套移植到 RC9。
不依赖另外安装 Activator，不改 RC9 3.0.7 版本身份、授权、玻璃主题、
头像 / 壁纸、名单、挂载、VPN 偏好或既有快照修复。

入口：越狱状态下，多巴胺设置页「计划事件」。直接在同页设置「低电量模式」，
不增加第三级菜单；点击开启 / 关闭时间行，在当前页展开原生时间滚轮。

- 默认关闭；预设每天本地时间 00:00 开启，06:00 关闭。
- 开启 / 关闭时间均可按分钟修改，支持跨午夜，禁止两者相同。
- 修改后点右上角勾号保存；返回时对未保存修改提供放弃确认。
- 保存已启用的计划会立即应用当前时段应有的状态。
- 暂停计划只取消后续事件，不强制关闭或开启当前低电量模式。
- 手动切换低电量模式后，保持到下一计划事件，不按分钟强制覆盖。
- 应用关闭不负责停止计划；执行依赖越狱中的 SpringBoard。
- 关机、未越狱、相关运行端未加载或系统接口不兼容时，不承诺执行。
- 重启 SpringBoard / 恢复越狱后只补当前最近事件，不重放离线期间全部事件。
- 同一系统启动会话内保留已处理事件，整机重启后重新越狱则重新补当前状态；
  无法读取启动会话时不复用旧的磁盘执行记录。

## 实现与边界

### 设置与存储

独立的 `DOLowPowerScheduleController` 使用原生开关、时间滚轮、保存和
返回按钮；沿用现有深色、透明页面背景与授权判断，复用 RC9 的
`DOCustomLiquidGlassView`，一组设置共用一个玻璃面，不另加嵌套边框。
未授权状态显示标准分组背景。主题变化、页面布局和展开滚轮时重新更新玻璃范围。
滚轮不改变后台调度机制，开关及时间仅在保存后写入配置。

时间反馈参考本机 `G:/AITEST/GlassFolders 1.0/GlassFolders-Test3/prefs/GFRootListController.m`
的滑块刻度反馈：`UIImpactFeedbackStyleRigid`、强度 `0.68`、相同刻度去重和
`prepare`。RC9 使用原生 `UIDatePickerStyleWheels`，在用户修改时间且分钟值变化时
触发一次反馈；不复制滑块的 5% 步长，不钩取私有滚轮或增加后台计时。
触感频率由原生时间控件的值变更事件决定，实际触感仍须真机验收。
新增文件已列入 Xcode App Sources；提供英文及两份简体中文本地化，
其他语言沿用现有英文回退机制。

配置及状态保存在当前随机 RootHide 根目录下：

```text
var/mobile/Library/Preferences/com.dopaminerh.rc9.low-power-schedule.plist
var/mobile/Library/Preferences/com.dopaminerh.rc9.low-power-schedule.plist.status
```

App 通过既有 `runUnsandboxed:` 写自己的独立配置，不请求 root UID；
运行端通过 `jbclient_get_jbroot()` 解析同一当前随机根目录，不硬编码 `/var/jb`。
配置包括版本、真正的布尔开关、两个分钟值和独立修订 UUID。
采用原子二进制 plist 写入、0600 权限和 iOS 无锁屏文件保护选项；
读取要求普通文件且限制 16 KiB。不修改系统低电量偏好 plist。

配置变更和状态查询通过 Darwin notification 发送；配置写入失败不发更新通知。
页面等待运行端对本次配置修订的最新确认，不把「文件已保存」直接等同于
「后台已生效」。系统拒绝请求或私有接口不匹配时显示失败 / 不兼容状态。

### 执行端

`lowpowerschedule.m` 随既有 `roothidehooks.dylib` 构建，仅从 SpringBoard 的
`sbInit()` 启动；不向每个 App 安装新钩子，不修改 jailbreakd / launchd。

按 iOS 16 运行时头文件核对：

- `LowPowerMode.framework` 的 `_PMLowPowerMode`：
  `sharedInstance` / `setPowerMode:fromSource:`。
- `PersistentConnection.framework` 的 `PCPersistentTimer`：
  `initWithFireDate:serviceIdentifier:target:selector:userInfo:`、
  `scheduleInRunLoop:`、`invalidate`、`isValid` 及四个调度属性。
- 头文件读取来源：
  `https://github.com/qingralf/iOS16-Runtime-Headers` 的
  `PrivateFrameworks/LowPowerMode.framework/_PMLowPowerMode.h` 和
  `PrivateFrameworks/PersistentConnection.framework/PCPersistentTimer.h`。
- 这是私有接口声明的对照，不是 Apple 支持承诺，也不证明所有 iOS 16
  小版本有同样接口或权限。调用前检查类、selector、参数及返回 ABI，
  外围捕获 Objective-C 异常；不可用则停用此功能，不影响既有快照钩子。

两个可选系统框架仅在计划启用后按需加载；默认关闭时不加载、不安排计时器。

执行端在主队列串行重新读取配置，先确保下一事件计时器可用，再设置当前模式。
使用绝对状态设置，不使用 toggle。已处理事件的配置修订、日期和状态保存到
独立状态文件，并记录系统启动时间作为启动会话。同一次启动内同一事件
不重复执行，减少 respring 对手动状态的干扰；整机重启后不沿用旧会话
「已执行」记录，避免错过当前计划状态。

持久计时器允许系统唤醒，并关闭提前触发比例与提前间隔；不创建 App 的
后台常驻定时器，不做每分钟轮询。请求唤醒不等于已证明锁屏准时性，
真实 powerd 权限、深度休眠和不同机型仍需设备验收。

系统拒绝设置时，每事件最多首次请求加三次延迟重试，状态查询不会提前消耗
重试预算。普通情况只安排下一个开 / 关事件。
时钟 / 时区变化时重新按本地日历计算；不以固定 86400 秒表示下一天。
夏令时缺失时刻使用下一个有效时刻，重复时刻选择首次；若开 / 关事件收敛于
同一时刻，关闭优先。

## 验证记录

- 本机 Windows：85 项源码及既有回归通过，`git diff --check` 通过。
- 新增 macOS Foundation 原生回归，直接包含生产头文件和运行端，
  仅替换私有类、电量设置、计时器和当前时间 / 根目录边界。
- 用例覆盖四组计划的全天每分钟、00:00 / 06:00 边界、跨午夜、夏令时、
  配置校验、独立原子存储、缺失类 / ABI 不符、手动覆盖、respring、
  暂停后的旧回调、计时器失败、有限重试、异常和随机根切换。
- 原生回归启用 ASan / UBSan，并加入既有私有 CI 工作流。
- 本机没有 Xcode / Apple SDK；原生回归及完整新包构建状态须以本次 CI
  结果补充，不能借用旧包的成功状态。
- 真机低电量状态、锁屏 / 休眠时触发、充电交互及界面布局尚未验收。

## 真机验收

1. 首次进入时计划关闭，不改变系统低电量状态。
2. 先用几分钟后的开 / 关时间做短周期测试；保存后退出多巴胺，
   保持锁屏，核对两个时间点的真实状态，而不是只看 App 状态文字。
3. 再测试默认 00:00 → 06:00、23:00 → 06:00 和同日白天时段。
4. 计划生效期间手动切换，确认不会在下一事件之前反复改回。
5. 暂停后确认不再执行；相同时间拒绝保存；重新打开仍保留配置。
6. respring、越狱环境重新加载、修改系统时间 / 时区后核对恢复策略。
7. 充电到系统自动退出低电量模式时，不在同一事件内强制重新打开；
   下一事件继续按计划设置。
8. 核对原授权、主题、头像 / 壁纸、黑白名单、快照与原插件行为。

不需要卸载越狱、清空插件、删除授权或已有设置；原 `b6e8e62` 包保持不动。
