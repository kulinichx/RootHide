# RC9 配套工具入口与挂载/信任边界

日期：2026-11-07。RC9 代码基线为 `7ad14162`；仅对照固定源码，
不把它们称为远端当前最新版本。

## 固定参考与已核实差异

| 范围 | 官方 RootHide `9617d75f` | ZQBB RootHide `7e14aa61` | RC9 本轮前的 `7ad14162` |
| --- | --- | --- | --- |
| 可选白名单管理器入口 | 无同名入口 | 设置页打开 `cn.zqbb.inject.manager` 的 Sileo 详情 | 尚无同名入口 |
| 可选挂载管理器入口 | 无同名入口 | 设置页打开 `cn.zqbb.hello.mnt` 的 Sileo 详情 | 尚无同名入口；已有自定义挂载设置 |
| Sileo URL scheme | 无 `sileoURLScheme` 方法 | 从 jbroot 的 Sileo Info.plist 读取，失败回退 `sileo` | 尚无同名方法 |
| RC9 自定义挂载列表 | 无对应用户列表接口 | 无对应用户列表接口 | 独立扩展管理 `/mnt/newFakePath.plist`，调用 `jbctl internal mount/unmount` |

对照依据是两个提交中的 `DOSettingsController.m`、
`DOEnvironmentManager.h/.m`，以及 RC9 的
`DOEnvironmentManager+RCFakeMounts.m`。本轮不使用旧目录名称推断版本，
而是直接读取固定 Git 对象。

## 功能边界

- Sileo 入口只是用户主动打开包详情，不安装包、不启停守护进程，
  不写入 `cn.zqbb.inject.plist`，不改变默认黑名单或用户已有模式。
- ZQBB 的外置挂载管理器不是 RC9 自定义挂载 API；没有核实其独立源码与
  配置契约前，不将两个功能合并或迁移配置。
- 挂载信任与 VPN/代理告警偏好属于独立管理器中的功能；
  `tools/manager-trust` 保存的适配源码不是 Dopamine 上游自身提供的设置。
  不能因应用入口对齐就宣称两个管理器或底层挂载实现已全面对齐。
- 此轮只补齐已有上游实现的两个可选入口和 Sileo scheme 读取；
  不调整表格滚动、回弹、玻璃渲染、菜单层级或已有挂载执行路径。
- iOS 16 适配范围不变；跳转入口不构成对外置包可安装性或运行兼容性的证明，
  是否安装由用户在包管理器中决定。

## 验证状态

- 已补齐两个越狱后可见的入口，复用现有 `DOButtonCell` 和 `buttonHeight`；
  不新增子菜单。点击只打开对应包详情。
- `sileoURLScheme` 方法体与固定 ZQBB 源码逐字一致，
  SHA-256 为 `813c3faf48f5c6f9bde1f2e987ef895a163d84b20813b6fe83ea2313cba2019d`。
- 失败提示沿用上游文案，使用 RC9 已存在的错误/确认本地化键，
  并显式派发到主队列呈现；补充英文和两份简体中文资源。
- 新增 6 项源码契约检查，本地全套 `unittest` 共 154 项通过，
  `git diff --check` 通过。既有 UI 和挂载方法体一致性回归均通过。
- Foundation 原生用例抽取生产 scheme 方法，读写真正的临时 plist，
  检查重写 scheme、未越狱、缺失/错误类型/损坏配置及读取不改变文件。
  它不模拟或执行 Sileo、UIKit 页面跳转或外置包安装。
- 原生用例作为独立步骤接入 macOS CI；当前 Windows 无 Clang/Foundation，
  新原生用例、完整 TIPA 构建和新入口真机验收尚未执行，不标为通过。

本轮关闭的是配套工具入口缺口，不是外置管理器的运行时审计。
两个固定 Dopamine 源码对象中未检出 `TrustedBindMountsV1`、
`IgnoreVPNProxyWarningV1` 或 `newFakePath`；RC9 工具目录中的信任适配
仍有独立来源、构建和验收记录，不合并为 Dopamine 本体的上游等价实现。
