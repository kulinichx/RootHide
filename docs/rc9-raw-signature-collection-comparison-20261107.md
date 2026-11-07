# RC9 原始签名收集错误传播核查

日期：2026-11-07。运行时代码基线 `d173d36e`，前置验收文档 `5049828e`。
固定官方 RootHide 参考为 `9617d75f476423fdfd33477299c8a1349eb6f375`，
固定 ZQBB RootHide 参考为 `7e14aa6155ce867e9052a88a8c17c632f4c30d77`。
本轮直接读取上述 Git 对象，不称为重新检查远端最新版本。

## 对照证据

| 路径 | 固定参考与 RC9 基线 | 本轮处理 |
| --- | --- | --- |
| 官方和 ZQBB 的 `fat_collect_signatures` | 返回 `void`，读取结果为空就跳过，不能区分没有签名和读取/解析失败 | 不照搬这项失败语义 |
| ZQBB 及已移植的 RC9 adhoc 收集路径 | 先枚举 `LC_CODE_SIGNATURE`；不存在为正常跳过，枚举或读取失败为错误 | 抽为共用的内部三态读取函数，保留原 adhoc 行为 |
| RC9 `fat_collect_signatures` | 已有状态返回、分配失败清理，但仍会把空读取当作正常跳过 | 对同样的可映射切片使用共用三态检查；真实错误停止收集并清空输出 |
| RC9 `systemwide_trust_file` | 已检查 `file_collect_signatures` 状态，失败时关闭本次 FD 并返回；成功后才调用 `trust_signatures` 和可选附加 | 保持该调用约定，不改信任和附加成功路径 |

这不是从官方或 ZQBB 复制一个已经完成的 raw-collector 修复。它复用已对齐的
三态检查模式，补上 RC9 原始签名收集入口的同类缺口，归为有源码证据的本地加固。

## 修改范围

- `macho_read_code_signature_checked`：`1` 为读到签名，`0` 为没有签名命令，
  `-1` 为参数、命令枚举或签名读取失败。输出指针在有效输出参数下先清空。
- adhoc helper 调用这个共用读取函数；保留解码、adhoc 判定与 cdhash 成功/失败语义。
- raw collector 遇到真实错误返回既有 `ENOEXEC`，停止处理后续切片，
  释放之前收集的全部 buffer 与数组，不发布半份结果。
- 数量到 `UINT32_MAX` 时释放当前 buffer 并返回 `EOVERFLOW`；
  先转换为 `size_t` 再计算下一次数组大小，匹配已有 iOS 16 的 64 位构建范围。
- 保留无签名、不可映射切片、空集合的正常成功；保留原有 source、
  slice 文件起点、buffer 和声明长度元数据，不新增 raw collector 的 adhoc 过滤。
- 保留已有 `ENOMEM` 数组扩展失败路径；若 Fat 输入为空且输出参数有效，
  先清空输出再返回 `EINVAL`，与其他 collector 约定一致。

本轮不修改 ChOma 补丁或 gitlink，不改任何 UI、玻璃/滚动/回弹、
低电量计划、挂载、黑白名单选择、产品版本或系统支持选择器。
仍为 `3.0.7`、最低 iOS `16.0`，仅保留既有实际可越狱的 iOS 16 设备/固件组合。

## 验证

Windows 本地完整源码/契约回归 **169 项通过**；`git diff --check` 通过。

新增 `tests/test_rc9_signature_raw_collection.py --native`：
直接抽取真实共用读取函数、raw collector 和文件包装函数，
使用实际 `signatures.h` 与固定 ChOma 头文件；没有手写替代 `MachO`、
`Fat`、`CS_SuperBlob`、`siginfo` 或文件签名结构体。
外部 Mach-O I/O、stream/Fat 构造和释放动作由测试替身提供，
因此这不是解析器实现、真实文件系统或 iOS 内核 ABI 测试。

原生用例检查直接 Fat 入口和文件包装入口：

- 三个切片成功，source、大小与文件起点保留。
- 首个、中间、最后一个切片的命令枚举或读取分别失败，确认停止、输出清空、
  早先 buffer 清理及包装入口释放。
- 各位置数组扩展失败时，当前 buffer 和早先结果全部释放。
- 无签名、不可映射、全部跳过、空集合、无效参数与 stream/Fat 构造失败。
- 不可映射切片不执行命令枚举或读取；真正无签名不错误地调用签名读取。

原 adhoc 原生回归已同步抽取共用读取函数，继续覆盖其已有成功、失败、
Cryptex/TrollStore 过滤及随机化策略。调用方停止信任/附加的顺序是源码契约检查，
不冒充已在该原生 harness 中执行整个 `systemwide_trust_file`。
`UINT32_MAX` 极限数量保护做源码约束，不以实际分配数十亿切片来做原生试验。

已在 macOS CI 接入独立 raw-collection 原生步骤。当前本地没有 Clang/Apple SDK；
新增 ASan/UBSan、既有原生回归、完整 TIPA 和包身份检查待本轮 CI，
真机验收仍单独记录。

### CI 验收补记

代码提交 `d140ebbf417148e1a46522b71e2c3aa01b8635aa` 的 GitHub Run
`42373722237` 已成功完成，更新本轮前述 CI 待验状态：
源码回归、既有运行时原生回归、签名附加/来源读取、真实 ChOma、
新增 raw-collection ASan/UBSan、配套工具 scheme、完整 TIPA、
包身份检查与制品上传均通过。这是 macOS CI 结果，不是 Windows 本机原生执行。

制品名 `Dopamine_3.0.7-d140ebbf_roothide.tipa`，artifact ID `13575075586`。
GitHub artifact 归档 digest：
`sha256:6474a54863ac3e2873ae0d38fbdd0ad0774869ffc697eb442e8b979cb685fc4e`。
该值不冒充归档内 TIPA 文件本身的 SHA-256。新包设备验收尚未完成；
此前 `7ad14162` 的普通安装/使用反馈不转移到本候选。

验收补记只修改文档；本轮包和代码身份保持为 `d140ebbf`。

## 未关闭事项

本轮替代第十三阶段记录中 raw collector 空读取静默跳过这一项，不表示整个
签名模块已关闭。

- `macho_read_code_signature` 仍只返回指针，无法从空指针区分 I/O、内存不足或
  非法外层容器；上层使用已有通用 `ENOEXEC`，不伪造更精确的底层原因。
- 合法外层容器内的 CodeDirectory 内部结构，以及 `trust_signatures` 的其他
  跳过语义仍需审计；本轮不新增内部字段校验。
- `roothider/signatures.m` 的递归依赖收集仍存在解析/哈希或随机化失败未统一
  进入 `collectionFailed` 的分支；不得将本轮 raw collector 修复覆盖到它。
- 多次读取之间文件/命令发生变化没有整文件快照保证；已经完成的随机化或信任缓存
  发布不会因为后续 raw 收集失败自动回滚。
- trustcache 内核读者生命周期、dyld/live basebin 中断恢复及全部受支持 iOS 16
  设备/固件组合的真机验证仍开放。本轮不诊断为用户此前重启或界面问题的根因。
