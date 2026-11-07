# RC9 iOS 16 选择条件初步盘点

日期：2026-11-07。源码基线 `8e560fa34d6f91a2942aaf7fe8e1b8407d94b514`。
这是选择器和随包元数据的初步盘点，不是完整设备/固件/漏洞/偏移兼容矩阵，
不证明任一新增组合已在真机越狱成功。本轮不修改漏洞、偏移或选择顺序。

## 实际检查层次

1. `DOEnvironmentManager.isSupported` 先限制系统版本为 `16.0` 至 `16.7.16`；
   区间上限和首页显示字符串本身不证明区间内所有设备都可越狱。
2. `DOExploitManager` 从最终应用 `Frameworks` 的 Info.plist 枚举可用实现，
   不是仅凭源码 `Exploits/*/Info.plist` 判断。
3. `DOExploit.isSupported` 检查版本区间、可选设备/CPU 集合及包含/排除 build；
   include/exclude 在基础匹配后继续运行，不能只读取 `DPSupportedRanges`。
4. 必须有可用 Kernel 实现；arm64e 还必须有可用 PPL 实现。
   当前 `isPACBypassRequired` 在 iOS 15.2 及以上返回 NO，因此 iOS 16
   不把独立 PAC 插件作为可用条件。是否成功加载/运行是之后的另一个门槛。
5. `Application/Makefile` 会用 `Prebuilt/Frameworks` 中的 ClearSword、
   DarkSword、Titan、momentarius 覆盖构建产物；本表同时核对了这些实际复制源的
   Info.plist，其 DP 选择元数据与对应源码 plist 一致。
   尚未重新解包本候选 TIPA 逐文件核验这些框架的元数据与二进制。

## 与 iOS 16 相交的声明

| 实现 | 类型 / 优先级 | 基础版本声明与 iOS 16 的交集 | 额外条件 |
| --- | --- | --- | --- |
| kfd physpuppet | Kernel / 1000 | 16.0–16.3.1 | plist 无额外设备排除 |
| kfd landa | Kernel / 900 | 16.0–16.6.1 | plist 无额外设备排除 |
| kfd smith | Kernel / 600 | 16.0–16.5 | 另有 build `20G5026e` 的 include |
| ClearSword | Kernel / 895 | 受全局上限约束后的 16.0–16.7.16 | 声明 `contiguousMapping` 要求 |
| DarkSword | Kernel / 890 | 受全局上限约束后的 16.0–16.7.16 | 声明 `contiguousMapping` 要求 |
| dmaFail | PPL / 1000 | 16.0–16.5.1 | A15/A16 的 `20F75` 被排除；另有四个 build 的 include |
| momentarius | PPL / 999 | 受全局上限约束后的 16.0–16.7.16 | 基础设备集合为 A12/A13 |
| Titan | PPL / 999 | 受全局上限约束后的 16.1–16.7.16 | 基础设备集合声明 A14/A15/A16/A17，不等于这些芯片都存在可安装 iOS 16 的实际设备组合 |

`dmaFail` 的四个 include build 是 `20G5026e`、`20G5037d`、
`20G5047d`、`20G5058d`。本表保留精确 build，不未经核实将其翻译成发行版本名称。
`DOExploit` 的 CPU 标签映射中 A14 同时涵盖 M1、A15 同时涵盖 M2；
这仍不是各 iPad 型号及固件可安装性/偏移的逐项验证。

ClearSword、DarkSword、momentarius、Titan 的 plist 含有 iOS 16 之外的声明，
但应用全局检查仍限制在 iOS 16。既有资源中保留这些声明不代表本轮移植或开放其他系统。
badRecovery、multicast_bytecopy、weightBufs 的基础区间及显式 build 没有新增
iOS 16 候选条件；不能把资源存在本身计作 iOS 16 可用实现。

## 仍需补齐

- 对最终 TIPA 内每个框架的选择元数据、架构、来源与二进制做对应检查。
- 按设备型号、CPU/架构、可安装固件与 build、Kernel/PPL 组合建立完整矩阵，
  对照相应实现和 XPF/硬编码偏移，不从宽泛版本区间推定支持。
- 核查连续映射等运行要求，以及框架 load/run/cleanup 的实际失败路径。
- 按组合记录真机重启后越狱、重复越狱、异常恢复与日常使用证据。
  用户对 `7ad14162` 的一般使用正常反馈不能替代这些逐项验收。
