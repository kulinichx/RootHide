# RC9 递归签名收集失败处理与安装入口调整

日期：2026-11-07。代码基线 `d140ebbf`，本轮前的文档提交 `5f93db94`。
固定官方 RootHide 3.0.13-30：`9617d75f476423fdfd33477299c8a1349eb6f375`；
固定 ZQBB RootHide：`7e14aa6155ce867e9052a88a8c17c632f4c30d77`。
本轮直接核对本地 Git 对象，不声称重新确认远端当前最新版本。

## 源码对照与分类

| 位置 | 官方 / ZQBB 固定参考 | RC9 原有状态与本轮处理 |
| --- | --- | --- |
| `BaseBin/libroothider/src/signatures.m` 的签名收集 | 空读取或解码失败直接跳过，哈希失败不统一报告，随机化失败只记录日志 | RC9 对应代码位于 `BaseBin/libjailbreak/src/roothider/signatures.m`；使用此前已移植的三态 helper，将可报告的读取、解码和哈希失败汇入既有失败清理路径 |
| 递归数组扩展 | 直接更新数量并使用 `realloc`，没有完整失败保护 | 保留 RC9 原有分配失败处理，增加数量上限与 `size_t` 大小计算，循环索引改用 `uint32_t` |
| 随机化失败 | 只打印日志，可能仍返回其他依赖的部分结果 | 设置既有 `collectionFailed`，停止后续依赖、释放本次结果并返回失败 |
| 递归依赖遍历 | 已知 cdhash / 非 adhoc 的提前返回规则 | 保留 RC9 已有的 adhoc 依赖继续遍历；可信或重复哈希仍可检查变化的依赖，路径集合防循环 |
| 配套安装入口 | ZQBB 设置提供白名单与挂载管理器 Sileo 跳转；官方固定参考没有同名入口 | 按用户明确要求移除 RC9 的这两行及私有跳转方法，记为有意保留差异，不记为对齐遗漏 |

签名失败传播是 RC9 本地补强，不宣称官方或 ZQBB 已经修复了这条递归路径。
复用的 `macho_collect_adhoc_cdhash` 由内部静态函数改为在 `signatures.h`
声明的共用函数；它的原三态与计算行为不变，没有另写第二套解码逻辑。

## 行为边界

- 无签名或非 adhoc 仍正常跳过；可报告的命令枚举失败、已有签名读取失败、
  解码失败、哈希失败和随机化失败不再作为递归收集成功返回。
- 公共入口验证输出参数、路径及架构数组，在有效输出参数下先清空输出。
  失败返回既有 `-1`；没有伪造底层细分错误码。
- 随机化成功后仍收集最终哈希；已可信哈希不重复随机化。
- 未解析路径、缺失文件、Fat 初始化失败及无可用切片的既有跳过策略不改，
  不能把它们全部解释成必须报错的签名文件。
- Cryptex、可移除应用 / TrollStore、jbroot 与挂载过滤、首选架构、
  `@loader_path` / `@executable_path` / `@rpath` 解析和路径缓存规则保留。
- 上层 `trust_macho_recurse` 既有逻辑在收集失败时先返回，后续批量信任
  上传不会执行；本轮没有重写调用方。
- 已经发生的 jbroot 链接准备或文件随机化不会因后续失败自动回滚。
  清空结果不是文件系统或 trustcache 事务。

## 两个安装入口

按用户要求删除设置页中的“安装白名单管理器”“安装挂载管理器”两行、
对应 action、仅供它们使用的 Sileo 跳转方法与三份翻译中的失效文案。
不卸载独立管理器、不删除用户配置、不切换注入模式，不动 RC9 自定义挂载功能。

只读的 `sileoURLScheme` 兼容方法及其回归暂保留；移除入口后没有该方法的
生产调用点，不创建后台任务。第十一阶段的入口移植与构建记录保留为历史证据，
不代表当前版本仍显示入口。后续对照不自动重新加入这两项。

