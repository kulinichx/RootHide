# iPad 第七代 / 16.6 / fad8bbbd 早期退出排查

日期：2026-11-07。状态：**已定位用户界面停留阶段，退出原因未确认，未修复验收**。
初查时暂停发布 ChOma 第十六阶段。随后用户确认重启后可以看到“详细日志”，
将补充尝试日志，并明确要求先继续其余修复；因此恢复独立的第十六阶段测试与构建，
本设备故障继续保持待证据状态，不将另一批构建成功当作本故障已修复。

## 用户证据

- 用户报告设备为 iPad 第七代，系统 16.6；尚未提供硬件标识、系统 build。
- 安装包明确为 `Dopamine_3.0.7-fad8bbbd_roothide.tipa`。
- 用户报告官方包能成功越狱；官方包的准确版本、构建和所选 Kernel 实现待确认。
- 用户随后确认重启后已找到“详细日志”。核对 `fad8bbbd` 源码和实际包中的
  开关键、中文翻译后，确认它并非缺失功能；设置入口受支持状态和未越狱状态控制。
  用户将提供下一次尝试的日志，当前尚未收到。
- 截图依次显示 Patchfinding 已结束、候选链
  `kfd, landa (landa) -> ClearSword (default) -> DarkSword (default)`，
  当前停留在 `Trying kernel exploit: kfd, landa (landa)`，一会后应用退出。
- 该行在 `[candidate load]` / `[candidate run]` 前显示，截图本身不能证明
  已进入 `kopen` 的哪一个内部函数，也不能将退出归因于后两个候选、
  PPL、bootstrap、低电量计划或菜单。

## 已执行的只读检查

实际本地制品：
`artifacts/11-6/rc9-fad8bbbd/Application/Dopamine_3.0.7-fad8bbbd_roothide.tipa`。
SHA-256 与原包身份记录一致：
`345b14de7f688bca28570c6ed45dc4de1704c8b9174cdcc4e457a9f3ab695c48`。
包内 `kfd.framework`：

- `CFBundleIdentifier = com.opa334.kfd`，实际可执行文件为 `kfd`。
- Mach-O `cputype = 16777228`、`cpusubtype = 0`，含 arm64 实现；
  本检查不等同于真机 `dlopen`、签名或运行验证。
- 可执行文件 SHA-256：
  `a0fd7fe888435c0e29e46bf16e4c6f68925764eff262f12affbbedbc2abc61f2`。
- 实际包内 landa 优先级 900，iOS 16 声明区间 `16.0–16.6.1`，
  没有额外 include / exclude；不是单看源码 plist 得出的判断。

直接比较 `fad8bbbd` 与固定官方 RootHide 3.0.13-30
`9617d75f476423fdfd33477299c8a1349eb6f375`：

- `Application/Dopamine/Exploits/kfd` 整个源码目录无差异。
- `DOExploitManager.m` 无差异，`DOExploit.m` 只有空白差异。
- RC9 源码具有与官方相同的 extended-virtual-addressing /
  increased-memory-limit 权限声明，但没有借此断言系统最终授予的权限相同。
- `info.c` 仍有差异，已查看该 diff；比较函数写法与 16.1 的版本比较常量
  为等价写法，其他所见新增偏移位于更高系统分支，不构成本次已证实根因。
  这不是对所有动态偏移的验证。
- XPF 固定提交不同：RC9 `b703bf3b3fee75ea18c676cc00e87f9770957cc3`，
  官方 `9e12b8faa7444f6fe7f699aec6b6c96d151455d3`。当前工作树没有初始化
  XPF 子模块，本次没有获得这两个完整依赖对象进行逐函数比较。
  不因 Patchfinding 行打勾就认定所有输出偏移正确。

上述官方是固定源码参考，不将其视为用户成功包的已确认身份，
也不声称源码一致就证明两个构建产物或运行环境一致。

## 源码明确存在的退出路径

1. RC9 `DOJailbreaker._armWatchdogForStage:timeout:` 对 Kernel 候选使用
   120 秒计时；阶段仍匹配时打印 watchdog 信息并 `_exit(1)`。
   固定官方 `doExploitation` 没有这条 RC9 计时退出逻辑。
2. kfd 的 `libkfd.h` 启用 `CONFIG_ASSERT = 1`。
   `libkfd/common.h` 自定义 assert 在失败时打印错误、文件和行号，
   `sleep(30)` 后 `exit(1)`；该代码与固定官方相同。
3. 系统终止、加载失败、异常和其他分支尚无设备日志支持，不能排除。

截图没有可靠经过时间，也没有详细日志。因此不能把 30 秒或 120 秒路径
直接定为本次根因，更不能把退出改为继续执行来掩盖未建立的内核读写状态。
固定官方无需 RC9 的候选链，但 kfd 内部 `exit` 不会作为普通错误返回，
所以 RC9 候选列表存在也不保证能执行到下一候选。

## 下一项所需证据

- 在未越狱状态的设置页开启已有“详细日志”，记录同一次尝试退出前最后几行；
  截屏或短录屏均可，不需要先改 Kernel 选项或反复更换多个包。
- 记录从 `Trying kernel exploit` 到退出的大致时间。
- 如有同一时间的 Dopamine / JetsamEvent 系统分析记录，一并保留；
  主动 `exit(1)` 不保证生成普通崩溃记录，不能把“没有 .ips”当成没发生故障。
- 核实成功官方包的准确版本和 Kernel 选项，以便做同条件对照。

本次不修改漏洞选择、PUAF 数量、偏移、保护绕过或低电量后台逻辑，
不声称后续 `ca342e46` 或未发布的 ChOma 补丁已经修复此设备问题。
需要设备证据后再决定最小修复，并单独记录该组合的验收。
