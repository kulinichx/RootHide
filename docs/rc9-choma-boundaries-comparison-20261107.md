# RC9 固定 ChOma 签名容器边界核查

日期：2026-11-07。RC9 运行时代码基线 `8e560fa3`，工作分支前置文档提交
`e32a0955`。固定对照仍是官方 RootHide `9617d75f` 与 ZQBB RootHide
`7e14aa61`，不将这些固定参考称为远端最新。

## 证据和归类

本轮初始化并直接检查 RC9 已固定的 ChOma
`ed99ac526142e78a5bc99793cf433775040f9d67`，没有换用 ZQBB 或远端的新提交。
补丁保存为 `.github/patches/ChOma-signature-boundaries.patch`，由构建工作流在
检出固定子模块后应用，记录补丁和修改后源码的 SHA-256。父仓库 gitlink 不变。

其他本地构建入口也必须先应用该补丁，不能只更新父仓库的 `signatures.c` 而链接
未经修改的 ChOma。从仓库根目录对干净、已初始化的固定子模块执行：

```sh
git -C BaseBin/ChOma apply "$PWD/.github/patches/ChOma-signature-boundaries.patch"
```

已经应用过补丁的工作区不要重复应用；当前审计工作区的子模块源码改动与提交中的
补丁一致。这不是未记录的另一个 ChOma 提交。

原 `CSBlob.c` 的 Git blob 是 `4c298b9fb9841e22412f949227f3e099a40306c1`，
原 `CSBlob.h` 是 `cefb2002d670feaa605354bf52615bfa511adcde`。
检查发现：

- `macho_read_code_signature` 未检查分配结果或返回容器的实际字节边界。
- 解码器按输入声明的索引数量和偏移读取，没有接收实际缓冲区容量；
  子 blob 或 stream 分配失败时还可能解引用空对象或遗漏释放。
- 真实 `csd_superblob_encode` 在自己的分配失败时已经写入空指针，
  不能只依靠调用方检查其返回值。
- 没有可用 CodeDirectory 时，best-cdhash 路径仍会继续调用字段读取函数。

这是固定依赖的实际缺口及 RC9 的失败路径加固，不冒充官方或 ZQBB 的已发布修复。
外层调用方的对照证据沿用第十、十二阶段记录。

## 本轮修改

| 范围 | 处理 |
| --- | --- |
| 已知容量的签名来源 | 新增 sized 解码接口；`trust_signatures` 传入 `fs_blob_size`，不把输入自报长度当作实际容量 |
| 容器外层边界 | 核查 header、magic、总长度、索引表、每个 child 的头部与长度；以减法/除法避免越界加法；复制读取可能未对齐的头和索引 |
| Mach-O 读取入口 | 读取大小至少包含完整 header；检查分配和读取结果，再按 load command 实际字节数验证容器 |
| 解码失败 | 失败立即释放此前成功创建的子对象，不返回部分解码结果 |
| 编码失败 | 检查 32 位总长度、分配结果、各子 stream 的读取结果和剩余输出容量 |
| stream 构造 | 补上 context 分配失败、构造失败时 stream 和复制缓冲区的释放 |
| 缺少 CodeDirectory | best-cdhash 返回失败，不解引用空对象 |
| 上层错误处理 | 非零数量的空输入，以及来源读取/解码失败，返回失败并清理本次临时数组，不继续信任或附加 |

成功路径的注入规则、信任顺序和 iOS 16 策略不变。本轮不修改 UI、回弹、
玻璃效果、低电量计划、挂载或名单默认值；版本仍为 `3.0.7`，最低 iOS `16.0`。

## 测试与此前结论修正

第十阶段的编码故障回归替换了 `csd_superblob_encode`，可以证明
`trust_signatures` 在编码器返回空值时保留原始缓冲区，**不能证明真实编码器内部
已经安全返回空值**。其当时的外层检查仍有作用，但真实依赖内部的分配保护直到本轮
才补上。此前成功构建和普通设备使用也不等于执行过真实分配失败路径。

新增 `tests/test_rc9_choma_boundaries.py --native`，使用固定依赖的真实头文件、
完整 `BufferedStream.c` 和直接抽取的生产 codec / MemoryStream 函数。
仅替换 Mach-O I/O 与本测试不用的 CodeDirectory 哈希边界；不替换被测编码器、
解码器或 stream 分配实现。覆盖：

- 紧贴 heap 分配边界的截断 header、非法长度/数量/索引/child。
- 两个 child 解码所需的全部九次分配逐次失败及部分对象清理。
- 未对齐输入、真实编码分配失败、成功往返、stream 读取失败与长度异常。
- 缺少 CodeDirectory、Mach-O 入口分配/读取/边界错误，以及允许尾部 padding、
  保持原有 detached signature 容器支持。

原签名附加回归另补来源读取和解码失败、非零数量空输入，确认不发生后续缓存查询、
信任或附加。

Windows 本地完整源码/契约回归 **164 项通过**。本机无 macOS Clang/Apple SDK，
新增真实实现的 ASan/UBSan 原生回归及完整 TIPA 构建需由本轮 macOS CI 验证；
未通过前不登记为原生验证成功。设备验收另行记录。

首次 CI Run `42372146566`（代码 `609084ea`）通过既有源码、运行时、
签名附加及来源读取回归，但新增 ChOma 测试在编译阶段失败：
故障注入的 `free` 宏在头文件载入后定义，使实现中的 `MemoryStream.free`
回调名被改写而声明未同步。已将注入宏移到真实 ChOma 头文件之前，
使声明与实现一致预处理；不复制结构体、不改变其布局，也不修改生产逻辑。
后续构建在该失败后被跳过，不能把本次 run 记为成功或已有新包。

### CI 验收补记

修正测试注入顺序后的提交 `d173d36ea9b532877c79f0630bf5e94c26c4de5d`，
GitHub Run `42372494583` 已完成并成功。源码回归、既有运行时原生回归、
签名附加和来源读取原生回归、新增真实 ChOma ASan/UBSan 回归、
配套工具 scheme 回归、完整 TIPA、包身份检查与上传均通过。
此记录更新本轮前述 macOS CI 待验状态，不改变第一次失败的事实。

制品 `Dopamine_3.0.7-d173d36e_roothide.tipa`，artifact ID `13573798939`。
GitHub artifact 归档 digest：
`sha256:ddfe9568b9313072743f456f7f018bc0e4abe69d43631fd0ff2fdf7ce2c51b4f`。
这是制品归档的摘要，不是其中 TIPA 文件本身的 SHA-256。
本候选尚未取得用户设备验收；不能沿用 `7ad14162` 的普通使用反馈。

## 仍未关闭

- 旧的无容量解码接口为兼容保留，只能使用输入声明的长度；直接调用方仍必须
  保证完整缓冲区，不能用它证明外部实际容量安全。
- 这是外层容器核查，不是完整 CodeDirectory 内部字段、哈希槽、重叠或重复索引审计。
- `fat_collect_signatures` 仍有读取失败与无签名混同为跳过的分支；常规调用链之前的
  adhoc 检查不能排除两次读取之间变化，也不能替代直接 collector 的错误传播审计。
- 并发修改文件、内存输入或已解码链表的一致性不在本轮保证范围。
- stream 的写入、扩展、clone 等其余分配路径尚未全部核查。
- trustcache 内核读者生命周期、dyld/live basebin 中断恢复、其他 fork 资源生命周期、
  standalone 构建及 iOS 16 各受支持设备/系统组合的真机验收仍开放。

本轮不归因为用户设备重启，也不表示 RC9 与两个上游的全量差异已经清零。
