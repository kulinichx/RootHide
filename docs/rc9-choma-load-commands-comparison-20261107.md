# RC9 ChOma 命令与依赖路径失败处理

日期：2026-11-07。运行时代码基线 `ca342e46`，本轮前文档提交 `2ef30f6a`。
保留 RC9 ChOma gitlink `ed99ac526142e78a5bc99793cf433775040f9d67`，
通过已有 `.github/patches/ChOma-signature-boundaries.patch` 维护依赖补丁，
不直接更换整套依赖或抬高 iOS 支持要求。

## 固定参考与证据边界

- 官方 RootHide 3.0.13-30 父提交：
  `9617d75f476423fdfd33477299c8a1349eb6f375`；
  其 ChOma gitlink 是 `7dccded6bc17081c08f5f5cdbd7a4b051543a825`。
  本轮直接读取本地 Git 对象中的三个枚举函数，其相关分支同样存在读取失败
  继续、截断仍成功、文件控制的栈数组、路径终止判断越界和枚举状态丢弃。
- ZQBB 父提交：`7e14aa6155ce867e9052a88a8c17c632f4c30d77`；
  其 ChOma gitlink 是 `4e4f8849e7a2025ab1717fe0a214d6363b9c1cc6`。
  本地没有该依赖对象；按 `.gitmodules` 中的
  `https://github.com/opa334/ChOma` 精确获取返回 `not our ref`。
  不将父仓库可读等同于该依赖源码已经对照，不猜测它是否已修复。
- RC9 固定依赖的相关实现可直接核对。本轮分类为依据源码确认缺口的
  **RC9 本地补强**，不是宣称照搬了上游已经完成的修复。
  这些是固定参考，不声称重新确认远端当前最新版本。

## 本轮修改

| 位置 | 修改 | 保留行为 |
| --- | --- | --- |
| `macho_enumerate_load_commands` | 校验输入、实际流长度、命令区与每条命令边界；头部或完整命令读取失败立即返回；使用受检堆分配并释放；拒绝两次读取间 `cmd` / `cmdsize` 形状变化 | 原有 1–1000 命令数限制、未知命令跳过、调用方主动提前停止成功 |
| `macho_enumerate_dependencies` | 转型和字节序处理前检查 `dylib_command` 大小；检查名称偏移、非空和范围内 NUL；传递底层与本层失败 | 五类现有依赖命令及正常回调行为 |
| `macho_enumerate_rpaths` | 先检查 `rpath_command` 大小；使用外层已验证长度限制字符串扫描；传递底层与本层失败 | 正常 rpath 回调及主动停止行为 |
| RC9 递归签名调用方 | 接收依赖 / rpath 枚举失败与 UTF-8 转换失败，停止收集并走已有部分结果清理；失败的 rpath 不写入缓存 | 既有路径展开、可信 / 重复哈希继续遍历、无签名与其他普通跳过策略 |

实际解析错误不再冒充“没有找到 rpath”，也不会继续尝试工作目录回退。
普通未解析路径、缺失文件、Fat 初始化失败、无可用切片仍采用原有策略；
本轮没有按强 / 弱依赖重写 dyld 解析语义。

依赖补丁现在包含 `BufferedStream.c`、`CSBlob.c`、`CSBlob.h` 和
`MachO.c` 四个文件。补丁 SHA-256：
`7ad486dc9c33be88b53d827738f6854ce6a312e2089a33bb7d0b49c3beb443e7`。
已检查它能应用到固定依赖的干净临时索引，并能从当前已应用目录反向校验；
没有重置依赖工作区或提交脏 submodule gitlink。
CI 额外记录实际 `MachO.c` 的 SHA-256。

## 验证

Windows 完整源码 / 契约回归 **179 项通过**，`git diff --check` 通过。
新增 `tests/test_rc9_choma_load_commands.py --native`，接入独立 macOS CI：

- 使用固定依赖真实头文件、类型、`BufferedStream.c`、实际流读取函数、
  命令名称函数、头部长度函数和三个枚举函数，不另写测试版解析器。
- 对有效依赖和 rpath、主动停止、未知命令跳过、五类依赖命令进行检查。
- 在首 / 中 / 末命令的两次读取、分配处分别注入失败，并检查立即停止和释放；
  覆盖短读取、两次读取间命令形状变化、命令数 / 流大小 / 命令区异常。
- 检查短类型头、无效偏移、空名称、未终止名称以及最后一字节恰为 NUL。
- 既有递归原生回归补充依赖枚举失败、rpath 枚举失败与非法 UTF-8；
  同一文件身份下清除故障后重试，确认失败没有缓存部分 rpath。

新增解析器用例执行的是独立 MachO fixture 和真实 buffered stream，
不执行完整 `macho_init`、segment/fileset 解析或 DSC 地址翻译。
递归用例继续使用真实 Foundation、文件与路径解析，但底层 ChOma 调用和
RootHide 副作用采用测试替身。两类用例不能等同于完整端到端 iOS 内核运行。
Windows 无 Apple SDK；ASan/UBSan、完整 TIPA、包身份与制品上传待本轮 CI，
后续验收记录会明确区分，当前不冒充已经通过。

### 首次 CI 与测试编译修正

提交 `bb4dda5f02831e38977030ef6213e2f79e1ac721` 的 Run `42377573833`
在新增命令枚举原生回归的编译阶段失败，完整打包未运行。
实际错误是固定依赖既有 `memory_stream_read` 中 `int ret` 与 `size_t size`
的比较，在本测试额外启用的 `-Wextra -Werror` 下触发 `-Wsign-compare`。
修正仅在生成的测试翻译单元中，围绕抽取的未修改 MemoryStream helper
局部屏蔽这一警告；生产源码和依赖补丁不变。
新增枚举器与其余测试继续使用 `-Wall -Wextra -Werror` 和 ASan/UBSan。
该修正仍需重新执行 macOS CI，不将编译警告处理冒充运行验证。

## 保留与剩余工作

- 按用户要求移除的两个管理器安装入口保持移除，不卸载独立管理器，
  不更改配置、挂载或黑白名单默认策略。
- 不修改设置 / 关于的滚动、回弹、玻璃渲染、低电量计划或后台设计。
  产品版本仍为 `3.0.7`，最低 iOS `16.0`，保留 RC9 既有真正可越狱的
  iOS 16 设备 / 固件组合；完整矩阵仍待逐项整理和真机验证。
- 通用枚举函数没有验证所有命令专属字段。segment 节表、fileset、
  CodeDirectory 内部字段、其他子解析器和 stream 写入 / 扩容 / clone
  失败路径仍开放，不能称为完整 Mach-O 解析器安全审计完成。
- `_macho_parse` 仍有未检查子解析结果的行为；本轮没有扩展为全面初始化重写。
  检查 `cmd` / `cmdsize` 变化也不是整个文件快照或并发修改一致性保证。
- 不提供之前文件随机化 / jbroot 准备的回滚，不关闭 trustcache 内核读者
  生命周期、dyld / live basebin 中断恢复、post-fork 资源或真机兼容性缺口。
