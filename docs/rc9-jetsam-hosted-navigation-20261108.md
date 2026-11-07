# Jetsam：容器页面与 Preferences 选项页显式接线

日期：2026-11-08。用户确认复发包为 `8061130d`。
状态：220 项本地源码 / 契约回归通过；原生边界回归、完整包构建和真机待验。

## 已知事实

- 用户确认设置 / 关于的滚动问题修好，随后报告非 30 MB 的 Jetsam
  选择仍会返回默认 30 MB；本问题重新开放，不沿用先前已修复结论。
- `a3796238..8061130d` 没有修改 Jetsam 选择控制器、偏好管理器、
  设置 IPC 客户端或服务端的读写实现；主要相关变化是设置页外层容器。
- `8061130d` 的导航栈顶是 `DOPSListPageController`，真正持有 specifier
  与 Jetsam getter/setter 的 `DOSettingsController` 是其子控制器。
- 原选项值 / 标题仍为 Preferences 的字符串数据源选择器；
  选择页的 push 则依赖系统私有 Preferences 的默认实现。
- 本地只有框架接口头和链接 stub，没有 iOS 16 私有方法实现或该次选择
  回调记录。仅凭这些差异不能证明运行值真的被重置，也不能证明具体哪个
  私有方法在设备上选错了所有者。

## 本次范围

1. Jetsam 的原 specifier 直接使用 PSSpecifier 既有
   `setValues:titles:` 绑定相同的七档 NSNumber 与本地化标题。
   不再需要从父页反射解析两个数据源方法，不排序、不改默认 `6`。
2. 只对 `DOPSJetsamListItemsController`，在真正的设置控制器接到
   两种 Preferences push 入口时，先显式设置 `parentController=self`、
   `rootController=既有 root ?: self`，然后由原 UINavigationController
   推入同一个原生选项页。
3. 其他控制器和没有导航控制器的情形继续调用原父类入口；
   不添加容器通用消息代理，不重写原生七档点击实现或 checkmark。
4. 保留 source specifier 的 target、getter、setter、数值映射、运行值
   核实、原子偏好保存与失败提示。不使用本地偏好冒充实时生效值。
5. 只在打开选项页时记录绑定的 parent / target 类名；
   没有新增轮询、定时器、后台任务或常驻日志采样。

这是 RC9 自有容器与原生选项页的集成修正，不是官方已有的 Jetsam
补丁，也不宣称已经取得症状根因的运行时证明。
官方 RootHide 固定参考仍为 `3.0.13-30`、
`9617d75f476423fdfd33477299c8a1349eb6f375`；
保留官方原生 Jetsam 选项类与原有通信协议，不整文件覆盖。

## 回归边界

- 新增 `tests/test_rc9_jetsam_navigation.py`，约束七档内联绑定、
  push 前的 parent/root 赋值、两个入口、非 Jetsam 的父类回退以及
  运行值核实先于落盘的既有顺序。
- macOS 原生测试抽取生产 push 方法、七档数组、getter/setter 和偏好
  getter，编译实际 `DOPreferenceManager.m`。使用 Foundation 临时文件，
  检查未越狱 / 已越狱、既有 / 缺省 root、两个 push 入口、七档选择、
  保存后重开、其他键保持、运行写入失败、读取失败和落盘失败。
- 导航、Preferences 选择回调与 IPC 在此测试中都是明确的替身。
  “进入时可能已有错误父对象”只是边界测试输入，
  不是声称已经在设备测到的私有实现行为。
- 不执行真实 UIKit / 私有 Preferences、launchd IPC 或设备越狱，
  不能把主机往返通过写成真机 Jetsam 修好。
- Windows 220 项本地检查通过，`git diff --check` 通过；
  新原生测试加入 GitHub CI。

## 保留与验收

已获用户确认的设置 / 关于布局、回弹及外观代码不改；
低电量页面、执行器、注入、挂载、越狱底层与实际支持范围不改。
产品版本仍为 3.0.7，最低系统声明仍为 16.0，不扩大兼容矩阵。

完整构建与制品核验后，先在相同运行环境覆盖安装并关闭重开 App，
检查 `+20 MB`、`+40 MB` 及关闭档位：选中、返回重进、App 重开后是否保持。
本次仅改 App 接线；不会以“必须重启才能更新本次 App 修改”解释失败。
App 覆盖安装并不证明此前运行的底层组件已更新，这两件事仍分别记录。
出现现有错误提示时保留错误码；仍回退时需要结合 parent/target 打开日志、
请求 / 实际回读值继续判断，不将修正候选提前关闭为已解决。