设置页只删除 specifier；没有修改滚动、回弹、玻璃合成、行高或菜单层级代码。
低电量计划及其他 RC9 扩展不变。产品版本保持 `3.0.7`，最低 iOS `16.0`；
支持范围仍是既有真正可越狱的 iOS 16 设备 / 固件组合，不扩展成所有设备
都能越狱任意 iOS 16 版本。

## 验证

Windows 完整源码 / 契约回归 **175 项通过**，`git diff --check` 通过。
新增 `tests/test_rc9_recursive_signatures.py --native` 并接入独立 CI 步骤：

- 抽取真实共用读取 / adhoc helper、递归处理 / 公共包装函数，以及真实
  loader / executable / rpath 解析和缓存函数。
- 使用实际 `signatures.h`、固定 ChOma 头文件及其 `MachO`、`Fat`、
  `CS_SuperBlob`、`CS_DecodedSuperBlob` 类型；不手写替代布局。
- Foundation 集合、临时文件、`open` / `fcntl(F_GETPATH)` / `stat` /
  `statfs` 和路径解析实际运行；ChOma 解析、RootHide 副作用、随机化及
  trustcache 查询由测试替身提供。
- 根节点及首 / 中 / 末依赖分别注入命令枚举、读取、解码、哈希、
  随机化和每次数组扩展失败，检查停止遍历、输出清空和临时资源释放。
- 检查最终随机化哈希、重复收集、可信与重复哈希的继续遍历、循环依赖、
  实际 `@rpath` 解析、首选架构请求、无签名 / 非 adhoc / 缺失文件 /
  不可解析 Fat / 无切片 / 可移除应用的既有跳过、TrollStore 放行及无效参数。

`UINT32_MAX` 保护、Cryptex 过滤及上层不上传顺序做源码约束；
没有分配数十亿条结果、访问真实 Cryptex 或执行完整内核上传来冒充原生覆盖。
原生用例也不证明真实 ARM64 切片选择、解析器内部或 iOS 私有 ABI 正确。
Windows 本机没有 macOS Clang / Apple SDK；新增 ASan/UBSan、完整 TIPA、
包身份与上传状态以本轮 CI 后续记录为准，当前仍待执行。

### CI 验收补记

代码提交 `ca342e467c77fa6d39b759de6a1437db2c7deba8` 的 GitHub Run
`42375351008` 首次运行已成功完成，更新上文 CI 待验状态：
新增递归收集 ASan/UBSan、实际 ChOma、raw / adhoc 与其他既有原生回归、
源码回归、保留的 scheme 原生检查、完整 TIPA、包身份及上传均通过。
它们是 macOS CI 结果，不是 Windows 本机的原生执行或设备验收。

实际制品：`Dopamine_3.0.7-ca342e46_roothide.tipa`；
artifact ID `13575647431`，GitHub artifact 归档 digest：
`sha256:6b67b950ba6e9009de9f366e9157c4c5c99ca1cac2b4fbd6556a29f3d9986568`。
此值不冒充归档内 TIPA 文件本身的 SHA-256。新包的 iOS 16 真机验收待完成；
此前 `7ad14162` 的一般使用反馈不移作本候选验收。

这次验收补记只修改文档，包和运行时代码身份继续对应 `ca342e46`。

## 仍开放的实际缺口

- 固定 ChOma 的 `macho_enumerate_dependencies` / `macho_enumerate_rpaths`
  当前丢弃底层枚举状态，始终返回 `0`；部分畸形命令只警告跳过。
  `macho_enumerate_load_commands` 也存在读取失败继续、越界提前停止仍返回
  `0` 的分支。本轮只能处理它明确上报的失败，不宣称全部解析错误已贯通。
- 依赖名及 rpath 长度 / 终止边界、CodeDirectory 内部字段、并发改写的一致性
  和剩余 stream 分配路径仍需单独核查。
- 递归文件解析、路径解析失败是否应按强 / 弱依赖细分，需要结合 dyld 和
  上游具体语义后再改，不能一律改成失败。
- trustcache 内核读者生命周期、dyld / live basebin 中断恢复、
  fork 其他资源生命周期和受支持 iOS 16 设备验证仍未关闭。
